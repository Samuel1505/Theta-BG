import { useAccount } from 'wagmi'
import type { Hex } from 'viem'
import { addresses, lpInsuranceVaultAbi, explorerAddress } from '../config/contracts'
import { useVaultStats, useStrategyShares } from '../hooks/useProtocol'
import { useActivity } from '../hooks/useActivity'
import { useDemoLpPosition, useLpPositions, type LpPosition } from '../hooks/useLp'
import { Card, Stat, KV, KVRow, Address, Tag, Callout, Empty } from '../components/primitives'
import { TxButton } from '../components/TxButton'
import { ActivityFeed } from '../components/ActivityFeed'
import { IconDroplet, IconInfo } from '../components/icons'
import { formatEth, formatBigCompact } from '../lib/format'

function PositionRow({
  p,
  isOwn,
  onClaimed,
}: {
  p: LpPosition
  isOwn: boolean
  onClaimed: () => void
}) {
  return (
    <tr>
      <td>
        <Address address={p.owner} />
        {isOwn ? <Tag tone="info">you</Tag> : null}
      </td>
      <td className="num">
        {p.tickLower} … {p.tickUpper}
      </td>
      <td className="num">{formatBigCompact(p.liquidity > 0n ? p.liquidity : 0n)}</td>
      <td className="num accent">{formatEth(p.claimable)} ETH</td>
      <td>
        {isOwn ? (
          <TxButton
            size="sm"
            disabled={p.claimable === 0n}
            disabledReason="Nothing accrued yet"
            successTitle="Insurance claimed"
            pendingLabel="Claiming…"
            onConfirmed={onClaimed}
            request={() => ({
              address: addresses.vault,
              abi: lpInsuranceVaultAbi,
              functionName: 'claimInsuranceYield',
              args: [p.tickLower, p.tickUpper, p.salt],
            })}
          >
            Claim
          </TxButton>
        ) : (
          <span className="muted">—</span>
        )}
      </td>
    </tr>
  )
}

