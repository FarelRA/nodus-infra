#!/usr/bin/env bash
# Install.sh copies repo managed files into the podman user runtime tree.
#
# Usage:
#   sudo bash deploy/install.sh
#   PODMAN_HOME=/tmp/test bash deploy/install.sh   # throwaway tree
#
# /home/farel is 0700, so the podman user cannot follow symlinks into the repo;
# files are copied. Re-run this after changing compose, Traefik, or deploy
# scripts.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PODMAN_HOME="${PODMAN_HOME:-/home/podman}"
SERVICES_DIR="$PODMAN_HOME/services"
BIN_DIR="$PODMAN_HOME/bin"
DATA_ROOT="$SERVICES_DIR/data"

install_dir() {
	[ -d "$1" ] || sudo install -d -o podman -g podman -m 755 "$1"
}

install_dir "$BIN_DIR"
install_dir "$SERVICES_DIR"
install_dir "$DATA_ROOT"
install_dir "$DATA_ROOT/traefik"

sudo install -o podman -g podman -m 755 "$REPO_DIR/deploy/deploy.sh" "$BIN_DIR/deploy"
sudo install -o podman -g podman -m 755 "$REPO_DIR/deploy/remove.sh" "$BIN_DIR/remove"

sudo install -o podman -g podman -m 644 "$REPO_DIR/services/docker-compose.yml" "$SERVICES_DIR/docker-compose.yml"
sudo install -o podman -g podman -m 640 "$REPO_DIR/services/traefik-dynamic.yml" "$DATA_ROOT/traefik/dynamic.yml"
if [ ! -e "$DATA_ROOT/traefik/acme.json" ]; then
	sudo install -o podman -g podman -m 600 /dev/null "$DATA_ROOT/traefik/acme.json"
fi
# Minecraft tuned configs: seed from the FarelRA/farelmc ground truth once.
# Updates ship inside the image; data/ copy is the live one (keep-existing).
if [ ! -e "$DATA_ROOT/minecraft/config/Geyser-Fabric/config.yml" ]; then
	echo "seeding Minecraft tuned configs from FarelRA/farelmc..."
	tmpdir="$(mktemp -d)"
	trap 'rm -rf "$tmpdir"' EXIT
	git clone -q --depth 1 --filter=blob:none --sparse https://github.com/FarelRA/farelmc.git "$tmpdir" 2>/dev/null
	(cd "$tmpdir" && git sparse-checkout set --skip-checks config server.properties eula.txt 2>/dev/null)
	sudo install -d -o podman -g podman -m 755 "$DATA_ROOT/minecraft/config"
	sudo cp -a "$tmpdir/config/." "$DATA_ROOT/minecraft/config/"
	sudo cp -a "$tmpdir/server.properties" "$DATA_ROOT/minecraft/server.properties" 2>/dev/null || true
	sudo cp -a "$tmpdir/eula.txt" "$DATA_ROOT/minecraft/eula.txt" 2>/dev/null || true
	sudo chown -R podman:podman "$DATA_ROOT/minecraft/config"
	sudo chown podman:podman "$DATA_ROOT/minecraft/server.properties" "$DATA_ROOT/minecraft/eula.txt" 2>/dev/null || true
fi

echo "installed into $PODMAN_HOME"
echo "  compose   : $SERVICES_DIR/docker-compose.yml"
echo "  traefik   : $DATA_ROOT/traefik/"
echo "apply future repo changes with: sudo bash $REPO_DIR/deploy/install.sh"
echo "deploy a service with:         sudo -iu podman deploy <service>"
echo "remove a service with:         sudo -iu podman remove <service>"
