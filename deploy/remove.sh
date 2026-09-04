#!/usr/bin/env bash
# remove — stop and delete a compose service's container (image and volumes are kept).
# Usage: remove <service> [service...]
# Designed to run as the `podman` user:  cd ~/services && remove randomting
set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-$HOME/services}"
cd "$COMPOSE_DIR"

if [ $# -eq 0 ]; then
	echo "usage: remove <service> [service...]" >&2
	exit 1
fi

for svc in "$@"; do
	if ! grep -qE "^  ${svc}:$" docker-compose.yml; then
		echo "    $svc: not in docker-compose.yml — removing container only"
	fi
	podman rm -f "services-${svc}-1" >/dev/null 2>&1 && echo "    $svc: container removed" || echo "    $svc: no container found"
done

# drop orphaned containers whose service was deleted from the compose file
podman compose up -d --remove-orphans >/dev/null 2>&1 || true
