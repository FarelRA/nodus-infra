#!/usr/bin/env bash
# Setup-minecraft.sh generates the runtime env for the Minecraft server.
#
# Usage:
#   bash deploy/setup-minecraft.sh [env-path]    # default: data/minecraft/.env
#
# Installs:
#   data/minecraft/.env              (600, heap + join domain)
#
# Existing files are kept; remove one to regenerate it.
# Tuned server.properties/config ship inside the ghcr.io/farelra/farelmc image
# (ground truth: FarelRA/farelmc); only the env is generated here.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENV_SRC="$REPO_DIR/services/env/minecraft.env.example"
# Rotate one value in place without touching the rest.
#   RCON_PASSWORD='<secret>' bash deploy/setup-minecraft.sh --rotate-rcon
#   HEAP_GB=8 bash deploy/setup-minecraft.sh --rotate-heap
if [ "${1:-}" = "--rotate-rcon" ] || [ "${1:-}" = "--rotate" ]; then
	# Rotate exactly one credential in place, keep the rest (domain, heap).
	ENV_OUT="${OUT:-$DATA_DIR/minecraft/.env}"
	rcon="${RCON_PASSWORD:?usage: RCON_PASSWORD='<secret>' bash deploy/setup-minecraft.sh --rotate-rcon}"
	tmp="$(mktemp)"
	trap 'rm -f "$tmp"' EXIT
	if grep -q '^RCON_PASSWORD=' "$ENV_OUT" 2>/dev/null; then
		sed -e "s|^RCON_PASSWORD=.*|RCON_PASSWORD=$rcon|" "$ENV_OUT" >"$tmp"
	elif [ -e "$ENV_OUT" ]; then
		cat "$ENV_OUT" >"$tmp" && printf 'RCON_PASSWORD=%s\n' "$rcon" >>"$tmp"
	else
		die "no env at $ENV_OUT to rotate, run without flags first"
	fi
	install_file "$tmp" "$ENV_OUT" 600
	echo "rotated RCON_PASSWORD in $ENV_OUT (restart minecraft to apply)"
	echo "  join (Java)    : $(env_value "$ENV_OUT" MCSERVER_DOMAIN):25565"
	echo "  join (Bedrock) : $(env_value "$ENV_OUT" MCSERVER_DOMAIN):19132"
	exit 0
fi
if [ "${1:-}" = "--rotate-heap" ]; then
	ENV_OUT="${OUT:-$DATA_DIR/minecraft/.env}"
	heap="${HEAP_GB:?usage: HEAP_GB=8 bash deploy/setup-minecraft.sh --rotate-heap}"
	tmp="$(mktemp)"
	trap 'rm -f "$tmp"' EXIT
	if grep -q '^HEAP_GB=' "$ENV_OUT" 2>/dev/null; then
		sed -e "s|^HEAP_GB=.*|HEAP_GB=$heap|" "$ENV_OUT" >"$tmp"
	elif [ -e "$ENV_OUT" ]; then
		cat "$ENV_OUT" >"$tmp" && printf 'HEAP_GB=%s\n' "$heap" >>"$tmp"
	else
		die "no env at $ENV_OUT to rotate, run without flags first"
	fi
	install_file "$tmp" "$ENV_OUT" 600
	echo "rotated HEAP_GB to $heap in $ENV_OUT (restart minecraft to apply)"
	exit 0
fi
ENV_OUT="${1:-${OUT:-$DATA_DIR/minecraft/.env}}"

[ -f "$ENV_SRC" ] || die "missing template: $ENV_SRC"

if [ ! -e "$ENV_OUT" ]; then
	heap="${HEAP_GB:-8}"
	domain="${MCSERVER_DOMAIN:-mc.farel.is-a.dev}"
	rcon="${RCON_PASSWORD:-}"
	tmp="$(mktemp)"
	trap 'rm -f "$tmp"' EXIT
	sed -e "s|{{HEAP_GB}}|$heap|g" \
		-e "s|{{MCSERVER_DOMAIN}}|$domain|g" \
		-e "s|{{RCON_PASSWORD}}|$rcon|g" "$ENV_SRC" >"$tmp"
	if grep -q '{{' "$tmp"; then
		die "unrendered placeholder in $ENV_SRC"
	fi
	[ -z "$rcon" ] && echo "warning: RCON_PASSWORD is empty. Set it in $ENV_OUT before going public" >&2
	install_file "$tmp" "$ENV_OUT" 600
else
	keep_existing "$ENV_OUT"
fi

echo
echo "Minecraft env is in place at $ENV_OUT"
echo "  join (Java)    : $(env_value "$ENV_OUT" MCSERVER_DOMAIN):25565"
echo "  join (Bedrock) : $(env_value "$ENV_OUT" MCSERVER_DOMAIN):19132"
echo "next: sudo -iu podman deploy minecraft"
