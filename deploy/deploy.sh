#!/usr/bin/env bash
# deploy — pull latest image, recreate one compose service, verify health, auto-rollback on failure.
# Usage: deploy <service> [more services...]
# Designed to run as the `podman` user:  cd ~/services && deploy osis sijimban
#
# Note: Traefik's docker provider does not receive live container events through
# podman's socket, so recreated containers keep stale backend IPs until Traefik
# restarts. This script detects that (502 probe) and bounces Traefik automatically.
set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-$HOME/services}"
cd "$COMPOSE_DIR"

if [ $# -eq 0 ]; then
	echo "usage: deploy <service> [service...]" >&2
	echo "services: traefik webservice couchdb sing-box growmate minio convex farelfolio osis sijimban randomting" >&2
	exit 1
fi

# first Host( hostname routed for a service (empty = not publicly routed)
routed_host() {
	awk -v s="$1" '
		$0 ~ "^  " s ":$" {inblk=1; next}
		inblk && $0 ~ /^  [a-z]/ {exit}
		inblk && /traefik.http.routers/ && match($0, /Host\(`[^`]+`\)/) {
			h=substr($0, RSTART+6, RLENGTH-7); print h; exit}' docker-compose.yml
}

bounce_traefik() {
	echo "    traefik backend stale — bouncing traefik"
	podman compose restart traefik >/dev/null 2>&1
	sleep 6
}

overall=0
bounced=false
for svc in "$@"; do
	echo "==> $svc"
	old_image_id=$(podman inspect "services-${svc}-1" --format '{{.Image}}' 2>/dev/null || true)
	image=$(awk -v s="$svc" '
		$0 ~ "^  " s ":$" {inblk=1; next}
		inblk && $0 ~ /^  [a-z]/ {exit}
		inblk && $1 == "image:" {print $2; exit}' docker-compose.yml)
	if [ -z "$image" ]; then
		echo "    ERROR: service '$svc' not found in docker-compose.yml" >&2
		overall=1
		continue
	fi

	podman pull -q "$image" >/dev/null
	podman rm -f "services-${svc}-1" >/dev/null 2>&1 || true
	podman compose up -d "$svc" >/dev/null

	# wait for healthy (max 120s)
	ok=false
	for i in $(seq 1 24); do
		st=$(podman inspect "services-${svc}-1" --format '{{.State.Healthcheck.Status}}' 2>/dev/null || echo "")
		if [ "$st" = "healthy" ]; then ok=true; break; fi
		if [ -z "$st" ] && [ "$i" -ge 10 ]; then
			podman inspect "services-${svc}-1" --format '{{.State.Status}}' 2>/dev/null | grep -q running && ok=true && break
		fi
		sleep 5
	done

	if ! $ok; then
		echo "    FAILED to become healthy — rolling back" >&2
		podman rm -f "services-${svc}-1" >/dev/null 2>&1 || true
		if [ -n "$old_image_id" ]; then
			podman tag "$old_image_id" "$image" 2>/dev/null || true
		fi
		podman compose up -d "$svc" >/dev/null
		echo "    rolled back to previous image" >&2
		overall=1
		continue
	fi
	echo "    deployed ($image) — healthy"

	# verify through traefik (publicly routed services only)
	host=$(routed_host "$svc")
	if [ -n "$host" ]; then
		code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve "$host:443:127.0.0.1" "https://$host/" --max-time 8 || echo 000)
		if [ "$code" = "502" ] || [ "$code" = "000" ]; then
			$bounced || bounce_traefik
			bounced=true
			code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve "$host:443:127.0.0.1" "https://$host/" --max-time 8 || echo 000)
		fi
		echo "    route https://$host -> $code"
	fi
done
exit $overall
