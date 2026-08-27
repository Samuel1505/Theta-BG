import { useMemo } from 'react'
import {
  useProtocolConfig,
  usePoolState,
  useStrategyShares,
  useTokenMeta,
  useVaultStats,
} from '../hooks/useProtocol'
import { useActivity } from '../hooks/useActivity'
import { useAllSearchers } from '../hooks/useSearchers'
import { Card, Stat, KV, KVRow, Address, Tag } from '../components/primitives'
import { ActivityFeed } from '../components/ActivityFeed'
import { IconInfo, IconRefresh } from '../components/icons'
import {
  bpsToPercent,
  formatBigCompact,
  formatCount,
  formatEth,
} from '../lib/format'
import { sqrtPriceX96ToPrice } from '../lib/pool'
import { addresses, explorerAddress } from '../config/contracts'

export function Dashboard() {
  const { config } = useProtocolConfig()
  const { stats } = useVaultStats()
  const { pool } = usePoolState()
  const strategyShares = useStrategyShares()
  const token = useTokenMeta()
  const activity = useActivity()
  const searchers = useAllSearchers()

  const slashes = activity.data?.filter((e) => e.kind === 'slash') ?? []
  const totalSlashed = slashes.reduce((s, e) => s + (e.amount ?? 0n), 0n)
  const totalToLps = slashes.reduce((s, e) => s + ((e.extra?.insuranceCut as bigint) ?? 0n), 0n)
  const activeSearchers = searchers.data?.filter((s) => s.isActive).length

  const price = useMemo(
    () => (pool ? sqrtPriceX96ToPrice(pool.slot0.sqrtPriceX96) : undefined),
    [pool],
  )

  // Rough proxy: everything the vault can pay out today, minus what was ever
  // deposited as principal. Positive once strategy yield accrues; not exact
  // after LP claims (the deployed vault tracks no withdrawal total).
  const yieldEarned =
    stats?.principalDeposited !== undefined && stats.availableBalance !== undefined
      ? stats.availableBalance - stats.principalDeposited
      : undefined

  return (
    <>
      <div className="grid grid--stats">
        <Stat
          label="Insurance vault"
          value={formatEth(stats?.availableBalance)}
          unit="ETH"
          sub="idle + strategy value"
          tone="accent"
          loading={!stats}
        />
        <Stat
          label="Principal deposited"
          value={formatEth(stats?.principalDeposited)}
          unit="ETH"
          sub={
            strategyShares.data !== undefined
              ? `${formatEth(strategyShares.data as bigint)} strategy shares`
              : 'in the yield strategy'
          }
          loading={!stats}
        />
        <Stat
          label="Bonds slashed (total)"
          value={formatEth(totalSlashed)}
          unit="ETH"
          sub={`${formatEth(totalToLps)} ETH routed to LPs`}
          tone={slashes.length ? 'danger' : undefined}
          loading={activity.isLoading}
        />
        <Stat
          label="Pending protocol fees"
          value={formatEth(config?.pendingProtocolFees)}
          unit="ETH"
          sub="awaiting withdrawal"
          loading={!config}
        />
        <Stat
          label="Pool price"
          value={price ? price.toLocaleString('en-US', { maximumFractionDigits: 4 }) : '—'}
          unit={`${token.symbol}/ETH`}
          sub={pool ? `tick ${pool.slot0.tick}` : ' '}
          loading={!pool}
        />
        <Stat
          label="In-range liquidity"
          value={formatBigCompact(pool?.liquidity)}
          sub="live from PoolManager"
          loading={!pool}
        />
        <Stat
          label="Active searchers"
          value={activeSearchers ?? '—'}
          sub={`${formatCount(searchers.data?.length)} registered`}
          loading={searchers.isLoading}
        />
        <Stat
          label="Strategy yield (approx)"
          value={yieldEarned !== undefined ? formatEth(yieldEarned > 0n ? yieldEarned : 0n) : '—'}
          unit="ETH"
          sub="available − principal"
          loading={!stats}
        />
      </div>

      <div className="grid grid--2">
        <Card
          title="Hook parameters"
          subtitle="Immutable — set once at deployment, no admin can change them"
        >
          <KV>
            <KVRow k="Minimum bond">{formatEth(config?.minimumBond)} ETH</KVRow>
            <KVRow k="Bond after a slash">
              {config?.minimumBond ? formatEth(config.minimumBond * 2n) : '—'} ETH
            </KVRow>
            <KVRow k="Withdrawal cooldown">
              {config?.withdrawalCooldown ? `${Number(config.withdrawalCooldown) / 3600}h` : '—'}
            </KVRow>
            <KVRow k={<>Restoration threshold</>}>
              {bpsToPercent(config?.restorationThresholdBps)}
            </KVRow>
            <KVRow k="Min. front-run displacement">
              {bpsToPercent(config?.minDisplacementBps)}
            </KVRow>
            <KVRow k="Priority-lane fee">{bpsToPercent(config?.priorityFeeBps)}</KVRow>
            <KVRow k="Protocol share of a slash">
              {bpsToPercent(config?.protocolShareBps)}
            </KVRow>
            <KVRow k="Protocol fee recipient">
              <Address address={config?.protocolFeeRecipient} />
            </KVRow>
          </KV>
        </Card>

        <Card title="Deployed contracts" subtitle="Unichain Sepolia · chain 1301">
          <KV>
            {(
              [
                ['ThetaBGHook', addresses.hook],
                ['SearcherRegistry', addresses.registry],
                ['LPInsuranceVault', addresses.vault],
                ['DemoYieldStrategy', addresses.strategy],
                ['tbgUSD token', addresses.demoToken],
                ['PoolManager', addresses.poolManager],
              ] as const
            ).map(([label, addr]) => (
              <KVRow key={addr} k={label}>
                <Address address={addr} />
              </KVRow>
            ))}
          </KV>
          <div style={{ marginTop: 14 }}>
            <a
              className="btn btn--ghost btn--sm"
              href={explorerAddress(addresses.hook)}
              target="_blank"
              rel="noreferrer"
            >
              Open hook on Uniscan
            </a>
          </div>
        </Card>
      </div>

      <Card
        title="On-chain activity"
        subtitle="Every slash, bond, priority fee and claim against this pool"
        action={
          <button
            className="btn btn--ghost btn--sm"
            onClick={() => activity.refetch()}
            disabled={activity.isFetching}
          >
            <IconRefresh style={{ width: 13, height: 13 }} />
            {activity.isFetching ? 'Refreshing…' : 'Refresh'}
          </button>
        }
        flush
      >
        {activity.isLoading ? (
          <div className="empty">Scanning logs from the deployment block…</div>
        ) : activity.isError ? (
          <div className="empty">
            Could not load activity from the RPC.{' '}
            <button className="btn btn--ghost btn--sm" onClick={() => activity.refetch()}>
              Retry
            </button>
          </div>
        ) : (
          <ActivityFeed events={activity.data} />
        )}
      </Card>

      {slashes.length > 0 && (
        <Card title="Slash ledger" subtitle="Each successful detection and where the bond went" flush>
          <div className="table-wrap">
            <table className="data">
              <thead>
                <tr>
                  <th>Searcher</th>
                  <th>Victim</th>
                  <th>Bond slashed</th>
                  <th>To LPs</th>
                  <th>Protocol</th>
                  <th>Block</th>
                </tr>
              </thead>
              <tbody>
                {slashes.map((e) => (
                  <tr key={`${e.txHash}-${e.logIndex}`}>
                    <td>
                      <Address address={e.actor} />
                    </td>
                    <td>
                      <Address address={e.counterparty} />
                    </td>
                    <td className="num danger">{formatEth(e.amount)} ETH</td>
                    <td className="num accent">
                      {formatEth(e.extra?.insuranceCut as bigint)} ETH
                    </td>
                    <td className="num">{formatEth(e.extra?.protocolCut as bigint)} ETH</td>
                    <td className="num">
                      <Tag>#{e.blockNumber.toString()}</Tag>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      )}

      <div className="callout callout--info">
        <IconInfo />
        <div>
          Pool price is read directly from <code>PoolManager</code> storage via{' '}
          <code>extsload</code> on the packed <code>Slot0</code>. The restoration/displacement
          thresholds compare <code>sqrtPriceX96</code> values, not squared prices — a{' '}
          <code>t</code> bps move in <code>sqrtPrice</code> is roughly <code>2t</code> bps in
          price.
        </div>
      </div>
    </>
  )
}
