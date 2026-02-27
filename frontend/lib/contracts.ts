// Deployed contract addresses — Arbitrum Sepolia (chainId 421614)
// Source: contracts/deployments/421614.json
// PositionManager upgraded 2026-02-27 (added BRKX fee system)

export const CONTRACTS = {
  OracleAdapter:     '0xB8d9778288B96ee5a9d873F222923C0671fc38D4',
  ShariahGuard:      '0x26d4db76a95DBf945ac14127a23Cd4861DA42e69',
  FundingEngine:     '0x459BE882BC8736e92AA4589D1b143e775b114b38',
  InsuranceFund:     '0x7B440af63D5fa5592E53310ce914A21513C1a716',
  CollateralVault:   '0x5530e4670523cFd1A60dEFbB123f51ae6cae0c5E',
  LiquidationEngine: '0x456eBE7BbCb099E75986307E4105A652c108b608',
  PositionManager:   '0x787E15807f32f84aC3D929CB136216897b788070',
  GovernanceModule:  '0x8c987818dffcD00c000Fe161BFbbD414B0529341',
  BRKXToken:         '0xD3f7E29cAC5b618fAB44Dd8a64C4CC335C154A32',
} as const

export const ARBISCAN_BASE = 'https://sepolia.arbiscan.io'

// BTC market identifier — WBTC address used as a consistent market key in OracleAdapter/ShariahGuard
export const BTC_ASSET_ADDRESS = '0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f' as const

// Arbitrum Sepolia USDC (Circle official testnet deployment)
export const USDC_ADDRESS = '0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d' as const

// TWAP window passed to getMarkPrice (30 minutes in seconds)
export const TWAP_WINDOW = 1800n

// ─────────────────────────────────────────────────────────
// ABIs — only functions/events the frontend calls
// Prices: OracleAdapter normalises Chainlink to 1e18 scale
// Collateral: USDC 6 decimals
// ─────────────────────────────────────────────────────────

export const FUNDING_ENGINE_ABI = [
  {
    name: 'getFundingRate',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'market', type: 'address' }],
    outputs: [{ name: 'fundingRate', type: 'int256' }],
  },
  {
    name: 'lastFundingTime',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'market', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'MAX_FUNDING_RATE',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'int256' }],
  },
] as const

export const ORACLE_ADAPTER_ABI = [
  {
    // Returns 1e18-scaled mark price (TWAP over twapWindow seconds)
    name: 'getMarkPrice',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'asset', type: 'address' },
      { name: 'twapWindow', type: 'uint256' },
    ],
    outputs: [{ name: 'price', type: 'uint256' }],
  },
  {
    // Returns 1e18-scaled index price (dual-Chainlink weighted average)
    name: 'getIndexPrice',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'asset', type: 'address' }],
    outputs: [{ name: 'price', type: 'uint256' }],
  },
] as const

export const COLLATERAL_VAULT_ABI = [
  {
    name: 'deposit',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    name: 'withdraw',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    // total balance (free + locked) — use for display
    name: 'balance',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'user', type: 'address' },
      { name: 'token', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    // free (withdrawable) balance
    name: 'freeBalance',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'user', type: 'address' },
      { name: 'token', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

export const POSITION_MANAGER_ABI = [
  {
    name: 'openPosition',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'asset',           type: 'address' },
      { name: 'collateralToken', type: 'address' },
      { name: 'collateral',      type: 'uint256' },
      { name: 'leverage',        type: 'uint256' },
      { name: 'isLong',          type: 'bool' },
    ],
    outputs: [{ name: 'positionId', type: 'bytes32' }],
  },
  {
    name: 'closePosition',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'positionId', type: 'bytes32' }],
    outputs: [],
  },
  {
    name: 'getPosition',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'positionId', type: 'bytes32' }],
    outputs: [
      {
        name: 'pos',
        type: 'tuple',
        components: [
          { name: 'trader',           type: 'address' },
          { name: 'asset',            type: 'address' },
          { name: 'collateralToken',  type: 'address' },
          { name: 'size',             type: 'uint256' },
          { name: 'collateral',       type: 'uint256' },
          { name: 'entryPrice',       type: 'uint256' },
          { name: 'fundingIndexAtOpen', type: 'int256' },
          { name: 'openBlock',        type: 'uint256' },
          { name: 'openTimestamp',    type: 'uint256' },
          { name: 'isLong',           type: 'bool' },
          { name: 'open',             type: 'bool' },
        ],
      },
    ],
  },
  {
    name: 'PositionOpened',
    type: 'event',
    inputs: [
      { name: 'positionId',     type: 'bytes32', indexed: true },
      { name: 'trader',         type: 'address', indexed: true },
      { name: 'asset',          type: 'address', indexed: true },
      { name: 'collateralToken',type: 'address', indexed: false },
      { name: 'size',           type: 'uint256', indexed: false },
      { name: 'collateral',     type: 'uint256', indexed: false },
      { name: 'entryPrice',     type: 'uint256', indexed: false },
      { name: 'isLong',         type: 'bool',    indexed: false },
    ],
  },
] as const

export const INSURANCE_FUND_ABI = [
  {
    name: 'fundBalance',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'token', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

export const BRKX_TOKEN_ABI = [
  {
    name: 'balanceOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'totalSupply',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'transfer',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'to', type: 'address' },
      { name: 'value', type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    // FeeCollected(trader, token, amount, feeBps) — emitted by PositionManager
    name: 'FeeCollected',
    type: 'event',
    inputs: [
      { name: 'trader', type: 'address', indexed: true },
      { name: 'token',  type: 'address', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
      { name: 'feeBps', type: 'uint256', indexed: false },
    ],
  },
] as const

// BRKX fee tier thresholds (in 18-decimal units)
export const BRKX_TIERS = [
  { minBrkx: 50_000n * 10n ** 18n, feeBps: 25, label: '2.5 bps' },
  { minBrkx: 10_000n * 10n ** 18n, feeBps: 35, label: '3.5 bps' },
  { minBrkx:  1_000n * 10n ** 18n, feeBps: 40, label: '4.0 bps' },
  { minBrkx:          0n,           feeBps: 50, label: '5.0 bps' },
] as const
