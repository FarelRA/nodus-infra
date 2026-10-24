# nodus-infra

Infrastructure-as-code for the **nodus** server (Oracle Cloud ARM, Debian, rootless podman).

Everything that defines the running stack lives here. `install.sh` copies compose,
Traefik, and deploy scripts onto the box; `setup.sh` can rebuild the whole host
from scratch. Application data and generated secrets stay under
`/home/podman/services/data` and are never committed.

## Layout

| Path | Deployed to | Purpose |
| --- | --- | --- |
| `services/docker-compose.yml` | `/home/podman/services/docker-compose.yml` | The full production stack (single source of truth) |
| `services/traefik-dynamic.yml` | `/home/podman/services/data/traefik/dynamic.yml` | Traefik middlewares (basicAuth, sslheader) |
| `deploy/install.sh` | — (run from this repo) | Copies compose, Traefik, and deploy scripts into the podman tree |
| `deploy/setup.sh` | — (run from this repo) | One-shot fresh-host bootstrap (host → config → start) |
| `deploy/lib.sh` | — (sourced by setup scripts) | Shared paths, secret generation, ownership, run-as-podman |
| `deploy/deploy.sh` | `/home/podman/bin/deploy` (via install.sh) | Pull → recreate → health-verify → auto-rollback |
| `deploy/remove.sh` | `/home/podman/bin/remove` (via install.sh) | Remove a service container (keeps image/volumes) |
| `deploy/setup-*.sh` | — (run from this repo) | Generate and validate the matching service env/config |
| `services/env/*.env.example` | — (read by the setup scripts) | Sanitized env templates for couchdb, convex, fabula, growmate, rustfs, waha |
| `services/couchdb/docker.ini.example` | `data/couchdb/conf/docker.ini` | CouchDB local config (admin comes from `.env`) |
| `services/xray/config.example.json` | — (read by `setup-xray.sh`) | Xray inbound template (credentials substituted before install) |
| `services/sing-box/config.example.json` | — (read by `setup-sing-box.sh`) | sing-box inbound template (credentials substituted before install) |
| `services/growmate/convex.env.example` | — (reference) | Function env to set in the GrowMate Convex deployment |
| `services/fabula/convex.env.example` | — (reference) | Function/auth env to set in the Fabula Convex deployment |
| `deploy/podman-containers.conf` | `/home/podman/.config/containers/containers.conf` | Rootless podman defaults (log driver/limit) |
| `deploy/sysctl-podman-rootless.conf` | `/etc/sysctl.d/99-podman-rootless.conf` | Unprivileged port 80 + ping range |
| `services/uptime-kuma/kuma-canary.*` | `~podman/.config/systemd/user/` | Optional per-minute Kuma heartbeat |

## Rebuild from scratch

On a fresh Debian host with `git` installed:

```bash
git clone https://github.com/FarelRA/nodus-infra.git
cd nodus-infra
sudo bash deploy/setup.sh
```

The script is re-runnable: missing files are generated, existing secrets and
configs are kept, and `podman compose up -d` converges the stack.

What it does:

1. **Host** — installs `podman`, `podman-compose`, Docker Compose v2
   (`docker-compose`; static binary fallback), `uidmap`, `slirp4netns`,
   `curl`, `openssl`, `sudo`, `python3` when missing; creates the `podman` user
   (uid 986, matching the socket paths in compose); configures subuid/subgid,
   linger, the unprivileged-port sysctl, `containers.conf`, the podman user
   socket, `podman-restart.service`, and host firewall accepts for 80/443/443udp.
2. **Install** — copies compose, Traefik dynamic config, `deploy`, and `remove`
   into `/home/podman`, and creates `data/traefik/acme.json` if absent.
3. **Generate** — writes every missing env/config from the committed examples:
   CouchDB, GrowMate Convex, GrowMate app, RustFS, WAHA, Fabula (including its
   RS256 auth keypair), sing-box, and Xray.
4. **Start** — pulls images, starts the stack, waits for Traefik, RustFS,
   GrowMate Convex, and Fabula Convex, then writes the two Convex admin keys.
5. **Report** — prints the remaining external steps and the generated paths.

Useful flags:

```bash
sudo bash deploy/setup.sh --no-start    # generate/install config, do not start
sudo bash deploy/setup.sh --no-host     # skip packages/user/sysctl/units
sudo bash deploy/setup.sh --no-install  # skip copying repo files into /home/podman
sudo bash deploy/setup.sh --data-dir /tmp/test-data --no-host --no-install --no-start
```

