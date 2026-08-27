import type { ActivityEvent, ActivityKind } from '../hooks/useActivity'
import { explorerTx } from '../config/contracts'
import { formatEth, shortAddress, timeAgo } from '../lib/format'
import { Address, Empty, Tag } from './primitives'
import { IconExternal } from './icons'

const META: Record<ActivityKind, { label: string; tone?: 'accent' | 'danger' | 'warn' | 'info' }> = {
  slash: { label: 'Sandwich slashed', tone: 'danger' },
  'searcher-registered': { label: 'Searcher bonded', tone: 'accent' },
  'bond-topped-up': { label: 'Bond topped up', tone: 'accent' },
  'withdrawal-requested': { label: 'Withdrawal requested', tone: 'warn' },
  withdrawal: { label: 'Bond withdrawn' },
  'priority-fee': { label: 'Priority fee', tone: 'info' },
  'insurance-funded': { label: 'Vault funded', tone: 'accent' },
  'insurance-claimed': { label: 'Insurance claimed', tone: 'info' },
}

function describe(e: ActivityEvent): React.ReactNode {
  switch (e.kind) {
    case 'slash':
      return (
        <>
          searcher <Address address={e.actor} chars={4} link={false} /> sandwiched{' '}
          <span className="mono muted">{shortAddress(e.counterparty)}</span> —{' '}
          <span className="accent">{formatEth(e.extra?.insuranceCut as bigint)} ETH</span> to LPs
        </>
      )
    case 'searcher-registered':
      return (
        <>
          <Address address={e.actor} chars={4} link={false} /> posted{' '}
          <span className="mono">{formatEth(e.amount)} ETH</span>
        </>
      )
    case 'bond-topped-up':
      return (
        <>
          <Address address={e.actor} chars={4} link={false} /> added{' '}
          <span className="mono">{formatEth(e.amount)} ETH</span> → {formatEth(e.extra?.newBond as bigint)} ETH
        </>
      )
    case 'withdrawal-requested':
      return (
        <>
          <Address address={e.actor} chars={4} link={false} /> started the 24h cooldown
        </>
      )
    case 'withdrawal':
      return (
        <>
          <Address address={e.actor} chars={4} link={false} /> withdrew{' '}
          <span className="mono">{formatEth(e.amount)} ETH</span>
        </>
      )
    case 'priority-fee':
      return (
        <>
          <Address address={e.actor} chars={4} link={false} /> paid{' '}
          <span className="mono">{formatEth(e.amount)} ETH</span> to in-range LPs
        </>
      )
    case 'insurance-funded':
      return (
        <>
          <span className="mono accent">{formatEth(e.amount)} ETH</span> booked to the accumulator
        </>
      )
    case 'insurance-claimed':
      return (
        <>
          <Address address={e.actor} chars={4} link={false} /> claimed{' '}
          <span className="mono">{formatEth(e.amount)} ETH</span>
        </>
      )
  }
}

export function ActivityFeed({
  events,
  limit,
  emptyLabel = 'No on-chain activity yet.',
}: {
  events: ActivityEvent[] | undefined
  limit?: number
  emptyLabel?: string
}) {
  if (!events) return null
  if (events.length === 0) return <Empty>{emptyLabel}</Empty>

  const rows = limit ? events.slice(0, limit) : events

  return (
    <div className="table-wrap">
      <table className="data">
        <thead>
          <tr>
            <th>Event</th>
            <th>Detail</th>
            <th>When</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {rows.map((e) => {
            const m = META[e.kind]
            return (
              <tr key={`${e.txHash}-${e.logIndex}`}>
                <td>
                  <Tag tone={m.tone}>{m.label}</Tag>
                </td>
                <td>{describe(e)}</td>
                <td className="num" title={e.timestamp ? new Date(e.timestamp * 1000).toLocaleString() : undefined}>
                  {e.timestamp ? timeAgo(e.timestamp) : `#${e.blockNumber}`}
                </td>
                <td>
                  <a href={explorerTx(e.txHash)} target="_blank" rel="noreferrer" title="View transaction">
                    <IconExternal style={{ width: 14, height: 14, opacity: 0.55 }} />
                  </a>
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
