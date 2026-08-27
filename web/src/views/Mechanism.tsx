import { Card, KV, KVRow, Callout, Tag } from '../components/primitives'
import { IconAlert, IconExternal, IconInfo } from '../components/icons'
import { useProtocolConfig } from '../hooks/useProtocol'
import { DEMO_SANDWICH, explorerTx } from '../config/contracts'
import { bpsToPercent, formatEth } from '../lib/format'
import { sqrtDeviationBps, sqrtPriceX96ToPrice } from '../lib/pool'

const CONDITIONS = [
  {
    n: 1,
    title: 'Same searcher brackets the victim',
    body: (
      <>
        The front-run leg <code>a</code> and the back-run leg <code>c</code> have the same{' '}
        <code>sender</code> — the direct <code>PoolManager.swap()</code> caller.
      </>
    ),
  },
  {
    n: 2,
    title: 'All three swaps in one block',
    body: (
      <>
        <code>a</code>, the victim <code>b</code>, and <code>c</code> share a block number.
        Cross-block back-runs are out of scope entirely.
      </>
    ),
  },
  {
    n: 3,
    title: 'A distinct address in the middle',
    body: (
      <>
        The most recent swap before the closing leg was sent by someone other than the searcher.
        A victimless round-trip by the searcher alone fails here.
      </>
    ),
  },
  {
    n: 4,
    title: 'Opposite directions',
    body: (
      <>
        <code>a.zeroForOne ≠ c.zeroForOne</code> — the searcher buys then sells (or sells then
        buys), not the same way twice.
      </>
    ),
  },
  {
    n: 5,
    title: 'Displaced enough, then restored',
    body: (
      <>
        The front-run moved <code>sqrtPriceX96</code> by at least{' '}
        <code>minDisplacementBps</code> (filters dust), and the back-run brought it back to
        within <code>restorationThresholdBps</code> of where it started.
      </>
    ),
  },
]

