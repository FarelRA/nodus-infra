#!/usr/bin/env bash
# install.sh — copy repo-managed files into the podman user's runtime tree.
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

echo "installed into $PODMAN_HOME"
echo "  compose   : $SERVICES_DIR/docker-compose.yml"
echo "  traefik   : $DATA_ROOT/traefik/"
echo "apply future repo changes with: sudo bash $REPO_DIR/deploy/install.sh"
echo "deploy a service with:         sudo -iu podman deploy <service>"
echo "remove a service with:         sudo -iu podman remove <service>"
