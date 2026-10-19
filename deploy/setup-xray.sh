#!/usr/bin/env bash
# setup-xray.sh — generate the Xray server config from services/xray/config.example.json.
#
# Usage:
#   bash deploy/setup-xray.sh [config-path]    # default: /home/podman/services/data/xray/config.json
#
# Fresh credentials are generated (override with UUID= / TROJAN_PASSWORD= env vars),
# substituted into the template, validated with `xray run -test` in a throwaway
# container, then installed as the podman user. Existing configs are never
# overwritten — delete the file first if you really want a new one.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_DIR/services/xray/config.example.json"
OUT="${1:-${OUT:-/home/podman/services/data/xray/config.json}}"
IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:latest}"

if [ ! -f "$SRC" ]; then
	echo "missing template: $SRC" >&2
	exit 1
fi
if [ -e "$OUT" ]; then
	echo "refusing to overwrite existing $OUT (remove it first to regenerate)" >&2
	exit 1
fi
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

UUID="${UUID:-$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')}"
TROJAN_PASSWORD="${TROJAN_PASSWORD:-$(openssl rand -hex 24)}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"
sed -e "s|{{UUID}}|$UUID|g" -e "s|{{TROJAN_PASSWORD}}|$TROJAN_PASSWORD|g" "$SRC" > "$tmp"

# validate before installing (uses the caller's podman; skipped when unavailable).
# The image runs as uid 65532, so the temp copy must be world-readable during the
# test; it returns to 600 for the install step, which sets the final mode.
if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
	echo "==> validating config with $IMAGE"
	chmod 644 "$tmp"
	if ! podman run --rm -v "$tmp":/etc/xray/config.json:ro "$IMAGE" run -test -c /etc/xray/config.json; then
		echo "config validation failed — nothing installed" >&2
		exit 1
	fi
	chmod 600 "$tmp"
else
	echo "warning: podman unavailable, skipping validation" >&2
fi

out_dir="$(dirname "$OUT")"
if [ "$(id -u)" -eq 0 ]; then
	install -d -o podman -g podman -m 750 "$out_dir"
	install -o podman -g podman -m 644 "$tmp" "$OUT"
elif [ -d "$out_dir" ] && [ -w "$out_dir" ]; then
	install -m 644 "$tmp" "$OUT"
else
	sudo install -d -o podman -g podman -m 750 "$out_dir"
	sudo install -o podman -g podman -m 644 "$tmp" "$OUT"
fi

echo
echo "wrote $OUT (contains credentials; never commit)"
echo "  VLESS/VMess UUID : $UUID"
echo "  Trojan password  : $TROJAN_PASSWORD"
echo
echo "next: sudo -iu podman deploy xray"
