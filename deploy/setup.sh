#!/usr/bin/env bash
# setup.sh — rebuild the nodus stack on a fresh Debian host from this repo.
#
# Usage:
#   sudo bash deploy/setup.sh [options]
#
# Options:
#   --no-host       skip host provisioning (packages, podman user, sysctl, units)
#   --no-install    skip copying compose/traefik/deploy into /home/podman
#   --no-start      generate and install config only; do not pull or start
#   --data-dir DIR  generate state under DIR (default /home/podman/services/data)
#   -h, --help      show this help
#
# Safe to re-run: missing files are generated, existing secrets/configs are
# never overwritten, and `podman compose up -d` converges the stack.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_DIR/deploy/lib.sh"
PODMAN_USER="${PODMAN_USER:-podman}"
PODMAN_UID="${PODMAN_UID:-986}"
PODMAN_HOME="${PODMAN_HOME:-}"
DATA_DIR="${DATA_DIR:-/home/podman/services/data}"
SKIP_HOST=false
SKIP_INSTALL=false
SKIP_START=false
COMPOSE_PROVIDER=""

usage() {
	cat <<'EOF'
setup.sh — rebuild the nodus stack on a fresh Debian host from this repo.

Usage:
  sudo bash deploy/setup.sh [options]

Options:
  --no-host       skip host provisioning (packages, podman user, sysctl, units)
  --no-install    skip copying compose/traefik/deploy into /home/podman
  --no-start      generate and install config only; do not pull or start
  --data-dir DIR  generate state under DIR (default /home/podman/services/data)
  -h, --help      show this help

Safe to re-run: missing files are generated, existing secrets/configs are
never overwritten, and `podman compose up -d` converges the stack.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--no-host) SKIP_HOST=true ;;
	--no-install) SKIP_INSTALL=true ;;
	--no-start) SKIP_START=true ;;
	--data-dir)
		[ $# -ge 2 ] || die "--data-dir needs a directory"
		DATA_DIR="$2"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1 (see --help)"
		;;
	esac
	shift
done

[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash deploy/setup.sh"

if [ -z "$PODMAN_HOME" ]; then
	PODMAN_HOME="$(getent passwd "$PODMAN_USER" | cut -d: -f6 || true)"
	PODMAN_HOME="${PODMAN_HOME:-/home/podman}"
fi
export DATA_DIR PODMAN_USER PODMAN_HOME

# ---------------------------------------------------------------------------
# Host prerequisites
# ---------------------------------------------------------------------------
ensure_packages() {
	local need=()
	for cmd in podman podman-compose docker-compose curl openssl sudo python3; do
		command -v "$cmd" >/dev/null 2>&1 || need+=("$cmd")
	done
	command -v newuidmap >/dev/null 2>&1 || need+=(uidmap)
	command -v slirp4netns >/dev/null 2>&1 || need+=(slirp4netns)
	[ "${#need[@]}" -eq 0 ] && return 0

	command -v apt-get >/dev/null 2>&1 || die "missing ${need[*]}; install them manually (this script supports apt)"
	note "installing packages: ${need[*]}"
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y podman podman-compose docker-compose uidmap slirp4netns curl openssl sudo python3
}

# Podman compose delegates to an external provider; Docker Compose v2 is the
# only one that names containers services-<svc>-1, which deploy/remove assume.
compose_v2() {
	COMPOSE_PROVIDER=""
	if command -v docker-compose >/dev/null 2>&1 &&
		docker-compose version 2>/dev/null | grep -Eq 'version v?2\.'; then
		COMPOSE_PROVIDER="$(command -v docker-compose)"
		return 0
	fi
	return 1
}

ensure_compose_provider() {
	compose_v2 && return 0

	note "installing Docker Compose v2 (the podman compose provider)"
	apt-get install -y docker-compose >/dev/null 2>&1 || true
	compose_v2 && return 0

	local arch
	case "$(uname -m)" in
	aarch64 | arm64) arch=aarch64 ;;
	x86_64 | amd64) arch=x86_64 ;;
	armv7l) arch=armv7 ;;
	*) die "no Docker Compose v2 build for $(uname -m); install docker-compose v2 manually" ;;
	esac
	local bin=/usr/local/libexec/docker/cli-plugins/docker-compose
	install -d /usr/local/libexec/docker/cli-plugins
	curl -fL --retry 3 -o "$bin.tmp" "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$arch"
	install -m 755 "$bin.tmp" "$bin"
	rm -f "$bin.tmp"
	ln -sf "$bin" /usr/local/bin/docker-compose
	compose_v2 || die "Docker Compose v2 installed but not on PATH"
}

