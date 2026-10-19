#!/usr/bin/env bash
# setup-sing-box.sh — generate the sing-box config from services/sing-box/config.example.json.
#
# Usage:
#   bash deploy/setup-sing-box.sh [config-path]   # default: data/sing-box/config.json
#
# Fresh credentials are generated (override with UUID= / TROJAN_PASSWORD=),
# substituted into the template, validated with `sing-box check` in a throwaway
# container, then installed as the podman user. Existing configs are kept.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SRC="$REPO_DIR/services/sing-box/config.example.json"
OUT="${1:-${OUT:-$DATA_DIR/sing-box/config.json}}"
IMAGE="${SING_BOX_IMAGE:-ghcr.io/sagernet/sing-box:latest}"

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

# Validate with the same rootless runtime that will run the service. The temp
# file is chmod 644 only for the test, then restored to 600 for the install.
if command -v podman >/dev/null 2>&1 && id "$PODMAN_USER" >/dev/null 2>&1 && run_as_podman podman info >/dev/null 2>&1; then
	note "validating config with $IMAGE (as $PODMAN_USER)"
	chmod 644 "$tmp"
	if ! run_as_podman podman run --rm -v "$tmp":/etc/sing-box/config.json:ro "$IMAGE" check -c /etc/sing-box/config.json; then
		die "config validation failed — nothing installed"
	fi
	chmod 600 "$tmp"
elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
	note "validating config with $IMAGE"
	chmod 644 "$tmp"
	if ! podman run --rm -v "$tmp":/etc/sing-box/config.json:ro "$IMAGE" check -c /etc/sing-box/config.json; then
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
echo "next: sudo -iu podman deploy sing-box"
