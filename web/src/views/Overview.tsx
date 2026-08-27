import { Link } from 'react-router-dom'
import { formatEth, formatCount } from '../lib/format'
import { useProtocolConfig, useVaultStats } from '../hooks/useProtocol'
import { useActivity } from '../hooks/useActivity'
import { useAllSearchers } from '../hooks/useSearchers'
import { Card, Stat, Callout } from '../components/primitives'
import { IconShield, IconExternal } from '../components/icons'
import { DEMO_SANDWICH, explorerTx } from '../config/contracts'

export function Overview() {
  const { stats } = useVaultStats()
  const { config } = useProtocolConfig()
  const activity = useActivity()
  const searchers = useAllSearchers()

  const slashes = activity.data?.filter((e) => e.kind === 'slash') ?? []
  const totalSlashed = slashes.reduce((sum, e) => sum + (e.amount ?? 0n), 0n)
  const activeSearchers = searchers.data?.filter((s) => s.isActive).length

  return (
    <>
      <section className="hero">
        <span className="tag tag--accent" style={{ marginBottom: 14 }}>
          <span className="tag__dot" /> Live on Unichain Sepolia
        </span>
        <h2>Sandwich the pool, lose your bond — and that bond becomes LP yield.</h2>
        <p className="lead">
          Theta-BG is a Uniswap v4 hook with three parts: a bonded priority lane for searchers,
          a pure on-chain predicate that detects a same-block front-run → victim → back-run
          bracket as it closes, and a self-compounding insurance vault that pays the slashed
          bond out to the LPs who were exposed to it — automatically, in the same transaction.
        </p>
        <div className="hero__actions">
          <Link className="btn btn--primary" to="/dashboard">
            Open the dashboard
          </Link>
          <Link className="btn btn--ghost" to="/mechanism">
            How the predicate works
          </Link>
        </div>
      </section>

      <div className="grid grid--stats">
        <Stat
          label="Insurance vault"
          value={formatEth(stats?.availableBalance)}
          unit="ETH"
          sub="Idle + strategy value, compounding"
          tone="accent"
          loading={!stats}
        />
        <Stat
          label="Bonds slashed"
          value={formatEth(totalSlashed)}
          unit="ETH"
          sub={`${formatCount(slashes.length)} on-chain slash${slashes.length === 1 ? '' : 'es'}`}
          loading={activity.isLoading}
        />
        <Stat
          label="Active searchers"
          value={activeSearchers ?? '—'}
          sub={`${formatCount(searchers.data?.length)} ever registered`}
          loading={searchers.isLoading}
        />
        <Stat
          label="Min. bond"
          value={formatEth(config?.minimumBond)}
          unit="ETH"
          sub="2× after any slash"
          loading={!config}
        />
      </div>

      <div className="grid grid--2">
        <Card title="The lifecycle" flush>
          <div className="card__body">
            <div className="flow">
              <div className="flow__step">
                <div className="flow__step__n">01</div>
                <h4>Bond</h4>
                <p>
                  A searcher posts ≥ the minimum bond in native ETH to the registry. Bonded
                  searchers get a small priority-fee lane; the bond is locked behind a 24h
                  withdrawal cooldown.
                </p>
              </div>
              <div className="flow__step">
                <div className="flow__step__n">02</div>
                <h4>Detect</h4>
                <p>
                  On every swap the hook checks a five-condition predicate against the
                  searcher's own open leg this block. A closed sandwich bracket that restored
                  the price is a match.
                </p>
              </div>
              <div className="flow__step">
                <div className="flow__step__n">03</div>
                <h4>Slash &amp; compound</h4>
                <p>
                  The entire bond is slashed. 10% goes to the protocol; the rest is wrapped to
                  WETH, deposited into a yield strategy, and booked to LPs via a
                  reward-per-liquidity accumulator.
                </p>
              </div>
            </div>
          </div>
        </Card>

        <Card title="The proof" subtitle="A real slash at production thresholds">
          <Callout tone="neutral" icon={<IconShield />}>
            The demo sandwich in <code>script/DemoSandwich.s.sol</code> was executed on-chain
            against this exact pool — front-run displaced the price{' '}
            <strong>{DEMO_SANDWICH.displacementBps} bps</strong>, the back-run restored it to
            within <strong>{DEMO_SANDWICH.finalDeviationBps} bps</strong> of the start, and the
            searcher's <strong>{formatEth(DEMO_SANDWICH.bondSlashed)} ETH</strong> bond was
            fully slashed: {formatEth(DEMO_SANDWICH.insuranceCut)} ETH to the vault,{' '}
            {formatEth(DEMO_SANDWICH.protocolCut)} ETH protocol cut.
          </Callout>
          <div className="stack" style={{ marginTop: 14 }}>
            {(
              [
                ['Front-run', DEMO_SANDWICH.frontRun],
                ['Victim', DEMO_SANDWICH.victim],
                ['Back-run → slash', DEMO_SANDWICH.backRun],
              ] as const
            ).map(([label, hash]) => (
              <a
                key={hash}
                className="row row--between"
                href={explorerTx(hash)}
                target="_blank"
                rel="noreferrer"
                style={{ fontSize: '0.86rem' }}
              >
                <span className="dim">{label}</span>
                <span className="row" style={{ gap: 6 }}>
                  <span className="mono muted">
                    {hash.slice(0, 10)}…{hash.slice(-6)}
                  </span>
                  <IconExternal style={{ width: 13, height: 13, opacity: 0.6 }} />
                </span>
              </a>
            ))}
          </div>
          <div style={{ marginTop: 16 }}>
            <Link className="btn btn--ghost btn--sm" to="/mechanism">
              Full walkthrough
            </Link>
          </div>
        </Card>
      </div>

      <Callout tone="warn">
        Testnet build. Detection is same-block and cross-transaction only; next-block back-runs,
        JIT/LVR, and searchers routed through shared aggregators are out of scope by design — see
        the Mechanism page and the repo's <code>LIMITATIONS.md</code>.
      </Callout>
    </>
  )
}
