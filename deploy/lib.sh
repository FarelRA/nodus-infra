#!/usr/bin/env bash
# Lib.sh holds shared helpers for the deploy and setup scripts. It is sourced and never run directly.
#
# All setup scripts honour DATA_DIR (default /home/podman/services/data) and
# PODMAN_USER (default podman), so a throwaway tree can be generated for tests
# without touching the live stack.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${DATA_DIR:-/home/podman/services/data}"
PODMAN_USER="${PODMAN_USER:-podman}"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

note() {
	printf '==> %s\n' "$*"
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

# Random material used by the generators. Hex keeps the values shell/env-safe.
new_hex() {
	openssl rand -hex "${1:-16}"
}

new_uuid() {
	openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
}

# Env_value prints the last value of a key from a dotenv file. Call it with the file path then the key name.
env_value() {
	sed -n "s/^$2=//p" "$1" | tail -n 1
}

# Keep generated state idempotent: a second run must never rotate credentials.
keep_existing() {
	printf 'keeping existing %s (remove it first to regenerate)\n' "$1"
}

# Install_file copies a file into place with the given mode. It installs as PODMAN_USER when root. Otherwise it uses
# sudo or write directly if the caller already owns the target tree.
install_file() {
	local src=$1 dst=$2 mode=$3 dir
	dir="$(dirname "$dst")"
	if [ "$(id -u)" -eq 0 ]; then
		[ -d "$dir" ] || install -d -o "$PODMAN_USER" -g "$PODMAN_USER" -m 755 "$dir"
		install -o "$PODMAN_USER" -g "$PODMAN_USER" -m "$mode" "$src" "$dst"
	elif [ -d "$dir" ] && [ -w "$dir" ]; then
		install -m "$mode" "$src" "$dst"
	else
		[ -d "$dir" ] || sudo install -d -o "$PODMAN_USER" -g "$PODMAN_USER" -m 755 "$dir"
		sudo install -o "$PODMAN_USER" -g "$PODMAN_USER" -m "$mode" "$src" "$dst"
	fi
}

# Run a command as the podman user, inside its home directory. The caller's cwd
# may be /home/farel (0700), which rootless podman cannot chdir into.
run_as_podman() {
	local home uid
	home="$(getent passwd "$PODMAN_USER" | cut -d: -f6)"
	uid="$(id -u "$PODMAN_USER" 2>/dev/null || true)"
	[ -n "$home" ] && [ -n "$uid" ] || die "user $PODMAN_USER does not exist"
	if [ "$(id -un)" = "$PODMAN_USER" ]; then
		(cd "$home" && "$@")
	elif command -v sudo >/dev/null 2>&1; then
		sudo -u "$PODMAN_USER" env \
			HOME="$home" \
			XDG_RUNTIME_DIR="/run/user/$uid" \
			DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
			bash -c 'cd "$HOME" && exec "$@"' bash "$@"
	else
		die "sudo is required to run commands as $PODMAN_USER"
	fi
}
