#!/usr/bin/env bash
# Setup-payments.sh generates the KalaNidhi self-hosted payments gateway state.
#
# Usage:
#   bash deploy/setup-payments.sh
#
# Installs (never committed; all mode 600):
#   data/kalanidhi/payments.env            gateway env + shared secrets
#   data/kalanidhi/.env                    app env additions (URL + shared keys)
#   data/kalanidhi/convex-functions.env    PAYMENTS_INTERNAL_KEY (same value)
#
# Existing files are kept, so re-running never rotates a secret. The script
# adopts an existing key instead of generating a second one, and refuses to
# silently reconcile conflicting values. Secrets are never printed: read them
# from the 600 files on the box.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

KALANIDHI_DATA="$DATA_DIR/kalanidhi"
ENV_SRC="$REPO_DIR/services/env/payments.env.example"
ENV_OUT="$KALANIDHI_DATA/payments.env"
APP_ENV="$KALANIDHI_DATA/.env"
FUNCTIONS_ENV="$KALANIDHI_DATA/convex-functions.env"
GATEWAY_URL="http://kalanidhi-payments:8080"
WEBHOOK_URL="https://kalanidhi.site/api/payments/webhook"

usage() {
	cat <<'EOF'
Setup-payments.sh generates the KalaNidhi self-hosted payments gateway state.

Usage:
  bash deploy/setup-payments.sh

Run deploy/setup-convex.sh first: this script shares its INTERNAL_API_KEY with
data/kalanidhi/convex-functions.env. Existing secrets are kept. To regenerate
the gateway's own values, remove data/kalanidhi/payments.env and run again.
EOF
}

# Print a key from a dotenv file, or nothing when the file/key is absent.
env_get() {
	local file=$1 key=$2
	[ -e "$file" ] || return 0
	env_value "$file" "$key"
}

case "${1:-}" in
-h | --help)
	usage
	exit 0
	;;
"") ;;
*)
	die "unknown option: $1 (see --help)"
	;;
esac

need_cmd openssl
[ -f "$ENV_SRC" ] || die "missing template: $ENV_SRC"
[ -e "$FUNCTIONS_ENV" ] || die "missing $FUNCTIONS_ENV; run deploy/setup-convex.sh first"

# Resolve the shared internal key from whichever generated file already has it.
# Never generate a second value for an existing install, and never overwrite an
# operator's value: a mismatch fails loudly instead.
payments_key="$(env_get "$ENV_OUT" INTERNAL_API_KEY)"
functions_key="$(env_get "$FUNCTIONS_ENV" PAYMENTS_INTERNAL_KEY)"
app_key="$(env_get "$APP_ENV" PAYMENTS_INTERNAL_KEY)"
internal_key=""
for value in "$payments_key" "$functions_key" "$app_key"; do
	[ -n "$value" ] || continue
	case "$value" in
	*'{{'*) die "unrendered INTERNAL_API_KEY placeholder in a generated env file" ;;
	esac
	if [ -z "$internal_key" ]; then
		internal_key="$value"
	elif [ "$value" != "$internal_key" ]; then
		die "PAYMENTS_INTERNAL_KEY differs between data/kalanidhi env files; align the existing values manually (nothing was changed)"
	fi
done
[ -n "$internal_key" ] || internal_key="$(new_hex 32)"

# The webhook secret is shared only with the app env (Convex does not verify the
# gateway signature).
payments_secret="$(env_get "$ENV_OUT" WEBHOOK_SECRET)"
app_secret="$(env_get "$APP_ENV" PAYMENTS_WEBHOOK_SECRET)"
webhook_secret=""
for value in "$payments_secret" "$app_secret"; do
	[ -n "$value" ] || continue
	case "$value" in
	*'{{'*) die "unrendered WEBHOOK_SECRET placeholder in a generated env file" ;;
	esac
	if [ -z "$webhook_secret" ]; then
		webhook_secret="$value"
	elif [ "$value" != "$webhook_secret" ]; then
		die "PAYMENTS_WEBHOOK_SECRET differs between data/kalanidhi env files; align the existing values manually (nothing was changed)"
	fi
done
[ -n "$webhook_secret" ] || webhook_secret="$(new_hex 32)"

vault_passphrase="$(env_get "$ENV_OUT" SESSION_VAULT_PASSPHRASE)"
case "$vault_passphrase" in
*'{{'*) die "unrendered SESSION_VAULT_PASSPHRASE placeholder in $ENV_OUT" ;;
esac
[ -n "$vault_passphrase" ] || vault_passphrase="$(new_hex 32)"

# 1. Gateway env. The template keeps GoPay fields empty on purpose; startup
#    validates them, so fill them from GoBiz before the first deploy.
if [ -e "$ENV_OUT" ]; then
	keep_existing "$ENV_OUT"
