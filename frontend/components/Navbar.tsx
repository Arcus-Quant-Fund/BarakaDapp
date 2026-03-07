'use client'

import { useState } from 'react'
import Link from 'next/link'
import Image from 'next/image'
import { usePathname } from 'next/navigation'
import { ConnectButton } from '@rainbow-me/rainbowkit'

const NAV_LINKS = [
  { href: '/trade',        label: 'Trade' },
  { href: '/markets',      label: 'Markets' },
  { href: '/sukuk',        label: 'Sukuk' },
  { href: '/takaful',      label: 'Takaful' },
  { href: '/credit',       label: 'Credit' },
  { href: '/dashboard',    label: 'Dashboard' },
  { href: '/transparency', label: 'Transparency' },
]

export default function Navbar() {
  const pathname = usePathname()
  const [mobileOpen, setMobileOpen] = useState(false)

  return (
    <>
      <nav
        style={{
          background: 'rgba(10,15,13,0.85)',
          backdropFilter: 'blur(12px)',
          borderBottom: '1px solid var(--border)',
        }}
        className="sticky top-0 z-50"
      >
        <div className="max-w-7xl mx-auto px-4 h-14 flex items-center justify-between">
          {/* Logo */}
          <Link href="/" className="flex items-center gap-2.5 no-underline">
            <Image
              src="/baraka-logo.png"
              alt="Baraka"
              width={30}
              height={30}
              className="rounded-sm"
            />
            <span style={{ color: 'var(--text-main)' }} className="font-bold text-sm tracking-wide">
              BARAKA
            </span>
            <span
              style={{
                background: 'var(--green-deep)',
                color: 'var(--green-lite)',
                fontSize: '9px',
                padding: '2px 6px',
                borderRadius: '4px',
                letterSpacing: '0.08em',
                fontWeight: 600,
              }}
            >
              TESTNET
            </span>
          </Link>

          {/* Desktop nav links */}
          <div className="nav-links flex items-center gap-1">
            {NAV_LINKS.map(({ href, label }) => {
              const active = pathname === href || pathname.startsWith(href + '/')
              return (
                <Link
                  key={href}
                  href={href}
                  style={{
                    color: active ? 'var(--green-lite)' : 'var(--text-muted)',
                    background: active ? 'rgba(82,183,136,0.08)' : 'transparent',
                    padding: '6px 12px',
                    borderRadius: '6px',
                    fontSize: '13px',
                    fontWeight: active ? 600 : 400,
                    textDecoration: 'none',
                    transition: 'all 0.15s',
                  }}
                >
                  {label}
                </Link>
              )
            })}
          </div>

          {/* Wallet connect + mobile button */}
          <div className="flex items-center gap-3">
            <ConnectButton
              accountStatus="avatar"
              chainStatus="icon"
              showBalance={false}
            />
            <button
              className="mobile-menu-btn items-center justify-center"
              onClick={() => setMobileOpen(!mobileOpen)}
              style={{
                background: 'transparent',
                border: '1px solid var(--border)',
                borderRadius: '6px',
                padding: '6px 8px',
                color: 'var(--text-muted)',
                cursor: 'pointer',
              }}
            >
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                {mobileOpen
                  ? <path d="M18 6L6 18M6 6l12 12" />
                  : <path d="M3 12h18M3 6h18M3 18h18" />}
              </svg>
            </button>
          </div>
        </div>
      </nav>

      {/* Mobile nav dropdown */}
      {mobileOpen && (
        <div
          className="mobile-nav"
          style={{
            position: 'fixed',
            top: '56px',
            left: 0,
            right: 0,
            bottom: 0,
            background: 'rgba(10,15,13,0.97)',
            backdropFilter: 'blur(12px)',
            zIndex: 49,
            padding: '16px',
            display: 'flex',
            flexDirection: 'column',
            gap: '4px',
          }}
        >
          {NAV_LINKS.map(({ href, label }) => {
            const active = pathname === href
            return (
              <Link
                key={href}
                href={href}
                onClick={() => setMobileOpen(false)}
                style={{
                  color: active ? 'var(--green-lite)' : 'var(--text-main)',
                  background: active ? 'rgba(82,183,136,0.08)' : 'transparent',
                  padding: '12px 16px',
                  borderRadius: '8px',
                  fontSize: '15px',
                  fontWeight: active ? 600 : 400,
                  textDecoration: 'none',
                  borderBottom: '1px solid var(--border)',
                }}
              >
                {label}
              </Link>
            )
          })}
        </div>
      )}
    </>
  )
}
