#!/usr/bin/env bash
# ============================================================
# Baraka Protocol — Automated E2E Test
# Forks Arbitrum Sepolia and runs against live deployed contracts.
# No real transactions. Runs in ~15 seconds.
#
# Usage: bash e2e.sh
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$SCRIPT_DIR/contracts"

# ANSI colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║    BARAKA PROTOCOL — AUTOMATED E2E TEST SUITE            ║${NC}"
echo -e "${CYAN}${BOLD}║    Fork: Arbitrum Sepolia (chain 421614)                 ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Contracts  : live deployed (no redeploy)"
echo -e "  Mode       : Anvil fork — zero real gas spent"
echo -e "  Scenarios  : 6 tests across lifecycle, funding, liquidation, guard"
echo -e "  Estimated  : ~15–25 seconds"
echo ""

# ── Ensure Foundry is in PATH ──────────────────────────────────────────────
export PATH="$HOME/.foundry/bin:$PATH"

if ! command -v forge &>/dev/null; then
    echo -e "${RED}ERROR: forge not found.${NC}"
    echo -e "Install Foundry: curl -L https://foundry.paradigm.xyz | bash && foundryup"
    exit 1
fi

cd "$CONTRACTS_DIR"

# ── Step 1: Build ──────────────────────────────────────────────────────────
echo -e "${YELLOW}[1/2] Building contracts...${NC}"
forge build --quiet
echo -e "      done."
echo ""

# ── Step 2: Run E2E fork tests ─────────────────────────────────────────────
echo -e "${YELLOW}[2/2] Running E2E fork tests...${NC}"
echo ""

forge test \
    --match-path "test/e2e/E2EForkTest.t.sol" \
    --fork-url "https://arb-sepolia.g.alchemy.com/v2/<ALCHEMY_KEY>" \
    --gas-limit 30000000 \
    -vvv

EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║  ✅  ALL 6 E2E TESTS PASSED                              ║${NC}"
    echo -e "${GREEN}${BOLD}║  Baraka Protocol is live and working on testnet.         ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
else
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ❌  ONE OR MORE E2E TESTS FAILED                        ║${NC}"
    echo -e "${RED}${BOLD}║  See the forge output above for the failing assertion.   ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
fi

exit $EXIT_CODE
