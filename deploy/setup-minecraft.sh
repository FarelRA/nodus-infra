#!/usr/bin/env bash
# setup-minecraft.sh — generate the Minecraft server runtime env.
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
ENV_OUT="${1:-${OUT:-$DATA_DIR/minecraft/.env}}"

[ -f "$ENV_SRC" ] || die "missing template: $ENV_SRC"

if [ ! -e "$ENV_OUT" ]; then
	heap="${HEAP_GB:-4}"
	domain="${MCSERVER_DOMAIN:-mc.farel.is-a.dev}"
	tmp="$(mktemp)"
	trap 'rm -f "$tmp"' EXIT
	sed -e "s|{{HEAP_GB}}|$heap|g" \
		-e "s|{{MCSERVER_DOMAIN}}|$domain|g" "$ENV_SRC" >"$tmp"
	if grep -q '{{' "$tmp"; then
		die "unrendered placeholder in $ENV_SRC"
	fi
	install_file "$tmp" "$ENV_OUT" 600
else
	keep_existing "$ENV_OUT"
fi

echo
echo "Minecraft env is in place at $ENV_OUT"
echo "  join (Java)    : $(env_value "$ENV_OUT" MCSERVER_DOMAIN):25565"
echo "  join (Bedrock) : $(env_value "$ENV_OUT" MCSERVER_DOMAIN):19132"
echo "next: sudo -iu podman deploy minecraft"
