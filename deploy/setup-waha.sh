#!/usr/bin/env bash
# setup-waha.sh — generate WAHA's API and dashboard/swagger credentials.
#
# Usage:
#   bash deploy/setup-waha.sh [env-path]
#
# Existing files are kept; remove one to regenerate it.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

OUT="${1:-${OUT:-$DATA_DIR/waha/.env}}"
if [ -e "$OUT" ]; then
	keep_existing "$OUT"
	exit 0
fi

need_cmd openssl

API_KEY="${WAHA_API_KEY:-$(new_hex 32)}"
DASHBOARD_PASSWORD="${WAHA_DASHBOARD_PASSWORD:-$(new_hex 12)}"
SWAGGER_PASSWORD="${WHATSAPP_SWAGGER_PASSWORD:-$(new_hex 12)}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed -e "s|{{WAHA_API_KEY}}|$API_KEY|g" \
	-e "s|{{WAHA_DASHBOARD_PASSWORD}}|$DASHBOARD_PASSWORD|g" \
	-e "s|{{WHATSAPP_SWAGGER_PASSWORD}}|$SWAGGER_PASSWORD|g" \
	"$REPO_DIR/services/env/waha.env.example" >"$tmp"
if grep -q '{{' "$tmp"; then
	die "unrendered placeholder in services/env/waha.env.example"
fi

install_file "$tmp" "$OUT" 600

echo
echo "wrote $OUT (600, contains credentials; never commit)"
echo "  WAHA API key        : $API_KEY"
echo "  Dashboard login     : farel / $DASHBOARD_PASSWORD"
echo "  Swagger login       : farel / $SWAGGER_PASSWORD"
