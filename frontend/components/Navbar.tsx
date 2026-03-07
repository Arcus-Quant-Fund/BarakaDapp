'use client'

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

  return (
    <nav
      style={{
        background: 'var(--bg-panel)',
        borderBottom: '1px solid var(--border)',
      }}
      className="sticky top-0 z-50"
    >
      <div className="max-w-7xl mx-auto px-4 h-14 flex items-center justify-between">
        {/* Logo */}
        <Link href="/" className="flex items-center gap-2 no-underline">
          <Image
            src="/baraka-logo.png"
            alt="Baraka"
            width={32}
            height={32}
            className="rounded-sm"
          />
          <span style={{ color: 'var(--text-main)' }} className="font-semibold text-sm">
            BARAKA
          </span>
          <span
            style={{
              background: 'var(--green-deep)',
              color: 'var(--green-lite)',
              fontSize: '10px',
              padding: '1px 6px',
              borderRadius: '4px',
              letterSpacing: '0.05em',
            }}
          >
            TESTNET
          </span>
        </Link>

        {/* Nav links */}
        <div className="flex items-center gap-1">
          {NAV_LINKS.map(({ href, label }) => {
            const active = pathname === href || pathname.startsWith(href + '/')
            return (
              <Link
                key={href}
                href={href}
                style={{
                  color: active ? 'var(--green-lite)' : 'var(--text-muted)',
                  background: active ? 'rgba(82,183,136,0.08)' : 'transparent',
                  padding: '4px 12px',
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

        {/* Wallet connect */}
        <ConnectButton
          accountStatus="avatar"
          chainStatus="icon"
          showBalance={false}
        />
      </div>
    </nav>
  )
}