ensure_user() {
	if ! id "$PODMAN_USER" >/dev/null 2>&1; then
		note "creating $PODMAN_USER (uid $PODMAN_UID)"
		useradd --create-home --home-dir "$PODMAN_HOME" --shell /bin/bash --uid "$PODMAN_UID" "$PODMAN_USER"
	fi
	local uid
	uid="$(id -u "$PODMAN_USER")"
	if ! grep -q "/run/user/$uid/podman/podman.sock" "$REPO_DIR/services/docker-compose.yml"; then
		die "$PODMAN_USER has uid $uid but compose mounts /run/user/986/podman/podman.sock; recreate the user with uid 986 or edit the socket paths"
	fi
	if ! grep -q "^$PODMAN_USER:" /etc/subuid; then
		usermod --add-subuids 100000-165535 "$PODMAN_USER"
	fi
	if ! grep -q "^$PODMAN_USER:" /etc/subgid; then
		usermod --add-subgids 100000-165535 "$PODMAN_USER"
	fi
	loginctl enable-linger "$PODMAN_USER"
}

ensure_sysctl() {
	install -m 644 "$REPO_DIR/deploy/sysctl-podman-rootless.conf" /etc/sysctl.d/99-podman-rootless.conf
	sysctl --system >/dev/null
}

ensure_user_units() {
	local uid i
	uid="$(id -u "$PODMAN_USER")"
	for i in $(seq 1 30); do
		[ -S "/run/user/$uid/bus" ] && break
		sleep 1
	done
	if ! run_as_podman systemctl --user daemon-reload >/dev/null 2>&1; then
		die "the systemd user manager for $PODMAN_USER is not reachable; check loginctl enable-linger and /run/user/$uid"
	fi
	run_as_podman systemctl --user enable --now podman.socket
	run_as_podman systemctl --user enable --now podman-restart.service 2>/dev/null ||
		echo "warning: podman-restart.service is not available; containers will not auto-start on boot" >&2
}

ensure_firewall() {
	command -v iptables >/dev/null 2>&1 || {
		echo "warning: iptables not found; allow 80/443/443udp in the cloud firewall" >&2
		return 0
	}
	local bin
	for bin in iptables ip6tables; do
		command -v "$bin" >/dev/null 2>&1 || continue
		"$bin" -C INPUT -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null ||
			"$bin" -I INPUT 1 -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -j ACCEPT || true
		"$bin" -C INPUT -p udp -m udp --dport 443 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null ||
			"$bin" -I INPUT 1 -p udp -m udp --dport 443 -m conntrack --ctstate NEW -j ACCEPT || true
		# Minecraft: Java 25565/tcp, Bedrock signaling 19132/tcp (Traefik geyser-signal
		# entrypoint), voice 24454/udp, Bedrock 19132/udp + 19133/udp
		# (signaling :19132/tcp is Traefik's geyser-signal entrypoint)
		"$bin" -C INPUT -p tcp -m multiport --dports 19132,25565 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null ||
			"$bin" -I INPUT 1 -p tcp -m multiport --dports 19132,25565 -m conntrack --ctstate NEW -j ACCEPT || true
		"$bin" -C INPUT -p udp -m multiport --dports 19132,19133,24454 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null ||
			"$bin" -I INPUT 1 -p udp -m multiport --dports 19132,19133,24454 -m conntrack --ctstate NEW -j ACCEPT || true
	done
	if command -v netfilter-persistent >/dev/null 2>&1; then
		netfilter-persistent save >/dev/null 2>&1 || true
	else
		echo "warning: netfilter-persistent not found; firewall rules may not survive a reboot" >&2
	fi
}

