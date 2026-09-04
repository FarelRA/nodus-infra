#!/usr/bin/env bash
# install.sh — one-time bootstrap: puts deploy.sh on PATH for the podman user and links infra files.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

sudo install -d -o podman -g podman -m 755 /home/podman/bin
sudo install -o podman -g podman -m 755 "$REPO_DIR/deploy/deploy.sh" /home/podman/bin/deploy

# make services dir reference the repo-managed compose (single source of truth)
sudo ln -sf "$REPO_DIR/services/docker-compose.yml" /home/podman/services/docker-compose.yml
sudo ln -sf "$REPO_DIR/services/traefik-dynamic.yml" /home/podman/services/data/traefik/dynamic.yml

echo "installed. use: sudo -iu podman deploy <service>"
