#!/usr/bin/env bash
# setup-couchdb.sh — generate the CouchDB admin env and local config.
#
# Usage:
#   bash deploy/setup-couchdb.sh [env-path]
#
# Installs:
#   data/couchdb/.env              (600, generated admin password)
#   data/couchdb/conf/docker.ini   (644, from services/couchdb/docker.ini.example)
#
# Existing files are kept; remove one to regenerate it.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENV_SRC="$REPO_DIR/services/env/couchdb.env.example"
ENV_OUT="${1:-${OUT:-$DATA_DIR/couchdb/.env}}"
INI_SRC="$REPO_DIR/services/couchdb/docker.ini.example"
INI_OUT="$DATA_DIR/couchdb/conf/docker.ini"

user="${COUCHDB_USER:-farel}"
password=""
if [ ! -e "$ENV_OUT" ]; then
	need_cmd openssl
	password="${COUCHDB_PASSWORD:-$(new_hex 24)}"
	tmp="$(mktemp)"
	trap 'rm -f "$tmp"' EXIT
	sed -e "s|{{COUCHDB_USER}}|$user|g" \
		-e "s|{{COUCHDB_PASSWORD}}|$password|g" "$ENV_SRC" >"$tmp"
	if grep -q '{{' "$tmp"; then
		die "unrendered placeholder in $ENV_SRC"
	fi
	install_file "$tmp" "$ENV_OUT" 600
else
	keep_existing "$ENV_OUT"
fi

if [ ! -e "$INI_OUT" ]; then
	install_file "$INI_SRC" "$INI_OUT" 644
else
	keep_existing "$INI_OUT"
fi

echo
if [ -n "$password" ]; then
	echo "wrote $ENV_OUT (600, contains credentials; never commit)"
	echo "  CouchDB user     : $user"
	echo "  CouchDB password : $password"
else
	echo "CouchDB env is in place at $ENV_OUT"
fi
echo "config: $INI_OUT"