if ! $SKIP_HOST; then
	ensure_packages
	ensure_compose_provider
	need_cmd openssl
	ensure_user
	ensure_sysctl
	if [ ! -e "$PODMAN_HOME/.config/containers/containers.conf" ]; then
		install_file "$REPO_DIR/deploy/podman-containers.conf" "$PODMAN_HOME/.config/containers/containers.conf" 644
	else
		echo "keeping existing $PODMAN_HOME/.config/containers/containers.conf"
	fi
	ensure_user_units
	ensure_firewall
else
	need_cmd openssl
	compose_v2 || echo "warning: Docker Compose v2 not found; podman compose may use podman-compose, whose container names deploy/remove do not expect" >&2
	id "$PODMAN_USER" >/dev/null 2>&1 || die "user $PODMAN_USER does not exist (omit --no-host to create it)"
	uid="$(id -u "$PODMAN_USER")"
	grep -q "/run/user/$uid/podman/podman.sock" "$REPO_DIR/services/docker-compose.yml" ||
		die "$PODMAN_USER has uid $uid but compose hardcodes another socket path"
fi

# ---------------------------------------------------------------------------
# Install repo-managed files and create the data tree
# ---------------------------------------------------------------------------
if ! $SKIP_INSTALL; then
	PODMAN_HOME="$PODMAN_HOME" bash "$REPO_DIR/deploy/install.sh"
fi

[ -d "$PODMAN_HOME/services" ] || install -d -o "$PODMAN_USER" -g "$PODMAN_USER" -m 755 "$PODMAN_HOME/services"
[ -d "$DATA_DIR" ] || install -d -o "$PODMAN_USER" -g "$PODMAN_USER" -m 755 "$DATA_DIR"
for dir in \
	"$DATA_DIR/couchdb" "$DATA_DIR/couchdb/data" "$DATA_DIR/couchdb/conf" \
	"$DATA_DIR/convex" \
	"$DATA_DIR/fabula" "$DATA_DIR/fabula/convex-data" \
	"$DATA_DIR/growmate" \
	"$DATA_DIR/osis" "$DATA_DIR/osis/data" "$DATA_DIR/osis/sessions" \
	"$DATA_DIR/rustfs" \
	"$DATA_DIR/sing-box" \
	"$DATA_DIR/traefik" \
	"$DATA_DIR/uptime-kuma" \
	"$DATA_DIR/waha" "$DATA_DIR/waha/.sessions" "$DATA_DIR/waha/.media" \
	"$DATA_DIR/webservice" \
	"$DATA_DIR/minecraft" "$DATA_DIR/minecraft/state" \
	"$DATA_DIR/xray"; do
	[ -d "$dir" ] || install -d -o "$PODMAN_USER" -g "$PODMAN_USER" -m 755 "$dir"
done

# ---------------------------------------------------------------------------
# Generate every missing secret/config from the committed examples
# ---------------------------------------------------------------------------
note "generating secrets and service configs under $DATA_DIR"
bash "$REPO_DIR/deploy/setup-rustfs.sh"
bash "$REPO_DIR/deploy/setup-couchdb.sh"
bash "$REPO_DIR/deploy/setup-convex.sh"
bash "$REPO_DIR/deploy/setup-growmate.sh"
bash "$REPO_DIR/deploy/setup-waha.sh"
bash "$REPO_DIR/deploy/setup-fabula.sh"
bash "$REPO_DIR/deploy/setup-sing-box.sh"
bash "$REPO_DIR/deploy/setup-xray.sh"
bash "$REPO_DIR/deploy/setup-minecraft.sh"

if grep -q '{{' "$DATA_DIR"/*/.env "$DATA_DIR"/*/config.json "$DATA_DIR"/couchdb/conf/docker.ini 2>/dev/null; then
	die "unrendered placeholders remain under $DATA_DIR — refusing to start"
fi

if $SKIP_START; then
	echo
	echo "config generated; skipped starting because --no-start was given"
	echo "start with: sudo -iu $PODMAN_USER bash -c 'cd $PODMAN_HOME/services && podman compose up -d'"
	exit 0
fi

