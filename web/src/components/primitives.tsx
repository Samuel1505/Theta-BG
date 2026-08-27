import { useState, type ReactNode } from 'react'
import { explorerAddress } from '../config/contracts'
import { shortAddress } from '../lib/format'
import { IconCopy, IconCheck, IconExternal, IconInbox } from './icons'

/* ── Address pill ──────────────────────────────────────────── */
export function Address({
  address,
  chars = 4,
  link = true,
  label,
}: {
  address?: string | null
  chars?: number
  link?: boolean
  label?: string
}) {
  const [copied, setCopied] = useState(false)
  if (!address) return <span className="muted mono">—</span>

  const copy = (e: React.MouseEvent) => {
    e.preventDefault()
    e.stopPropagation()
    navigator.clipboard?.writeText(address).then(() => {
      setCopied(true)
      window.setTimeout(() => setCopied(false), 1200)
    })
  }

  const inner = (
    <>
      <span>{label ?? shortAddress(address, chars)}</span>
      <button
        onClick={copy}
        title="Copy address"
        style={{ background: 'none', border: 'none', padding: 0, color: 'inherit', display: 'inline-flex' }}
      >
        {copied ? <IconCheck /> : <IconCopy />}
      </button>
      {link ? <IconExternal /> : null}
    </>
  )

  return link ? (
    <a className="addr" href={explorerAddress(address)} target="_blank" rel="noreferrer">
      {inner}
    </a>
  ) : (
    <span className="addr">{inner}</span>
  )
}

/* ── Card ─────────────────────────────────────────────────── */
export function Card({
  title,
  subtitle,
  action,
  flush,
  children,
}: {
  title?: ReactNode
  subtitle?: ReactNode
  action?: ReactNode
  flush?: boolean
  children: ReactNode
}) {
  return (
    <div className="card">
      {(title || action) && (
        <div className="card__head">
          <div>
            {title ? <h3>{title}</h3> : null}
            {subtitle ? <p>{subtitle}</p> : null}
          </div>
          {action ? <div>{action}</div> : null}
        </div>
      )}
      <div className={flush ? 'card__body card__body--flush' : 'card__body'}>{children}</div>
    </div>
  )
}

/* ── Stat tile ────────────────────────────────────────────── */
export function Stat({
  label,
  value,
  unit,
  sub,
  tone,
  loading,
}: {
  label: ReactNode
  value: ReactNode
  unit?: ReactNode
  sub?: ReactNode
  tone?: 'accent' | 'danger'
  loading?: boolean
}) {
  return (
    <div className="stat">
      <div className="stat__label">{label}</div>
      <div className={`stat__value${tone ? ` stat__value--${tone}` : ''}`}>
        {loading ? <span className="skeleton" style={{ width: 90 }}>0.000</span> : value}
        {unit && !loading ? <span className="stat__unit">{unit}</span> : null}
      </div>
      {sub ? <div className="stat__sub">{loading ? <span className="skeleton" style={{ width: 120 }}>loading</span> : sub}</div> : null}
    </div>
  )
}

/* ── Key/value list ───────────────────────────────────────── */
export function KV({ children }: { children: ReactNode }) {
  return <div className="kv">{children}</div>
}
export function KVRow({ k, children }: { k: ReactNode; children: ReactNode }) {
  return (
    <div className="kv__row">
      <span className="kv__key">{k}</span>
      <span className="kv__val">{children}</span>
    </div>
  )
}

/* ── Tag ──────────────────────────────────────────────────── */
export function Tag({
  children,
  tone,
  dot,
}: {
  children: ReactNode
  tone?: 'accent' | 'danger' | 'warn' | 'info'
  dot?: boolean
}) {
  return (
    <span className={`tag${tone ? ` tag--${tone}` : ''}`}>
      {dot ? <span className="tag__dot" /> : null}
      {children}
    </span>
  )
}

/* ── Callout ──────────────────────────────────────────────── */
export function Callout({
  tone = 'info',
  icon,
  children,
}: {
  tone?: 'info' | 'warn' | 'danger' | 'neutral'
  icon?: ReactNode
  children: ReactNode
}) {
  return (
    <div className={`callout${tone !== 'neutral' ? ` callout--${tone}` : ''}`}>
      {icon}
      <div>{children}</div>
    </div>
  )
}

/* ── Empty state ──────────────────────────────────────────── */
export function Empty({ children }: { children: ReactNode }) {
  return (
    <div className="empty">
      <IconInbox />
      <div>{children}</div>
    </div>
  )
}

/* ── Skeleton line ────────────────────────────────────────── */
export function SkeletonText({ width = 80 }: { width?: number | string }) {
  return (
    <span className="skeleton" style={{ width }}>
      &nbsp;
    </span>
  )
}
