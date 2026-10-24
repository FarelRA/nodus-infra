#!/usr/bin/env bash
# Setup-growmate.sh generates the GrowMate app runtime env.
#
# Usage:
#   bash deploy/setup-growmate.sh [env-path]
#
# Reuses the RustFS credentials from data/rustfs/.env so the app and the store
# always agree. Existing files are kept; remove one to regenerate it.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

OUT="${1:-${OUT:-$DATA_DIR/growmate/.env}}"
if [ -e "$OUT" ]; then
	keep_existing "$OUT"
	exit 0
fi

need_cmd openssl

RUSTFS_ENV="$DATA_DIR/rustfs/.env"
[ -f "$RUSTFS_ENV" ] || die "missing $RUSTFS_ENV; run deploy/setup-rustfs.sh first"
ACCESS="$(env_value "$RUSTFS_ENV" RUSTFS_ACCESS_KEY)"
SECRET="$(env_value "$RUSTFS_ENV" RUSTFS_SECRET_KEY)"
[ -n "$ACCESS" ] && [ -n "$SECRET" ] || die "missing RustFS credentials in $RUSTFS_ENV"

DEVICE_KEY="${DEVICE_API_KEY:-$(new_hex 32)}"
DEMO_TOKEN="${DEMO_ACCESS_TOKEN:-$(new_hex 16)}"
DEMO_PASSWORD="${DEMO_PASSWORD:-$(new_hex 12)}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed -e "s|{{RUSTFS_ACCESS_KEY}}|$ACCESS|g" \
	-e "s|{{RUSTFS_SECRET_KEY}}|$SECRET|g" \
	-e "s|{{DEVICE_API_KEY}}|$DEVICE_KEY|g" \
	-e "s|{{DEMO_ACCESS_TOKEN}}|$DEMO_TOKEN|g" \
	-e "s|{{DEMO_PASSWORD}}|$DEMO_PASSWORD|g" \
	"$REPO_DIR/services/env/growmate.env.example" >"$tmp"
if grep -q '{{' "$tmp"; then
	die "unrendered placeholder in services/env/growmate.env.example"
fi

install_file "$tmp" "$OUT" 600

echo
echo "wrote $OUT (600, contains credentials; never commit)"
echo "  Demo login : https://growmate.bond/demo/$DEMO_TOKEN"
echo "  Demo email : demo@growmate.bond"
echo "  Demo pass  : $DEMO_PASSWORD"
echo "  Device key : $DEVICE_KEY"
echo
echo "After the Convex backend is up, set the function env from the app repo"
echo "(see services/growmate/convex.env.example):"
echo "  bunx convex env set RUSTFS_ENDPOINT http://rustfs:9000"
echo "  bunx convex env set RUSTFS_ACCESS_KEY $ACCESS"
echo "  bunx convex env set RUSTFS_SECRET_KEY $SECRET"
echo "  bunx convex env set RUSTFS_BUCKET_IMAGE images"
