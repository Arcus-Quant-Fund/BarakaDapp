#!/usr/bin/env bash
# =============================================================================
# upload_fatwa.sh — Upload fatwa placeholder document to IPFS via Pinata
# =============================================================================
# Usage:
#   bash scripts/upload_fatwa.sh
#
# Prerequisites:
#   1. Set PINATA_JWT in BarakaDapp/.env  (get from https://app.pinata.cloud)
#   2. Run from anywhere — script finds its own root automatically
#
# Output:
#   Prints the IPFS CID (starts with Qm... or bafk...)
#   Copy it into scripts/update_fatwa.sh or run UpdateFatwa.s.sol directly.
# =============================================================================

set -euo pipefail

# ── Locate repo root ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

# ── Load .env ────────────────────────────────────────────────────────────────
ENV_FILE="$ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: $ENV_FILE not found" >&2
    exit 1
fi

# shellcheck disable=SC2046
export $(grep -v '^#' "$ENV_FILE" | grep '=' | xargs)

if [[ -z "${PINATA_JWT:-}" || "$PINATA_JWT" == "YOUR_PINATA_JWT" ]]; then
    echo ""
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║  PINATA_JWT not set in .env                              ║"
    echo "  ║                                                          ║"
    echo "  ║  Steps:                                                  ║"
    echo "  ║  1. Go to https://app.pinata.cloud                       ║"
    echo "  ║  2. Sign up / log in                                     ║"
    echo "  ║  3. API Keys → New Key → (Admin) → copy JWT              ║"
    echo "  ║  4. Edit BarakaDapp/.env:                                ║"
    echo "  ║       PINATA_JWT=eyJhbGciOi...                           ║"
    echo "  ║  5. Re-run this script                                   ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

FATWA_FILE="$ROOT/docs/fatwa_placeholder.md"
if [[ ! -f "$FATWA_FILE" ]]; then
    echo "ERROR: $FATWA_FILE not found" >&2
    exit 1
fi

echo ""
echo "  Uploading fatwa document to IPFS via Pinata..."
echo "  File: $FATWA_FILE"
echo ""

# ── Upload via Pinata v3 API ─────────────────────────────────────────────────
RESPONSE=$(curl -sS \
    --request POST \
    --url "https://uploads.pinata.cloud/v3/files" \
    --header "Authorization: Bearer $PINATA_JWT" \
    --form "file=@$FATWA_FILE;type=text/markdown" \
    --form 'name=baraka-protocol-fatwa-placeholder-v01' \
    --form 'keyvalues={"project":"baraka-protocol","version":"0.1","type":"fatwa-placeholder"}')

# ── Extract CID ──────────────────────────────────────────────────────────────
# Pinata v3 returns: {"data":{"cid":"Qm...", ...}}
CID=$(echo "$RESPONSE" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    # v3 API
    if 'data' in d and 'cid' in d['data']:
        print(d['data']['cid'])
    # v2 API fallback
    elif 'IpfsHash' in d:
        print(d['IpfsHash'])
    else:
        print('PARSE_ERROR: ' + json.dumps(d), file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print('ERROR: ' + str(e), file=sys.stderr)
    print('Raw response: ' + sys.stdin.read(), file=sys.stderr)
    sys.exit(1)
" 2>&1)

if [[ $CID == PARSE_ERROR* ]] || [[ $CID == ERROR* ]]; then
    echo "  ERROR parsing Pinata response:" >&2
    echo "  $CID" >&2
    echo "  Raw: $RESPONSE" >&2
    exit 1
fi

# ── Print result ─────────────────────────────────────────────────────────────
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  UPLOAD SUCCESSFUL                                       ║"
echo "  ╠══════════════════════════════════════════════════════════╣"
printf  "  ║  CID: %-51s║\n" "$CID"
echo "  ╠══════════════════════════════════════════════════════════╣"
echo "  ║  View:  https://gateway.pinata.cloud/ipfs/$CID"
echo "  ║                                                          ║"
echo "  ║  Next — update on-chain (run as DEPLOYER wallet):        ║"
echo "  ║                                                          ║"
printf  "  ║    FATWA_CID=%s \\\n" "$CID"
echo "  ║    forge script contracts/script/UpdateFatwa.s.sol \\     ║"
echo "  ║      --rpc-url arbitrum_sepolia --broadcast -vvv          ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Write CID to .cid file for the forge script to pick up ───────────────────
echo "$CID" > "$ROOT/.fatwa_cid"
echo "  CID saved to: $ROOT/.fatwa_cid"
echo "  (UpdateFatwa.s.sol reads this automatically)"
echo ""
