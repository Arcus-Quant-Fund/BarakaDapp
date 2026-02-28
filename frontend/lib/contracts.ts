// Deployed contract addresses — Arbitrum Sepolia (chainId 421614)
// Source: contracts/deployments/421614.json
// v2/v3 redeployed 2026-02-27 (OracleAdapter v2, CollateralVault v2, LiquidationEngine v2, PositionManager v3)

export const CONTRACTS = {
  OracleAdapter:     '0x86C475d9943ABC61870C6F19A7e743B134e1b563', // v2: kappa signal
  ShariahGuard:      '0x26d4db76a95DBf945ac14127a23Cd4861DA42e69',
  FundingEngine:     '0x459BE882BC8736e92AA4589D1b143e775b114b38',
  InsuranceFund:     '0x7B440af63D5fa5592E53310ce914A21513C1a716',
  CollateralVault:   '0x0e9e32e4e061Db57eE5d3309A986423A5ad3227E', // v2: chargeFromFree
  LiquidationEngine: '0x17D9399C7e17690bE23544E379907eC1AB6b7E07', // v2
  PositionManager:   '0x035E38fd8b34486530A4Cd60cE9D840e1a0A124a', // v3: BRKX fee system
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
  {
    // v2: returns (kappa, premium, regime) — kappa/premium in 1e18 scale, regime 0-3
    // NORMAL=0, ELEVATED=1, HIGH=2, CRITICAL=3
    name: 'getKappaSignal',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'market', type: 'address' }],
    outputs: [
      { name: 'kappa',   type: 'int256' },
      { name: 'premium', type: 'int256' },
      { name: 'regime',  type: 'uint8'  },
    ],
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

// ─────────────────────────────────────────────────────────
// Layer 2/3/4 Product Stack — deployed 2026-02-28
// Source: contracts/deployments/421614.json
// ─────────────────────────────────────────────────────────

// Product stack deployed 2026-02-28 to Arbitrum Sepolia
export const PRODUCT_CONTRACTS = {
  EverlastingOption: '0x977419b75182777c157E2192d4Ec2dC87413E006' as `0x${string}`,
  TakafulPool:       '0xD53d34cC599CfadB5D1f77516E7Eb326a08bb0E4' as `0x${string}`,
  PerpetualSukuk:    '0xd209f7B587c8301D5E4eC1691264deC1a560e48D' as `0x${string}`,
  iCDS:              '0xc4E8907619C8C02AF90D146B710306aB042c16c5' as `0x${string}`,
}

// BTC Takaful pool ID: keccak256("BTC-40k-USDC")
// cast keccak "BTC-40k-USDC" → confirmed matches Solidity keccak256(abi.encodePacked("BTC-40k-USDC"))
export const BTC_TAKAFUL_POOL_ID = '0xa62553efe090534f3bd23505218dd898105cb8863d630a8e01fae4e40ab72647' as `0x${string}`

// ERC20 approve ABI (used by sukuk/takaful/credit for token approvals)
export const ERC20_ABI = [
  {
    name: 'approve',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'value',   type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    name: 'allowance',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'owner',   type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'balanceOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

export const EVERLASTING_OPTION_ABI = [
  {
    // Quote everlasting put + call at current oracle spot
    name: 'quoteAtSpot',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'asset', type: 'address' },
      { name: 'kWad',  type: 'uint256' },
    ],
    outputs: [
      { name: 'putPriceWad',  type: 'uint256' },
      { name: 'callPriceWad', type: 'uint256' },
      { name: 'spotWad',      type: 'uint256' },
      { name: 'kappaWad',     type: 'uint256' },
      { name: 'betaNegWad',   type: 'int256'  },
      { name: 'betaPosWad',   type: 'int256'  },
    ],
  },
  {
    name: 'markets',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'asset', type: 'address' }],
    outputs: [
      { name: 'sigmaSquaredWad', type: 'uint256' },
      { name: 'kappaAnnualWad',  type: 'uint256' },
      { name: 'useOracleKappa',  type: 'bool'    },
      { name: 'active',          type: 'bool'    },
    ],
  },
] as const

export const TAKAFUL_POOL_ABI = [
  {
    name: 'pools',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [
      { name: 'asset',    type: 'address' },
      { name: 'token',    type: 'address' },
      { name: 'floorWad', type: 'uint256' },
      { name: 'active',   type: 'bool'    },
    ],
  },
  {
    name: 'poolBalance',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'members',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'poolId', type: 'bytes32' },
      { name: 'member', type: 'address' },
    ],
    outputs: [
      { name: 'totalCoverage', type: 'uint256' },
      { name: 'totalTabarru',  type: 'uint256' },
    ],
  },
  {
    name: 'totalClaimsPaid',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'getRequiredTabarru',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'poolId',         type: 'bytes32' },
      { name: 'coverageAmount', type: 'uint256' },
    ],
    outputs: [
      { name: 'tabarruGross', type: 'uint256' },
      { name: 'spotWad',      type: 'uint256' },
      { name: 'putRateWad',   type: 'uint256' },
    ],
  },
  {
    name: 'contribute',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'poolId',         type: 'bytes32' },
      { name: 'coverageAmount', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    name: 'ContributionMade',
    type: 'event',
    inputs: [
      { name: 'poolId',   type: 'bytes32', indexed: true  },
      { name: 'member',   type: 'address', indexed: true  },
      { name: 'coverage', type: 'uint256', indexed: false },
      { name: 'tabarru',  type: 'uint256', indexed: false },
      { name: 'wakala',   type: 'uint256', indexed: false },
    ],
  },
] as const

