import type { Metadata } from 'next'
import { Geist, Geist_Mono } from 'next/font/google'
import './globals.css'
import Providers from '@/components/Providers'
import Navbar from '@/components/Navbar'

const geistSans = Geist({ variable: '--font-geist-sans', subsets: ['latin'] })
const geistMono = Geist_Mono({ variable: '--font-geist-mono', subsets: ['latin'] })

export const metadata: Metadata = {
  title: 'Baraka Protocol — Shariah-Compliant Perpetuals',
  description:
    'Trade Bitcoin perpetual futures with zero interest (ι=0), Islamic-compliant funding mechanics, and full on-chain transparency. Powered by Ackerer et al. (2024) mathematical proof.',
  keywords: ['Islamic DeFi', 'halal crypto', 'shariah perpetuals', 'baraka protocol', 'ι=0 funding'],
  openGraph: {
    title: 'Baraka Protocol',
    description: 'Shariah-compliant perpetual futures. ι=0, proven on-chain.',
    type: 'website',
  },
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className={`${geistSans.variable} ${geistMono.variable} antialiased`}>
        <Providers>
          <Navbar />
          {children}
        </Providers>
      </body>
    </html>
  )
}