else
	tmp="$(mktemp)"
	trap 'rm -f "$tmp"' EXIT
	sed -e "s|{{SESSION_VAULT_PASSPHRASE}}|$vault_passphrase|g" \
		-e "s|{{INTERNAL_API_KEY}}|$internal_key|g" \
		-e "s|{{WEBHOOK_SECRET}}|$webhook_secret|g" "$ENV_SRC" >"$tmp"
	grep -q '{{' "$tmp" && die "unrendered placeholder in $ENV_SRC"
	install_file "$tmp" "$ENV_OUT" 600
	trap - EXIT
	rm -f "$tmp"
	echo "wrote $ENV_OUT (600, contains the internal key, webhook secret, and vault passphrase; never commit)"
fi

# Fill missing/empty defaults without touching non-empty operator values.
env_ensure "$ENV_OUT" NODE_ENV production
env_ensure "$ENV_OUT" HOST 0.0.0.0
env_ensure "$ENV_OUT" PORT 8080
env_ensure "$ENV_OUT" LOG_LEVEL info
env_ensure "$ENV_OUT" STORE_PATH /var/lib/kalanidhi/payments.sqlite
env_ensure "$ENV_OUT" SESSION_VAULT_PASSPHRASE "$vault_passphrase"
env_ensure "$ENV_OUT" GOPAY_MERCHANT_ID ""
env_ensure "$ENV_OUT" GOPAY_STATIC_QRIS ""
env_ensure "$ENV_OUT" INTERNAL_API_KEY "$internal_key"
env_ensure "$ENV_OUT" WEBHOOK_URL "$WEBHOOK_URL"
env_ensure "$ENV_OUT" WEBHOOK_SECRET "$webhook_secret"
env_ensure "$ENV_OUT" WEBHOOK_ALLOW_HTTP false
env_ensure "$ENV_OUT" WEBHOOK_ALLOW_PRIVATE_NETWORKS false
env_ensure "$ENV_OUT" WEBHOOK_TIMEOUT_MS 5000
env_ensure "$ENV_OUT" WEBHOOK_MAX_ATTEMPTS 8
env_ensure "$ENV_OUT" WEBHOOK_BASE_DELAY_MS 1000
env_ensure "$ENV_OUT" WEBHOOK_MAX_DELAY_MS 60000
env_ensure "$ENV_OUT" RECONCILE_INTERVAL_MS 15000
env_ensure "$ENV_OUT" RECONCILE_JITTER_RATIO 0.2
env_ensure "$ENV_OUT" CLOCK_SKEW_MS 60000
env_ensure "$ENV_OUT" DEFAULT_EXPIRY_SECONDS 600
env_ensure "$ENV_OUT" MAX_UNIQUE_OFFSET 999

# 2. App env: the Next.js server reaches the gateway over the compose network
#    and verifies webhooks with the shared secret. Other keys are owned by
#    setup-convex.sh/setup-livekit.sh and are not touched here.
if [ ! -e "$APP_ENV" ]; then
	tmp="$(mktemp)"
	trap 'rm -f "$tmp"' EXIT
	cat >"$tmp" <<EOF
# KalaNidhi runtime environment. Generated by the deploy/setup-*.sh scripts;
# edit values here, never in the repo.
PAYMENTS_GATEWAY_URL=$GATEWAY_URL
PAYMENTS_INTERNAL_KEY=$internal_key
PAYMENTS_WEBHOOK_SECRET=$webhook_secret
EOF
	install_file "$tmp" "$APP_ENV" 600
	trap - EXIT
	rm -f "$tmp"
	echo "wrote $APP_ENV (600)"
else
	env_ensure "$APP_ENV" PAYMENTS_GATEWAY_URL "$GATEWAY_URL"
	env_ensure "$APP_ENV" PAYMENTS_INTERNAL_KEY "$internal_key"
	env_ensure "$APP_ENV" PAYMENTS_WEBHOOK_SECRET "$webhook_secret"
fi

# 3. Convex function env: the functions call the gateway with the same key. The
#    file is otherwise owned by setup-convex.sh (BETTER_AUTH_SECRET, SITE_URL).
env_ensure "$FUNCTIONS_ENV" PAYMENTS_INTERNAL_KEY "$internal_key"

echo
echo "gateway: $GATEWAY_URL (private network only; no public route)"
echo "shared internal key and webhook secret are in $ENV_OUT (600)"
echo "fill GOPAY_MERCHANT_ID and GOPAY_STATIC_QRIS in $ENV_OUT before deploying"
echo "deployment order: convex -> kalanidhi-payments -> kalanidhi"