export function Mechanism() {
  const { config } = useProtocolConfig()

  const d = DEMO_SANDWICH
  const p0 = sqrtPriceX96ToPrice(d.startSqrtPriceX96)
  const p1 = sqrtPriceX96ToPrice(d.afterFrontRunSqrtPriceX96)
  const p2 = sqrtPriceX96ToPrice(d.afterVictimSqrtPriceX96)
  const p3 = sqrtPriceX96ToPrice(d.finalSqrtPriceX96)

  return (
    <>
      <Card title="The predicate" subtitle="Pure, five conditions, formally specified in SandwichPredicate.sol">
        <div className="stack">
          {CONDITIONS.map((c) => (
            <div className="cond" key={c.n}>
              <div className="cond__n">{c.n}</div>
              <div className="cond__body">
                <h4>{c.title}</h4>
                <p>{c.body}</p>
              </div>
            </div>
          ))}
        </div>
        <Callout tone="info" icon={<IconInfo />}>
          The predicate has no storage access and no external calls — it's unit- and
          fuzz-tested in isolation. The hook feeds it three <code>SwapRecord</code>s: the
          searcher's open leg this block, a synthetic middle record carrying only the prior
          sender, and the swap that just closed the bracket.
        </Callout>
      </Card>

      <div className="grid grid--2">
        <Card title="Live thresholds" subtitle="Read from the deployed hook">
          <KV>
            <KVRow k="Min. front-run displacement">
              {bpsToPercent(config?.minDisplacementBps)}{' '}
              <span className="muted">of sqrtPrice</span>
            </KVRow>
            <KVRow k="Restoration threshold">
              {bpsToPercent(config?.restorationThresholdBps)}{' '}
              <span className="muted">of sqrtPrice</span>
            </KVRow>
            <KVRow k="Priority-lane fee">{bpsToPercent(config?.priorityFeeBps)}</KVRow>
            <KVRow k="Protocol share of a slash">{bpsToPercent(config?.protocolShareBps)}</KVRow>
          </KV>
          <Callout tone="warn" icon={<IconAlert />}>
            Thresholds compare <code>sqrtPriceX96</code>, not price. A <code>t</code> bps move in
            <code> sqrtPrice</code> ≈ <code>2t</code> bps in price — so the 0.1% restoration band
            is ~0.2% in price terms. This is deliberate and documented in <code>MECHANISM.md</code>.
          </Callout>
        </Card>

        <Card title="Bond economics" subtitle="From MECHANISM.md">
          <KV>
            <KVRow k="Base bond">{formatEth(config?.minimumBond)} ETH</KVRow>
            <KVRow k="Re-entry after a slash">
              {config?.minimumBond ? formatEth(config.minimumBond * 2n) : '—'} ETH{' '}
              <span className="muted">flat 2×, not exponential</span>
            </KVRow>
            <KVRow k="Slash amount">entire current bond</KVRow>
            <KVRow k="Withdrawal cooldown">24h — can't dodge a pending slash</KVRow>
          </KV>
          <p className="dim" style={{ fontSize: '0.86rem', marginTop: 12 }}>
            A full-bond slash is the only amount that can never exceed available funds, so there's
            no "bond smaller than the required slash" edge case. The 24h cooldown means a searcher
            can't front-run their own detection by withdrawing between the front-run and back-run
            legs.
          </p>
        </Card>
      </div>

      <Card
        title="The demo sandwich — a real, verified slash"
        subtitle="script/DemoSandwich.s.sol, executed on-chain at production thresholds"
      >
        <div className="table-wrap">
          <table className="data">
            <thead>
              <tr>
                <th>Stage</th>
                <th>sqrtPriceX96</th>
                <th>Price (tbgUSD/ETH)</th>
                <th>Deviation from start</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>Start</td>
                <td className="num">{d.startSqrtPriceX96.toString()}</td>
                <td className="num">{p0.toFixed(4)}</td>
                <td className="num">—</td>
              </tr>
              <tr>
                <td>After front-run</td>
                <td className="num">{d.afterFrontRunSqrtPriceX96.toString()}</td>
                <td className="num">{p1.toFixed(4)}</td>
                <td className="num danger">
                  {sqrtDeviationBps(d.startSqrtPriceX96, d.afterFrontRunSqrtPriceX96).toFixed(1)} bps
                </td>
              </tr>
              <tr>
                <td>After victim</td>
                <td className="num">{d.afterVictimSqrtPriceX96.toString()}</td>
                <td className="num">{p2.toFixed(4)}</td>
                <td className="num">
                  {sqrtDeviationBps(d.startSqrtPriceX96, d.afterVictimSqrtPriceX96).toFixed(1)} bps
                </td>
              </tr>
              <tr>
                <td>After back-run</td>
                <td className="num">{d.finalSqrtPriceX96.toString()}</td>
                <td className="num">{p3.toFixed(4)}</td>
                <td className="num accent">
                  {sqrtDeviationBps(d.startSqrtPriceX96, d.finalSqrtPriceX96).toFixed(2)} bps
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div className="grid grid--stats" style={{ marginTop: 16 }}>
          <div className="stat">
            <div className="stat__label">Bond slashed</div>
            <div className="stat__value stat__value--danger">{formatEth(d.bondSlashed)} ETH</div>
          </div>
          <div className="stat">
            <div className="stat__label">To insurance vault</div>
            <div className="stat__value stat__value--accent">{formatEth(d.insuranceCut)} ETH</div>
            <div className="stat__sub">exactly 90%</div>
          </div>
          <div className="stat">
            <div className="stat__label">Protocol cut</div>
            <div className="stat__value">{formatEth(d.protocolCut)} ETH</div>
            <div className="stat__sub">exactly 10%</div>
          </div>
        </div>

        <div className="stack" style={{ marginTop: 16 }}>
          {(
            [
              ['Front-run', d.frontRun, 'the searcher displaces the price 372.9 bps'],
              ['Victim', d.victim, 'an unrelated address swaps into the displaced price'],
              ['Back-run', d.backRun, 'the searcher closes to 1.72 bps of start → predicate matches → slash'],
            ] as const
          ).map(([label, hash, note]) => (
            <a
              key={hash}
              className="card"
              href={explorerTx(hash)}
              target="_blank"
              rel="noreferrer"
              style={{ padding: '12px 14px', display: 'block' }}
            >
              <div className="row row--between">
                <Tag tone={label === 'Back-run' ? 'danger' : undefined}>{label}</Tag>
                <span className="row" style={{ gap: 6 }}>
                  <span className="mono muted" style={{ fontSize: '0.8rem' }}>
                    {hash.slice(0, 14)}…{hash.slice(-8)}
                  </span>
                  <IconExternal style={{ width: 13, height: 13, opacity: 0.6 }} />
                </span>
              </div>
              <p className="dim" style={{ fontSize: '0.84rem', marginTop: 6 }}>
                {note}
              </p>
            </a>
          ))}
        </div>

        <Callout tone="info" icon={<IconInfo />}>
          The back-run's input amount was computed exactly via v4's own{' '}
          <code>SqrtPriceMath.getAmount1Delta</code> — necessary to reliably land inside a 0.1%
          restoration band rather than guess.
        </Callout>
      </Card>

      <Card title="Out of scope — by design" subtitle="From LIMITATIONS.md">
        <ul className="dim" style={{ fontSize: '0.9rem', lineHeight: 1.7, paddingLeft: 18, margin: 0 }}>
          <li>Back-runs that land in the next block or later — cross-block MEV is not covered.</li>
          <li>
            Searchers routed through a shared aggregator or router — identity is the direct{' '}
            <code>PoolManager</code> caller only.
          </li>
          <li>JIT liquidity attacks and LVR — the predicate looks at swap sequences only.</li>
          <li>
            It's pattern detection, not intent proof — a benign arbitrage that happens to close a
            same-block bracket around a third party would match.
          </li>
        </ul>
      </Card>
    </>
  )
}
