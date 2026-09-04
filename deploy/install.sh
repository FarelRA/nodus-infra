#!/usr/bin/env bash
# install.sh — one-time bootstrap (run after cloning this repo as farel):
# copies repo-managed configs into the podman user's runtime tree and installs `deploy`.
# NOTE: /home/farel is 0700, so the podman user cannot follow symlinks into it —
# therefore install.sh COPIES (apply = re-run install.sh after pulling this repo).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

sudo install -d -o podman -g podman -m 755 /home/podman/bin
sudo install -o podman -g podman -m 755 "$REPO_DIR/deploy/deploy.sh" /home/podman/bin/deploy

sudo install -o podman -g podman -m 644 "$REPO_DIR/services/docker-compose.yml" /home/podman/services/docker-compose.yml
sudo install -o podman -g podman -m 640 "$REPO_DIR/services/traefik-dynamic.yml" /home/podman/services/data/traefik/dynamic.yml

echo "installed. apply future repo changes with: sudo bash $REPO_DIR/deploy/install.sh"
echo "deploy a service with:    sudo -iu podman deploy <service>"
