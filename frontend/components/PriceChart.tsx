'use client'

import { useEffect, useRef, useState } from 'react'
import type { UTCTimestamp } from 'lightweight-charts'
import { useOraclePrices } from '@/hooks/useOraclePrices'

// We use CoinGecko public API for historical BTC price (no key needed for simple endpoint)
// In production this would come from our subgraph / Chainlink historical data

interface Candle {
  time: UTCTimestamp
  open: number
  high: number
  low: number
  close: number
}

export default function PriceChart() {
  const chartRef = useRef<HTMLDivElement>(null)
  const { mark, markDisplay } = useOraclePrices()
  const [chartReady, setChartReady] = useState(false)
  const [priceHistory, setPriceHistory] = useState<Candle[]>([])

  // Fetch 30-day BTC hourly OHLCV from CoinGecko (free, no key)
  useEffect(() => {
    async function fetchHistory() {
      try {
        const res = await fetch(
          'https://api.coingecko.com/api/v3/coins/bitcoin/ohlc?vs_currency=usd&days=7',
          { cache: 'force-cache' }
        )
        const raw: [number, number, number, number, number][] = await res.json()
        if (!Array.isArray(raw)) return
        const candles: Candle[] = raw.map(([ts, o, h, l, c]) => ({
          time: Math.floor(ts / 1000) as UTCTimestamp,
          open: o,
          high: h,
          low: l,
          close: c,
        }))
        // deduplicate by time
        const seen = new Set<number>()
        const deduped = candles.filter((c) => {
          if (seen.has(c.time)) return false
          seen.add(c.time)
          return true
        })
        deduped.sort((a, b) => a.time - b.time)
        setPriceHistory(deduped)
      } catch {
        // CoinGecko may rate-limit; silently ignore
      }
    }
    fetchHistory()
  }, [])

  useEffect(() => {
    if (!chartRef.current || priceHistory.length === 0) return

    let chart: ReturnType<typeof import('lightweight-charts').createChart> | null = null

    import('lightweight-charts').then(({ createChart, ColorType, CrosshairMode, CandlestickSeries }) => {
      if (!chartRef.current) return

      chart = createChart(chartRef.current, {
        layout: {
          background: { type: ColorType.Solid, color: '#111a15' },
          textColor: '#7a9e7a',
        },
        grid: {
          vertLines: { color: '#1e3327' },
          horzLines: { color: '#1e3327' },
        },
        crosshair: { mode: CrosshairMode.Normal },
        rightPriceScale: {
          borderColor: '#1e3327',
          textColor: '#7a9e7a',
        },
        timeScale: {
          borderColor: '#1e3327',
          timeVisible: true,
          secondsVisible: false,
        },
        width: chartRef.current.clientWidth,
        height: 380,
      })

      const series = chart.addSeries(CandlestickSeries, {
        upColor:   '#52b788',
        downColor: '#e55353',
        borderUpColor:   '#52b788',
        borderDownColor: '#e55353',
        wickUpColor:   '#52b788',
        wickDownColor: '#e55353',
      })

      series.setData(priceHistory)
      chart.timeScale().fitContent()
      setChartReady(true)

      // Resize observer
      const ro = new ResizeObserver(() => {
        if (chartRef.current && chart) {
          chart.applyOptions({ width: chartRef.current.clientWidth })
        }
      })
      if (chartRef.current) ro.observe(chartRef.current)

      return () => {
        ro.disconnect()
        chart?.remove()
      }
    })

    return () => {
      chart?.remove()
    }
  }, [priceHistory])

  return (
    <div
      style={{
        background: 'var(--bg-panel)',
        border: '1px solid var(--border)',
        borderRadius: '12px',
        overflow: 'hidden',
      }}
    >
      {/* Chart header */}
      <div
        style={{
          padding: '12px 16px',
          borderBottom: '1px solid var(--border)',
          display: 'flex',
          alignItems: 'center',
          gap: '16px',
        }}
      >
        <span style={{ fontWeight: 700, color: 'var(--text-main)', fontSize: '14px' }}>
          BTC / USD
        </span>
        <span
          style={{
            fontFamily: 'var(--font-geist-mono)',
            fontSize: '1.1rem',
            fontWeight: 700,
            color: 'var(--green-lite)',
          }}
        >
          {markDisplay}
        </span>
        <span style={{ fontSize: '11px', color: 'var(--text-muted)', marginLeft: 'auto' }}>
          7-day · Hourly (CoinGecko)
        </span>
      </div>

      {/* Chart area */}
      <div
        ref={chartRef}
        style={{
          width: '100%',
          height: '380px',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
        }}
      >
        {!chartReady && priceHistory.length === 0 && (
          <span style={{ color: 'var(--text-muted)', fontSize: '13px' }}>
            Loading chart data...
          </span>
        )}
      </div>
    </div>
  )
}
