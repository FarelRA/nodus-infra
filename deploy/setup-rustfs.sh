#!/usr/bin/env bash
# setup-rustfs.sh — generate data/rustfs/.env with fresh S3 credentials.
#
# Usage:
#   bash deploy/setup-rustfs.sh [env-path]
#
# Existing files are kept, so this is safe to re-run from deploy/setup.sh.
# Override the generated values with RUSTFS_ACCESS_KEY= / RUSTFS_SECRET_KEY=.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SRC="$REPO_DIR/services/env/rustfs.env.example"
OUT="${1:-${OUT:-$DATA_DIR/rustfs/.env}}"

if [ -e "$OUT" ]; then
	keep_existing "$OUT"
	exit 0
fi

need_cmd openssl
ACCESS="${RUSTFS_ACCESS_KEY:-$(new_hex 20)}"
SECRET="${RUSTFS_SECRET_KEY:-$(new_hex 32)}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed -e "s|{{RUSTFS_ACCESS_KEY}}|$ACCESS|g" \
	-e "s|{{RUSTFS_SECRET_KEY}}|$SECRET|g" \
	"$SRC" >"$tmp"
if grep -q '{{' "$tmp"; then
	die "unrendered placeholder in $SRC"
fi

install_file "$tmp" "$OUT" 600

echo
echo "wrote $OUT (600, contains credentials; never commit)"
echo "  RUSTFS_ACCESS_KEY: $ACCESS"
echo "  RUSTFS_SECRET_KEY: $SECRET"
