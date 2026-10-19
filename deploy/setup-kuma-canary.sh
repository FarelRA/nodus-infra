#!/usr/bin/env bash
# setup-kuma-canary.sh — install the per-minute Uptime Kuma self-canary timer.
#
# Usage:
#   KUMA_PUSH_TOKEN=<token> bash deploy/setup-kuma-canary.sh
#
# Get the token from Uptime Kuma: add a Push monitor, then copy the token from
# its push URL (https://<host>/api/push/<token>). Optional KUMA_HOST override
# (default nkuma.farel.at.eu.org). Existing units are kept; remove the service
# file first to rotate the token.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

PODMAN_HOME="${PODMAN_HOME:-/home/podman}"
UNIT_DIR="$PODMAN_HOME/.config/systemd/user"
SERVICE="$UNIT_DIR/kuma-canary.service"
TIMER="$UNIT_DIR/kuma-canary.timer"
HOST="${KUMA_HOST:-nkuma.farel.at.eu.org}"
TOKEN="${KUMA_PUSH_TOKEN:-}"

if [ ! -e "$SERVICE" ]; then
	[ -n "$TOKEN" ] || die "set KUMA_PUSH_TOKEN (Uptime Kuma → Push monitor → token)"
	tmp="$(mktemp)"
	trap 'rm -f "$tmp"' EXIT
	sed -e "s|{{KUMA_HOST}}|$HOST|g" \
		-e "s|{{KUMA_PUSH_TOKEN}}|$TOKEN|g" \
		"$REPO_DIR/services/uptime-kuma/kuma-canary.service.example" >"$tmp"
	if grep -q '{{' "$tmp"; then
		die "unrendered placeholder in services/uptime-kuma/kuma-canary.service.example"
	fi
	install_file "$tmp" "$SERVICE" 644
	echo "wrote $SERVICE"
else
	keep_existing "$SERVICE"
fi

if [ ! -e "$TIMER" ]; then
	install_file "$REPO_DIR/services/uptime-kuma/kuma-canary.timer" "$TIMER" 644
	echo "wrote $TIMER"
else
	keep_existing "$TIMER"
fi

if run_as_podman systemctl --user daemon-reload 2>/dev/null; then
	run_as_podman systemctl --user enable --now kuma-canary.timer
	echo "enabled kuma-canary.timer"
else
	echo "warning: could not reach the podman user's systemd manager; enable the timer later:" >&2
	echo "  sudo -iu podman systemctl --user enable --now kuma-canary.timer" >&2
fi