# ---------------------------------------------------------------------------
# Pull, start, wait, and finish the per-service post-start steps
# ---------------------------------------------------------------------------
[ -f "$PODMAN_HOME/services/docker-compose.yml" ] || die "missing $PODMAN_HOME/services/docker-compose.yml (run without --no-install)"
[ -f "$DATA_DIR/traefik/dynamic.yml" ] || die "missing $DATA_DIR/traefik/dynamic.yml (run without --no-install)"
[ -f "$DATA_DIR/traefik/acme.json" ] || die "missing $DATA_DIR/traefik/acme.json (run without --no-install)"
if [ "$(realpath -m "$DATA_DIR")" != "$(realpath -m "$PODMAN_HOME/services/data")" ]; then
	die "--data-dir must be $PODMAN_HOME/services/data when starting (compose uses relative paths)"
fi
command -v podman >/dev/null 2>&1 || die "podman is required to start the stack"

compose_run() {
	if [ -n "$COMPOSE_PROVIDER" ]; then
		run_as_podman env PODMAN_COMPOSE_PROVIDER="$COMPOSE_PROVIDER" \
			bash -c 'cd "$1" && shift && exec podman compose "$@"' bash "$PODMAN_HOME/services" "$@"
	else
		run_as_podman bash -c 'cd "$1" && shift && exec podman compose "$@"' bash "$PODMAN_HOME/services" "$@"
	fi
}

note "pulling images"
compose_run pull
note "starting the stack"
compose_run up -d

wait_state() {
	local name=$1 want=$2 tries=${3:-60} i state
	for ((i = 1; i <= tries; i++)); do
		if [ "$want" = healthy ]; then
			state="$(run_as_podman podman inspect "$name" --format '{{.State.Health.Status}}' 2>/dev/null || true)"
		else
			state="$(run_as_podman podman inspect "$name" --format '{{.State.Status}}' 2>/dev/null || true)"
		fi
		[ "$state" = "$want" ] && return 0
		sleep 3
	done
	return 1
}

wait_state services-traefik-1 running || die "traefik did not start; check: podman logs services-traefik-1"
wait_state services-rustfs-1 healthy || die "rustfs did not become healthy; check: podman logs services-rustfs-1"
wait_state services-convex-1 running || die "convex did not start; check: podman logs services-convex-1"
wait_state services-fabula-convex-1 healthy || die "fabula-convex did not become healthy; check: podman logs services-fabula-convex-1"

bash "$REPO_DIR/deploy/setup-convex.sh" --post
bash "$REPO_DIR/deploy/setup-fabula.sh" --post

if [ -n "${KUMA_PUSH_TOKEN:-}" ]; then
	bash "$REPO_DIR/deploy/setup-kuma-canary.sh"
else
	echo
	echo "optional: after creating the Kuma push monitor, install its heartbeat with:"
	echo "  sudo KUMA_PUSH_TOKEN=<token> bash $REPO_DIR/deploy/setup-kuma-canary.sh"
fi

cat <<EOF

Stack is up. Generated state: $DATA_DIR
  env files      : */.env (600, contains credentials; back up and never commit)
  proxy configs  : sing-box/config.json, xray/config.json (644)
  Convex keys    : convex/admin-key, fabula/admin-key (600)
  Fabula auth    : fabula/auth/private.pem + jwks.json (600)

Still external to this repo:
  1. DNS: point every Host(...) name in services/docker-compose.yml at this box.
  2. Cloud firewall: allow TCP 80/443 and UDP 443 (Oracle security list + host).
  3. GrowMate Convex: set RUSTFS_* in the deployment and deploy/seed functions
     (services/growmate/convex.env.example).
  4. Fabula: run the env/deploy commands printed above, set the OpenAI gateway
     vars, then deploy the app.
  5. WAHA: open the dashboard/API and scan the WhatsApp QR.
  6. Uptime Kuma: create the admin account and the monitors; optionally add the
     push monitor used by setup-kuma-canary.sh.
  7. Restore data if this is a replacement (all service data lives under
     $DATA_DIR and the rustfs-data/convex-data volumes; a fresh host starts empty).

Updates: sudo -iu $PODMAN_USER deploy <service>
EOF
