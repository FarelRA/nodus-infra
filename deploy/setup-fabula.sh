#!/usr/bin/env bash
# Setup-fabula.sh generates the Fabula Convex backend env with auth keys and the admin key.
#
# Usage:
#   bash deploy/setup-fabula.sh           # pre-start: env + RS256 auth keypair
#   bash deploy/setup-fabula.sh --post    # post-start: data/fabula/admin-key
#
# The auth keypair is a PKCS8 RSA private key plus the matching JWKS document,
# the same shape the fabula self-host drill uses. It is generated once and must
# be kept: rotating it invalidates every existing session.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

OUT="$DATA_DIR/fabula/.env"
AUTH_DIR="$DATA_DIR/fabula/auth"
PRIVATE="$AUTH_DIR/private.pem"
JWKS="$AUTH_DIR/jwks.json"
ADMIN_KEY="$DATA_DIR/fabula/admin-key"
SITE_URL="https://fabula.farel.at.eu.org"
BACKEND_URL="https://fabula-api.farel.at.eu.org"

if [ "${1:-}" = "--post" ]; then
	if [ -e "$ADMIN_KEY" ]; then
		keep_existing "$ADMIN_KEY"
	else
		if ! run_as_podman podman inspect services-fabula-convex-1 >/dev/null 2>&1; then
			die "services-fabula-convex-1 is not running; start the stack first"
		fi
		if ! key="$(run_as_podman podman exec services-fabula-convex-1 ./generate_admin_key.sh 2>/dev/null | grep '|' | tail -n 1)"; then
			die "could not generate the Fabula admin key"
		fi
		[ -n "$key" ] || die "could not generate the Fabula admin key"
		tmp="$(mktemp)"
		trap 'rm -f "$tmp"' EXIT
		printf '%s\n' "$key" >"$tmp"
		install_file "$tmp" "$ADMIN_KEY" 600
		echo "wrote $ADMIN_KEY (600, contains credentials; never commit)"
	fi

	cat <<EOF

Next, provision the deployment (run from the fabula app repo):

  cd ~/projects/apps/fabula
  export CONVEX_SELF_HOSTED_URL=$BACKEND_URL
  export CONVEX_SELF_HOSTED_ADMIN_KEY="\$(cat $ADMIN_KEY)"
  bunx convex env set SITE_URL $SITE_URL
  bunx convex env set JWT_PRIVATE_KEY --from-file $PRIVATE
  bunx convex env set JWKS --from-file $JWKS
  bunx convex deploy --yes

Then set the operator's OpenAI-compatible gateway vars (see
services/fabula/convex.env.example) and deploy the app with:

  sudo -iu podman deploy fabula

EOF
	exit 0
fi

if [ -e "$OUT" ]; then
	keep_existing "$OUT"
else
	need_cmd openssl
	secret="$(new_hex 32)"
	tmp="$(mktemp)"
	trap 'rm -f "$tmp"' EXIT
	sed -e "s|{{FABULA_INSTANCE_SECRET}}|$secret|g" \
		"$REPO_DIR/services/env/fabula.env.example" >"$tmp"
	if grep -q '{{' "$tmp"; then
		die "unrendered placeholder in services/env/fabula.env.example"
	fi
	install_file "$tmp" "$OUT" 600
	echo "wrote $OUT (600, contains credentials; never commit)"
	echo "  INSTANCE_SECRET: $secret"
fi

if [ -e "$PRIVATE" ] || [ -e "$JWKS" ]; then
	if [ -e "$PRIVATE" ] && [ -e "$JWKS" ]; then
		keep_existing "$AUTH_DIR/private.pem + jwks.json"
	else
		die "incomplete auth keypair in $AUTH_DIR (both private.pem and jwks.json are required)"
	fi
else
	need_cmd openssl
	need_cmd python3
	tmp_key="$(mktemp)"
	tmp_jwks="$(mktemp)"
	trap 'rm -f "$tmp_key" "$tmp_jwks"' EXIT
	openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp_key" 2>/dev/null
	grep -q 'BEGIN PRIVATE KEY' "$tmp_key" || die "unexpected private key format"
	modulus="$(openssl rsa -in "$tmp_key" -noout -modulus 2>/dev/null | cut -d= -f2)"
	[ -n "$modulus" ] || die "could not read the RSA modulus"
	n_b64="$(python3 -c 'import base64,sys; print(base64.urlsafe_b64encode(bytes.fromhex(sys.argv[1])).decode().rstrip("="))' "$modulus")"
	printf '{"keys":[{"kty":"RSA","n":"%s","e":"AQAB","alg":"RS256","use":"sig"}]}\n' "$n_b64" >"$tmp_jwks"
	install_file "$tmp_key" "$PRIVATE" 600
	install_file "$tmp_jwks" "$JWKS" 600
	echo "wrote $PRIVATE + $JWKS (600, signing keys; back them up and never commit)"
fi

cat <<EOF

Next: start the stack, then run:
  bash deploy/setup-fabula.sh --post

That writes the deployment admin key and prints the auth/deploy commands.
EOF