export const PERPETUAL_SUKUK_ABI = [
  {
    name: 'nextId',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'sukuks',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [
      { name: 'issuer',          type: 'address' },
      { name: 'asset',           type: 'address' },
      { name: 'token',           type: 'address' },
      { name: 'parValue',        type: 'uint256' },
      { name: 'profitRateWad',   type: 'uint256' },
      { name: 'maturityEpoch',   type: 'uint256' },
      { name: 'issuedAt',        type: 'uint256' },
      { name: 'totalSubscribed', type: 'uint256' },
      { name: 'redeemed',        type: 'bool'    },
    ],
  },
  {
    name: 'subscriptions',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'id',       type: 'uint256' },
      { name: 'investor', type: 'address' },
    ],
    outputs: [
      { name: 'amount',       type: 'uint256' },
      { name: 'lastProfitAt', type: 'uint256' },
      { name: 'redeemed',     type: 'bool'    },
    ],
  },
  {
    name: 'getAccruedProfit',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'id',       type: 'uint256' },
      { name: 'investor', type: 'address' },
    ],
    outputs: [{ name: 'accrued', type: 'uint256' }],
  },
  {
    name: 'getEmbeddedCallValue',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'id',       type: 'uint256' },
      { name: 'investor', type: 'address' },
    ],
    outputs: [
      { name: 'callRateWad', type: 'uint256' },
      { name: 'callUpside',  type: 'uint256' },
    ],
  },
  {
    name: 'issue',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'asset',          type: 'address' },
      { name: 'token',          type: 'address' },
      { name: 'parValue',       type: 'uint256' },
      { name: 'profitRateWad',  type: 'uint256' },
      { name: 'maturityEpoch',  type: 'uint256' },
    ],
    outputs: [{ name: 'id', type: 'uint256' }],
  },
  {
    name: 'subscribe',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'id',     type: 'uint256' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    name: 'claimProfit',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [],
  },
  {
    name: 'redeem',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [],
  },
  {
    name: 'SukukIssued',
    type: 'event',
    inputs: [
      { name: 'id',             type: 'uint256', indexed: true  },
      { name: 'issuer',         type: 'address', indexed: true  },
      { name: 'asset',          type: 'address', indexed: false },
      { name: 'token',          type: 'address', indexed: false },
      { name: 'par',            type: 'uint256', indexed: false },
      { name: 'profitRateWad',  type: 'uint256', indexed: false },
      { name: 'maturityEpoch',  type: 'uint256', indexed: false },
    ],
  },
] as const

export const ICDS_ABI = [
  {
    name: 'protections',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [
      { name: 'seller',            type: 'address' },
      { name: 'buyer',             type: 'address' },
      { name: 'refAsset',          type: 'address' },
      { name: 'token',             type: 'address' },
      { name: 'notional',          type: 'uint256' },
      { name: 'recoveryRateWad',   type: 'uint256' },
      { name: 'recoveryFloorWad',  type: 'uint256' },
      { name: 'tenorEnd',          type: 'uint256' },
      { name: 'lastPremiumAt',     type: 'uint256' },
      { name: 'premiumsCollected', type: 'uint256' },
      { name: 'status',            type: 'uint8'   },  // 0=Open 1=Active 2=Triggered 3=Settled 4=Expired
    ],
  },
  {
    name: 'computePremium',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [{ name: 'premium', type: 'uint256' }],
  },
  {
    name: 'openProtection',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'refAsset',        type: 'address' },
      { name: 'token',           type: 'address' },
      { name: 'notional',        type: 'uint256' },
      { name: 'recoveryRateWad', type: 'uint256' },
      { name: 'tenorDays',       type: 'uint256' },
    ],
    outputs: [{ name: 'id', type: 'uint256' }],
  },
  {
    name: 'acceptProtection',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [],
  },
  {
    name: 'payPremium',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [],
  },
  {
    name: 'settle',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [],
  },
  {
    name: 'expire',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [],
  },
  {
    name: 'ProtectionOpened',
    type: 'event',
    inputs: [
      { name: 'id',       type: 'uint256', indexed: true  },
      { name: 'seller',   type: 'address', indexed: true  },
      { name: 'refAsset', type: 'address', indexed: false },
      { name: 'token',    type: 'address', indexed: false },
      { name: 'notional', type: 'uint256', indexed: false },
      { name: 'tenorEnd', type: 'uint256', indexed: false },
    ],
  },
] as const