export function Vault() {
  const { address, isConnected } = useAccount()
  const { stats } = useVaultStats()
  const strategyShares = useStrategyShares()
  const activity = useActivity()
  const mine = useLpPositions(address as Hex | undefined)
  const demo = useDemoLpPosition()

  const claimEvents = activity.data?.filter((e) => e.kind === 'insurance-claimed') ?? []
  const fundedEvents = activity.data?.filter((e) => e.kind === 'insurance-funded') ?? []
  const totalFunded = fundedEvents.reduce((s, e) => s + (e.amount ?? 0n), 0n)
  const totalClaimed = claimEvents.reduce((s, e) => s + (e.amount ?? 0n), 0n)

  const myClaimable = mine.data?.reduce((s, p) => s + p.claimable, 0n)

  const onClaimed = () => {
    mine.refetch()
    demo.refetch()
    activity.refetch()
  }

  return (
    <>
      <div className="grid grid--stats">
        <Stat
          label="Available balance"
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
              ? `${formatEth(strategyShares.data as bigint)} shares held`
              : 'lifetime into strategy'
          }
          loading={!stats}
        />
        <Stat
          label="Idle (undeployed)"
          value={formatEth(stats?.idleAssets)}
          unit="ETH"
          sub="slashes with no eligible LP"
          loading={!stats}
        />
        <Stat
          label="Claimed by LPs"
          value={formatEth(totalClaimed)}
          unit="ETH"
          sub={`${formatEth(totalFunded)} ETH ever booked`}
          loading={activity.isLoading}
        />
      </div>

      <div className="grid grid--2">
        <Card title="Your positions" subtitle="Auto-discovered from your PoolManager liquidity events">
          {!isConnected ? (
            <Empty>Connect a wallet that has provided liquidity to this pool.</Empty>
          ) : mine.isLoading ? (
            <div className="empty">Looking up your positions…</div>
          ) : !mine.data || mine.data.length === 0 ? (
            <Empty>
              No liquidity positions found for this address on the demo pool. Add liquidity to the
              ETH/tbgUSD pool through the hook to start accruing insurance.
            </Empty>
          ) : (
            <div className="stack">
              <div className="row row--between">
                <span className="dim">Total claimable now</span>
                <span className="mono accent" style={{ fontSize: '1.1rem' }}>
                  {formatEth(myClaimable)} ETH
                </span>
              </div>
              <div className="table-wrap">
                <table className="data">
                  <thead>
                    <tr>
                      <th>Owner</th>
                      <th>Tick range</th>
                      <th>Liquidity</th>
                      <th>Claimable</th>
                      <th />
                    </tr>
                  </thead>
                  <tbody>
                    {mine.data.map((p) => (
                      <PositionRow
                        key={`${p.tickLower}:${p.tickUpper}:${p.salt}`}
                        p={p}
                        isOwn
                        onClaimed={onClaimed}
                      />
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </Card>

        <Card title="How LPs get paid" subtitle="Model A — fully claimable, any time">
          <div className="stack">
            <Callout tone="neutral" icon={<IconDroplet />}>
              When a bond is slashed, the pool's share is wrapped to WETH and deposited into the
              yield strategy. The vault bumps a{' '}
              <code>accInsurancePerLiquidityX128</code> accumulator — the same fee-growth trick
              Uniswap uses — so every in-range LP's share is computed on claim, with no LP list
              and no enumeration.
            </Callout>
            <KV>
              <KVRow k="Accumulator">
                {stats?.accPerLiquidityX128 !== undefined
                  ? formatBigCompact(stats.accPerLiquidityX128)
                  : '—'}{' '}
                <span className="muted">Q128</span>
              </KVRow>
              <KVRow k="Strategy">
                <Address address={addresses.strategy} />
              </KVRow>
              <KVRow k="Vault">
                <Address address={addresses.vault} />
              </KVRow>
            </KV>
            <a
              className="btn btn--ghost btn--sm"
              href={explorerAddress(addresses.vault)}
              target="_blank"
              rel="noreferrer"
            >
              View vault on Uniscan
            </a>
          </div>
        </Card>
      </div>

      <Card
        title="Demo LP position"
        subtitle="The seeded ETH/tbgUSD position that absorbed the demo slash"
        flush
      >
        {demo.isLoading ? (
          <div className="empty">Loading…</div>
        ) : !demo.data || demo.data.length === 0 ? (
          <Empty>Demo LP position not found.</Empty>
        ) : (
          <div className="table-wrap">
            <table className="data">
              <thead>
                <tr>
                  <th>Owner</th>
                  <th>Tick range</th>
                  <th>Liquidity</th>
                  <th>Claimable</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {demo.data.map((p) => (
                  <PositionRow
                    key={`${p.tickLower}:${p.tickUpper}:${p.salt}`}
                    p={p}
                    isOwn={Boolean(address && p.owner.toLowerCase() === address.toLowerCase())}
                    onClaimed={onClaimed}
                  />
                ))}
              </tbody>
            </table>
          </div>
        )}
        <div className="callout callout--info" style={{ margin: 16 }}>
          <IconInfo />
          <div>
            This position is owned by the demo LP executor contract, so its accrued insurance
            can only be claimed by that contract — the row is shown here as a worked example of
            the accumulator crediting a real slash.
          </div>
        </div>
      </Card>

      <Card title="Vault events" subtitle="Funding and claims" flush>
        {activity.isLoading ? (
          <div className="empty">Loading…</div>
        ) : (
          <ActivityFeed
            events={activity.data?.filter(
              (e) => e.kind === 'insurance-funded' || e.kind === 'insurance-claimed',
            )}
            emptyLabel="The vault has not been funded or claimed against yet."
          />
        )}
      </Card>
    </>
  )
}