Generated state (never committed; back it up):

| Path | Contents |
| --- | --- |
| `data/couchdb/.env`, `data/couchdb/conf/docker.ini` | CouchDB admin + local config |
| `data/convex/.env`, `data/convex/admin-key` | GrowMate Convex instance secret/admin key |
| `data/growmate/.env` | GrowMate app + demo/device credentials |
| `data/rustfs/.env` | S3 access/secret keys |
| `data/waha/.env` | WAHA API/dashboard/swagger credentials |
| `data/fabula/.env`, `data/fabula/admin-key`, `data/fabula/auth/` | Fabula instance secret, admin key, JWT signing keys |
| `data/sing-box/config.json`, `data/xray/config.json` | Proxy credentials |
| `data/traefik/acme.json` | Let's Encrypt state (reissued on a fresh host) |

Still external to this repo:

- DNS for every `Host(...)` name in `services/docker-compose.yml`, and the
  Oracle/cloud firewall plus host firewall allowing TCP 80/443, UDP 443,
  and Minecraft: TCP 25565 + 19132 (signaling) / UDP 19132 + 19133 + 24454
  (Bedrock requires UDP, TCP-only won't show the server).
- App code and Convex function deploys. The images are pulled by compose, but
  GrowMate/Fabula functions live in their app repos; run the commands printed
  by `setup-growmate.sh` / `setup-fabula.sh --post`.
- Operator API keys (Fabula's OpenAI-compatible gateway, etc.) and the WAHA
  WhatsApp QR scan.
- The Traefik basic-auth hash committed in `services/traefik-dynamic.yml` is
  the one already in use. To change it, generate a new hash (for example
  `htpasswd -nb farel <password>` via any httpd image), replace it, and re-run
  `deploy/install.sh`.
- Uptime Kuma's admin account and monitors. After creating the push monitor,
  install the heartbeat with
  `sudo KUMA_PUSH_TOKEN=<token> bash deploy/setup-kuma-canary.sh` (or export
  `KUMA_PUSH_TOKEN` before `setup.sh`).
- `data/webservice` static content is user data, not in this repo.

### What a fresh host does not restore

`setup.sh` creates a **new** empty stack with new credentials. It does not
restore application data: CouchDB, both Convex stores, the RustFS volume, WAHA
sessions/media, Uptime Kuma's SQLite DB, OSIS files/sessions, or static
webservice files. Those live under `data/` and the `rustfs-data` /
`convex-data` volumes; back them up before replacing a host and copy them back
after the first start.

Losing `INSTANCE_SECRET` (GrowMate or Fabula) means losing the ability to read
that Convex data, so keep `data/*/.env` with the data backup. Fabula's
`data/fabula/auth/` keypair must also be kept: rotating it invalidates every
existing session.

## App CI/CD

Applications are built by GitHub Actions in their own repos (`FarelRA/farelfolio`,
`FarelRA/osis-sman1bantul`, `FarelRA/sijimban`,
`FarelRA/growmate-app`) and published to GHCR. Deploying a new app version:

```bash
sudo -iu podman deploy farelfolio        # or: osis sijimban growmate pitch
```

Static Nuxt apps with no backend (like `pitch`) need no `env_file` or
`depends_on`; the deploy probe follows the first `Host(` router rule.

`deploy` waits for the container to come up, probes the public route through Traefik
(auto-bounces Traefik on a stale backend), and rolls back to the previous image
automatically if the probe fails.

`fabula` also ships Convex functions, which live with the code rather than the
image; every release needs a function deploy before recreating the app (see the
fabula notes).

## Infrastructure changes

1. Edit `services/docker-compose.yml`, `services/traefik-dynamic.yml`, or a
   setup script/example in this repo.
2. Commit + push.
3. On the box: `git pull && sudo bash deploy/install.sh` (it copies; the podman
   user cannot follow symlinks through `/home/farel`, which is 0700).
4. Deploy the changed service: `sudo -iu podman deploy <service>`. For a new or
   regenerated service config, run the matching `deploy/setup-*.sh` first; it
   will keep any existing file unless you remove it.

## Stack inventory

| Service    | Image                          | Public route                              |
| ---------- | ------------------------------ | ----------------------------------------- |
| traefik    | `traefik:latest`               | all HTTPS ingress, dashboard (auth)       |
| webservice | static-web-server              | `farel.is-a.dev` + `farel.at.eu.org` (/priv behind auth) |
| farelfolio | `farelra/farelfolio`           | `farel.is-a.dev`                          |
| jaringan-hayati | `farelra/jaringan-hayati` | `farel.is-a.dev/assignment/jaringan-hayati` |
| osis       | `farelra/osis-sman1bantul`     | `osis.farel.is-a.dev`                     |
| sijimban   | `farelra/sijimban`             | `sijimban.site`                           |
| uptime-kuma | `louislam/uptime-kuma:next`    | `nkuma.farel.at.eu.org` (kuma's own auth) |
| waha       | `devlikeapro/waha:arm`         | `waha.farel.at.eu.org` (API key + dashboard auth) |
| growmate   | `farelra/growmate-app`         | `growmate.bond`                           |
| pitch      | `farelra/growmate-pitch`       | `pitch.growmate.bond`                     |
| convex     | `get-convex/convex-backend`    | `convex.growmate.bond`                    |
| rustfs     | `rustfs/rustfs`                | `storage.growmate.bond`                   |
| fabula     | `farelra/fabula`               | `fabula.farel.at.eu.org`                  |
| fabula-convex | `convex/convex-backend` | `fabula-api.farel.at.eu.org` (API), `fabula-site.farel.at.eu.org` (actions) |
| fabula-dashboard | `convex/convex-dashboard` | `fabula-admin.farel.at.eu.org` (auth) |
| couchdb    | `couchdb:latest`               | `couchdb.farel.at.eu.org`                 |
| sing-box   | `sagernet/sing-box`            | proxy tunnels under `/sing/*` (VLESS/VMess/Trojan × ws/ht/grpc/httpupgrade; `ht` = HTTP transport over H2c) |
| xray       | `ghcr.io/xtls/xray-core`       | proxy tunnels under `/xray/*` (VLESS/VMess/Trojan × ws/grpc/httpupgrade/xh; `xh` = XHTTP over H2c) |
| tor-proxy  | `zhaowde/rotating-tor-http-proxy` | loopback `127.0.0.1:3128` only           |
| minecraft | `ghcr.io/farelra/farelmc` (CI from `FarelRA/farelmc`) | Java `mc.farel.is-a.dev:25565`, Bedrock `:19132`, voice `:24454/udp`, map `map.mc.farel.is-a.dev` |

All containers run **rootless** as the `podman` user (uid 986); ports 80/443 are
bound by rootlessport (`net.ipv4.ip_unprivileged_port_start=80`). Boot persistence
via `podman-restart.service` + `restart: always` + linger. A fresh host is
bootstrapped with `sudo bash deploy/setup.sh`.

### couchdb notes

- CouchDB backs OSIS (and anything else that wants a document store). The admin
  account comes from `data/couchdb/.env`; `data/couchdb/conf/docker.ini` holds
  CORS, `require_valid_user`, and the larger request/document limits.
- A fresh host runs `deploy/setup-couchdb.sh`, which generates both files. The
  committed `services/couchdb/docker.ini.example` deliberately has no
  `[admins]` section: the image creates the admin from the env file, and a
  second admin hash in the ini would fight it.
- Data lives in `data/couchdb/data` (not in repo). Back it up with the rest of
  `data/`; the DB is not rebuilt by `setup.sh`.

### growmate notes

- The app reads `data/growmate/.env` (generated by `setup-growmate.sh`); the
  public RustFS/Convex URLs are baked into the env example. RustFS keys must
  match `data/rustfs/.env` — the script reuses them.
- `convex` is the self-hosted GrowMate backend. `setup-convex.sh` writes its
  env and, after the stack is up, `data/convex/admin-key`. Function env
  (`RUSTFS_ENDPOINT=http://rustfs:9000` plus the keys/bucket) is set in the
  deployment, not in compose; see `services/growmate/convex.env.example` and
  the commands printed by `setup-growmate.sh`.
- The demo login is `https://growmate.bond/demo/<DEMO_ACCESS_TOKEN>` with
  `DEMO_EMAIL` / `DEMO_PASSWORD`; all three are generated. `DEVICE_API_KEY`
  authenticates the device fleet API.
- Both Convex hostnames resolve to `host-gateway` inside the container so
  server-side calls re-enter through Traefik :443 (the public IP is closed for
  self-hairpin). `TRUST_ALL_PROXY_HEADERS` is intentional behind Traefik.

### uptime-kuma notes

- `louislam/uptime-kuma:next` is the rolling pre-release channel: it tracks
  the next Kuma release before it becomes stable, including database
  migrations. Back up `data/uptime-kuma` before updating, and expect possible
  breaking changes. Update with `sudo -iu podman deploy uptime-kuma`.

### waha notes

- WhatsApp HTTP API (NOWEB engine — browserless, no Chromium). Sessions persist in
  `data/waha/.sessions`; media in `data/waha/.media`.
- `devlikeapro/waha:arm` is the floating arm64 build; upstream's `:latest` is
  amd64-only, so it cannot replace `:arm` on this Oracle ARM host.
- `deploy/setup-waha.sh` generates `data/waha/.env` (600): `WAHA_API_KEY`,
  dashboard + swagger creds. The committed template is
  `services/env/waha.env.example`. Re-scan the QR after a fresh host; sessions
  are not in the repo.
- Updating: `:arm` floats — `podman compose pull waha` then `rm -f` + `up -d` (compose
  no-ops on same tag), then `podman compose restart traefik` (stale backend).
- Used as the outbound notifier for uptime-kuma ("Orion Alert" notification).

### rustfs notes

- S3-compatible store for `growmate` + `convex` (MinIO is deprecated
  upstream). `rustfs/rustfs:latest` floats like the rest of the stack
  (rollback via deploy retag).
  S3 wire-compat verified live (bucket create/policy, presigned URLs,
  private-bucket denial, deletes) against the exact aws-sdk calls the app
  makes; app image `farelra/growmate-app:91c5c98`+ reads `RUSTFS_*` env
  (the old `MINIO_*` names are dead — rename them everywhere, values can stay).
- Fresh volume only (`rustfs-data`): RustFS cannot read MinIO's on-disk
  format, and a fresh host always starts empty. Buckets self-create on first
  upload; re-upload seed images with `convex run seed:comprehensive`; past
  `recordings` regenerate under TTL. The old MinIO volume is not a rollback
  path on a new host.
- Runs as upstream uid 10001; named volume needs no ownership fix.
- `deploy/setup-rustfs.sh` generates `data/rustfs/.env` (600, 20+ char access
  key, 32-byte secret). `setup-growmate.sh` and `setup-convex.sh` reuse those
  keys, so all three stay in sync. The template is
  `services/env/rustfs.env.example`; the real file is never committed.
- Console enabled but unrouted; health at `/health`. Deploy/update with
  `sudo -iu podman deploy rustfs`.

### fabula notes

- Three services: `fabula` (Next.js app), `fabula-convex` (its own Convex
  backend), and `fabula-dashboard` (public behind `defaultAuth@file`; the
  deployment admin key gates the deployment on top of that). Both Convex
  images use `latest` and must be pulled/recreated together so the backend and
  dashboard stay paired.
- Functions live with the code, not the image. After every release of
  `FarelRA/fabula`, deploy functions against the server backend, then
  recreate the app:

  ```bash
  cd ~/projects/apps/fabula
  export CONVEX_SELF_HOSTED_URL=https://fabula-api.farel.at.eu.org
  export CONVEX_SELF_HOSTED_ADMIN_KEY="$(sudo cat /home/podman/services/data/fabula/admin-key)"
  bunx convex deploy --yes     # fallback: bunx convex dev --once
  sudo -iu podman deploy fabula
  ```

- The app image bakes `NEXT_PUBLIC_CONVEX_URL` at build time from the
  repository variable of the same name (currently
  `https://fabula-api.farel.at.eu.org`). Changing the public origin needs a
  fresh release tag, not just a compose edit.
- `INSTANCE_SECRET` (hex, `openssl rand -hex 32`) lives in
  `data/fabula/.env` and must never change for the life of the instance;
  losing it means losing the deployment. `deploy/setup-fabula.sh` generates it
  on a fresh host.
- Convex Auth keys: a fresh deployment also needs `SITE_URL` and an RS256
  keypair (`JWT_PRIVATE_KEY`, `JWKS`) or every sign-in fails. `setup-fabula.sh`
  generates the PKCS8 key + JWKS under `data/fabula/auth/`; after the stack is
  up, `setup-fabula.sh --post` writes the admin key and prints the
  `convex env set` commands. Keep `data/fabula/auth/` backed up; rotating it
  invalidates every session.
- Deployment env (`convex env set` against the self-hosted URL with the
  admin key, or the fabula-dashboard): `OPENAI_API_KEY` and `OPENAI_BASE_URL`
  point the model gateway at the operator's OpenAI-compatible endpoint,
  `FABULA_MODEL_SPOTLIGHT` / `FABULA_MODEL_STANDARD` / `FABULA_MODEL_CHEAP`
  select the model per tier, and `FABULA_IMAGE_MODEL` enables avatar images
  through the gateway (unset keeps the gradient+monogram placeholder). The
  full reference is `services/fabula/convex.env.example`; keys never enter
  this repo.
- Backups: tar the `data/fabula/convex-data` path (the backend bind-mounts
  it so the data sits on the host disk directly) together with
  `data/fabula/.env` and `data/fabula/auth/`.
- Both convex hostnames and the app resolve their public origin to
  `host-gateway` inside the container so server-side calls re-enter through
  traefik :443 (the public IP is closed for self-hairpin, same as growmate).
- Kuma coverage: HTTP monitors for the three public routes (app 200, api
  `/version` 200, admin 401 without credentials) plus docker state monitors
  per the coverage invariant.

### sing-box notes

- Every tunnel lives under `/sing/*` on `flare.farel.is-a.dev` /
  `flare.farel.at.eu.org` (previously `/tunnel/*`). Each protocol has a single
  HTTP-transport route, `-ht`, with Traefik pinned to h2c. The client's HTTP
  version is independent (Traefik terminates H1/H2/H3 and re-originates h2c),
  so HTTP/1.1 and HTTP/2 clients both use the same `-ht` path.
- The live config (`data/sing-box/config.json`) is gitignored because it holds
  credentials; `services/sing-box/config.example.json` is the committed
  template and `bash deploy/setup-sing-box.sh` generates/validates/installs it
  on a fresh box (same flow as Xray). On the running box the path rename is a
  two-part change — edit the config, then redeploy:

  ```bash
  sudo -u podman sed -Ei \
      -e 's|/tunnel/|/sing/|g' \
      -e 's|"service_name": *"tunnel/|"service_name": "sing/|g' \
      -e 's|/sing/(vless|vmess|trojan)-h2|/sing/\1-ht|g' \
      /home/podman/services/data/sing-box/config.json
  sudo -iu podman deploy sing-box
  ```

  The old `*-http` inbounds (ports 12002/12008/12014) become unrouted; they can
  stay (harmless) or be deleted in the same edit.
- Fresh deployment: `bash deploy/setup-sing-box.sh`, then
  `sudo bash deploy/install.sh`, then `sudo -iu podman deploy sing-box` (the
  deploy probe follows the first router, `/sing/vless-ws`). On a brand-new
  host, `sudo bash deploy/setup.sh` runs all of that; existing configs are
  kept, so it doubles as the safe re-run.
- Clients (WS/HTTP paths, gRPC service names) must switch to `/sing/...`
  in the same window; the old routes stop matching in Traefik as soon as the
  compose change is installed.

### xray notes

- Scope: the full VLESS/VMess/Trojan matrix over every transport that survives
  a Traefik front — `ws`, `grpc` (h2c), `httpupgrade` and XHTTP over h2c
  (`xh`). One inbound per route, ports 12101-12112, public paths
  `/xray/<proto>-<transport>`:

  | Protocol | Routes (ports)                                                            |
  | -------- | ------------------------------------------------------------------------- |
  | vless    | `vless-ws` 12101, `vless-grpc` 12102, `vless-hu` 12103, `vless-xh` 12104   |
  | vmess    | `vmess-ws` 12105, `vmess-grpc` 12106, `vmess-hu` 12107, `vmess-xh` 12108   |
  | trojan   | `trojan-ws` 12109, `trojan-grpc` 12110, `trojan-hu` 12111, `trojan-xh` 12112 |

- `xh` is XHTTP pinned to HTTP/2 (h2c) on the Traefik→Xray hop and is the
  single XHTTP route; the H1 variant was dropped. Xray's client `mode: auto`
  defaults to `packet-up`; `stream-up`/`stream-one` also work (the server
  config's `mode: "auto"` allows every mode).
- Upstream **removed** the plain `http` transport, so XHTTP covers sing-box's
  `http`/`h2` rows. `ws`, `grpc` and `httpupgrade` still work but print
  deprecation warnings — prefer `xh` for new clients.
- Credentials are never committed: `bash deploy/setup-xray.sh` substitutes a
  fresh UUID (shared by the vless/vmess inbounds) and Trojan password into
  `services/xray/config.example.json`, validates the result with
  `xray run -test` in a throwaway container, and installs it to
  `data/xray/config.json` (644, podman-owned — the image runs as uid 65532).
  Pass `UUID=` / `TROJAN_PASSWORD=` to keep existing creds; to regenerate,
  delete the file and rerun.
- Apply: `sudo bash deploy/install.sh`, then `sudo -iu podman deploy xray`.
  The deploy probe follows the first router (`/xray/vless-ws`). A fresh host
  gets the same result from `sudo bash deploy/setup.sh`.
- Deliberately not exposed through Traefik: RAW (+XTLS Vision), REALITY, mKCP,
  QUIC and the Hysteria inbound — they need their own TCP/UDP ports and
  terminate TLS/QUIC inside Xray, which would bypass the ACME certificate and
  Cloudflare in front of :443. Add a dedicated port + firewall rule if ever
  needed instead of bending the HTTP router.

## Assignment apps (subpath pattern)

School/assignment apps deploy under `farel.is-a.dev/assignment/<name>` as plug-and-play
compose blocks. Reference implementation: `jaringan-hayati`.

How it works:

- The app honors its base path at RUNTIME via `NUXT_APP_BASE_URL` (Nuxt maps
  `app.baseURL` to runtime config, overridable by env). One image works at any
  subpath, no rebuild. No StripPrefix middleware: the app serves under its own
  baseURL, so router links and assets are correct by construction.
- Traefik matches `Host(\`farel.is-a.dev\`) && PathPrefix(\`/assignment/<name>\`)`.
  The longer rule outranks farelfolio's bare `Host` rule by Traefik's default
  rule-length priority (same mechanism as the `/priv` router).

Checklist for the next assignment:

1. App repo: Nuxt 4 + bun, `Dockerfile` + `bunfig.toml` + `.dockerignore` +
   `.github/workflows/docker-release.yml` copied from `jaringan-hayati` (builder
   pinned `--platform=$BUILDPLATFORM`, node runtime for the nitro build, arm64-only).
2. Repo public (anonymous GHCR pull), CI green on `Docker Release`.
3. Compose: copy the `jaringan-hayati` block, change service name, image, and the
   two path occurrences (`NUXT_APP_BASE_URL` + router rule). Port 3000 for Nuxt.
4. `git pull` on the box, `install.sh`, then `sudo -iu podman deploy <service>`
   (the probe follows the PathPrefix automatically).
5. Verify from outside (check-host.net) and add kuma monitors (http + docker state)
   per the coverage invariant.

### minecraft notes

- Scope: Fabric 26.3 SMP, 62 pinned jars (Via stack = any Java version joins;
  Geyser + Floodgate = current Bedrock joins, no Java account). Ground truth is
  `FarelRA/farelmc` — CI builds `ghcr.io/farelra/farelmc` on `main` push;
  nodus only pulls the image, never builds it.
- Traefik manages ALL TLS: BlueMap `:8100` → `https://map.mc.farel.is-a.dev`,
  and NetherNet signaling `:19132` TCP → `https://mc.farel.is-a.dev` with plain
  HTTP to Geyser (`geyser-signal` router on its own entrypoint). Geyser trusts
  `10.89.0.0/24` via `signaling-trusted-proxies` so every Bedrock player keeps
  their real IP (no shared rate limit). Game UDP/TCP stay raw publishes —
  Traefik can't proxy MC UDP / Bedrock WebRTC.
- Fresh deployment: `bash deploy/setup-minecraft.sh`, then
  `sudo bash deploy/install.sh`, then `sudo -iu podman deploy minecraft`
  (the deploy probe skips services with no `Host(` route — game ports aren't
  HTTP, so container `running` is the gate). BlueMap route probes
  `https://map.mc.farel.is-a.dev` like every other web route.
- Live state (never in repo): `data/minecraft/` (world + player files,
  bind-mounted `/data`), `data/minecraft/config/` (tuned defaults seeded from
  farelmc, server may add version stamps), `data/minecraft/state/luckperms/`
  (H2) + `state/nethernet/identity.pem` (Geyser identity), `data/minecraft/.env`
  (600). Floodgate `key.pem` ships with the committed farelmc config
  (auto-picked-up — back it up, rotating it orphans linked Bedrock accounts).
- Updating mods: edit `FarelRA/farelmc`, push (CI rebuilds), then
  `sudo -iu podman deploy minecraft` (fresh image, `cp -n` seeds new jars).
