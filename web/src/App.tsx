import { useState } from 'react'
import { NavLink, Route, Routes, useLocation } from 'react-router-dom'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import { useAccount } from 'wagmi'

import { CHAIN_ID } from './config/contracts'
import { IconBook, IconBolt, IconDroplet, IconGauge, IconMenu, IconShield } from './components/icons'
import { Overview } from './views/Overview'
import { Dashboard } from './views/Dashboard'
import { Searchers } from './views/Searchers'
import { Vault } from './views/Vault'
import { Mechanism } from './views/Mechanism'

interface NavItem {
  to: string
  label: string
  icon: (p: { className?: string }) => React.ReactElement
  end: boolean
  title: string
  sub: string
}

const NAV: NavItem[] = [
  { to: '/', label: 'Overview', icon: IconBolt, end: true, title: 'Overview', sub: 'What Theta-BG does' },
  { to: '/dashboard', label: 'Protocol', icon: IconGauge, end: false, title: 'Protocol Dashboard', sub: 'Live pool, vault & activity' },
  { to: '/searchers', label: 'Searchers', icon: IconShield, end: false, title: 'Bonded Searchers', sub: 'Post, top up & withdraw a bond' },
  { to: '/vault', label: 'LP Vault', icon: IconDroplet, end: false, title: 'LP Insurance Vault', sub: 'Claim your share of slashed bonds' },
  { to: '/mechanism', label: 'Mechanism', icon: IconBook, end: false, title: 'How It Works', sub: 'The predicate & bond economics' },
]

export function App() {
  const { chainId, isConnected } = useAccount()
  const location = useLocation()
  const [menuOpen, setMenuOpen] = useState(false)
  const closeMenu = () => setMenuOpen(false)

  const current = [...NAV].reverse().find((n) => (n.end ? location.pathname === n.to : location.pathname.startsWith(n.to)))
  const wrongChain = isConnected && chainId !== CHAIN_ID

  return (
    <div className="app">
      <div className={menuOpen ? 'scrim scrim--show' : 'scrim'} onClick={() => setMenuOpen(false)} />
      <aside className={menuOpen ? 'sidebar sidebar--open' : 'sidebar'}>
        <div className="brand">
          <svg className="brand__mark" viewBox="0 0 48 48" fill="none" aria-hidden>
            <rect width="48" height="48" rx="11" fill="#101216" />
            <circle cx="24" cy="24" r="14" stroke="#3ddc97" strokeWidth="3.5" />
            <path d="M24 12v24M16 24h16" stroke="#3ddc97" strokeWidth="3.5" strokeLinecap="round" />
          </svg>
          <div>
            <div className="brand__name">Theta-BG</div>
            <div className="brand__sub">MEV Protection</div>
          </div>
        </div>

        <nav className="stack" style={{ gap: 2 }}>
          {NAV.map((n) => (
            <NavLink
              key={n.to}
              to={n.to}
              end={n.end}
              onClick={closeMenu}
              className={({ isActive }) => (isActive ? 'nav-link nav-link--active' : 'nav-link')}
            >
              <n.icon className="nav-link__icon" />
              {n.label}
            </NavLink>
          ))}
        </nav>

        <div className="sidebar__spacer" />
        <div className="sidebar__foot">
          Uniswap v4 hook · UHI10
          <br />
          <a href="https://sepolia.uniscan.xyz/address/0x9739f9f628e06b0f1da21a8ab841067856fa15c8" target="_blank" rel="noreferrer">
            Verified contracts ↗
          </a>
        </div>
      </aside>

      <div className="main">
        <header className="topbar">
          <div className="row" style={{ gap: 12 }}>
            <button className="menu-btn" onClick={() => setMenuOpen((v) => !v)} aria-label="Menu">
              <IconMenu />
            </button>
            <div className="topbar__title">
              <h1>{current?.title ?? 'Theta-BG'}</h1>
              <span>{current?.sub}</span>
            </div>
          </div>
          <div className="topbar__right">
            <span className={wrongChain ? 'net-badge net-badge--warn' : 'net-badge'}>
              <span className="net-badge__dot" />
              {wrongChain ? 'Wrong network' : 'Unichain Sepolia'}
            </span>
            <ConnectButton
              accountStatus="address"
              chainStatus="none"
              showBalance={{ smallScreen: false, largeScreen: true }}
            />
          </div>
        </header>

        <main className="content">
          <Routes>
            <Route path="/" element={<Overview />} />
            <Route path="/dashboard" element={<Dashboard />} />
            <Route path="/searchers" element={<Searchers />} />
            <Route path="/vault" element={<Vault />} />
            <Route path="/mechanism" element={<Mechanism />} />
            <Route path="*" element={<Overview />} />
          </Routes>
        </main>
      </div>
    </div>
  )
}
