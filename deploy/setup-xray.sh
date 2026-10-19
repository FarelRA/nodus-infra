#!/usr/bin/env bash
# setup-xray.sh — generate the Xray server config from services/xray/config.example.json.
#
# Usage:
#   bash deploy/setup-xray.sh [config-path]    # default: data/xray/config.json
#
# Fresh credentials are generated (override with UUID= / TROJAN_PASSWORD=),
# substituted into the template, validated with `xray run -test` in a throwaway
# container, then installed as the podman user. Existing configs are kept.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SRC="$REPO_DIR/services/xray/config.example.json"
OUT="${1:-${OUT:-$DATA_DIR/xray/config.json}}"
IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:latest}"

[ -f "$SRC" ] || die "missing template: $SRC"
if [ -e "$OUT" ]; then
	keep_existing "$OUT"
	exit 0
fi

need_cmd openssl
UUID="${UUID:-$(new_uuid)}"
TROJAN_PASSWORD="${TROJAN_PASSWORD:-$(new_hex 24)}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"
sed -e "s|{{UUID}}|$UUID|g" -e "s|{{TROJAN_PASSWORD}}|$TROJAN_PASSWORD|g" "$SRC" >"$tmp"
if grep -q '{{' "$tmp"; then
	die "unrendered placeholder in $SRC"
fi

# The image runs as uid 65532, so the temp copy must be world-readable during
# the test; it returns to 600 for the install step, which sets the final mode.
if command -v podman >/dev/null 2>&1 && id "$PODMAN_USER" >/dev/null 2>&1 && run_as_podman podman info >/dev/null 2>&1; then
	note "validating config with $IMAGE (as $PODMAN_USER)"
	chmod 644 "$tmp"
	if ! run_as_podman podman run --rm -v "$tmp":/etc/xray/config.json:ro "$IMAGE" run -test -c /etc/xray/config.json; then
		die "config validation failed — nothing installed"
	fi
	chmod 600 "$tmp"
elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
	note "validating config with $IMAGE"
	chmod 644 "$tmp"
	if ! podman run --rm -v "$tmp":/etc/xray/config.json:ro "$IMAGE" run -test -c /etc/xray/config.json; then
		die "config validation failed — nothing installed"
	fi
	chmod 600 "$tmp"
else
	echo "warning: podman unavailable, skipping validation" >&2
fi

install_file "$tmp" "$OUT" 644

echo
echo "wrote $OUT (contains credentials; never commit)"
echo "  VLESS/VMess UUID : $UUID"
echo "  Trojan password  : $TROJAN_PASSWORD"
echo
echo "next: sudo -iu podman deploy xray"
