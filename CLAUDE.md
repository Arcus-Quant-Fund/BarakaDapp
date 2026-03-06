# Baraka Protocol — Claude Instructions

## Read first
1. `STATUS.md` — current state, what's live, what's next
2. `plan/next/CHECKLIST.md` — full build checklist
3. `plan/next/SESSION_LOG.md` — last session's work

## Division context
This directory covers two divisions:
- **Baraka Protocol** — DeFi smart contracts, frontend, subgraph
- **Arcus Research** — Academic papers in `papers/`, simulations in `simulations/`

## Critical rules — do NOT violate

1. **wagmi version**: Stay at wagmi@2.19.5. RainbowKit 2.x requires wagmi ^2.9.0. v3 breaks it.

2. **Solidity — no Unicode ι**: Use ASCII "iota=0" in string literals, not the Greek character.

3. **lightweight-charts API**: Use `chart.addSeries(CandlestickSeries, opts)` — not `addCandlestickSeries` (removed in v5).

4. **Slither in CI**: Any HIGH or MEDIUM finding fails the pipeline (`--fail-high --fail-medium`). Fix before pushing.

5. **Contracts are NOT upgradeable**: Immutable deploys. Any contract change = new address. Update `deployments/421614.json` and all downstream references (subgraph.yaml, frontend contracts.ts, transparency page).

6. **PositionManager posId**: `keccak256(msg.sender, asset, token, block.timestamp, block.number)` — closePosition via forge broadcast fails due to double-simulation. Test close in unit tests only.

7. **EverlastingOption prices**: `quotePut`/`quoteCall` return ABSOLUTE WAD prices (~$27k/unit at BTC params), not percentages.

8. **API keys**: All in `BarakaDapp/.env` — never commit. Extract Pinata JWT with `grep "^PINATA_JWT=" .env | cut -d'=' -f2-` (too long for direct env sourcing).

## Key contract addresses (Arbitrum Sepolia)
See `contracts/deployments/421614.json` for all 13. Core:
- PositionManager v4: `0x5a8b09cc1EE6462fCc34311A08770336C2b05d31`
- CollateralVault v2: `0x0e9e32e4e061Db57eE5d3309A986423A5ad3227E`
- ShariahGuard: `0x26d4db76a95DBf945ac14127a23Cd4861DA42e69`

## Key files
- `contracts/src/` — 13 Solidity contracts
- `contracts/deployments/421614.json` — deployed addresses
- `frontend/lib/contracts.ts` — addresses for frontend hooks
- `subgraph/subgraph.yaml` — data sources (must match deployed addresses)
- `docs/SECURITY_AUDIT_SCOPE.md` — audit scope doc (for security firms)
- `papers/` — LaTeX research papers (paper1, paper2, paper3)
- `simulations/` — cadCAD + RL + game theory + mechanism design

## Deployment commands
```bash
# Contracts
cd contracts && forge build && forge test -vvv

# Frontend
cd frontend && npm run build && vercel deploy --prod --token <token> --scope shehzadahmed-xxs-projects

# Subgraph
cd subgraph && npx graph auth <key> && npx graph deploy arcus --version-label vX.X.X
```
