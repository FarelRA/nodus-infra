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
| `deploy/install.sh` | run it from this repo | Copies compose plus Traefik plus deploy scripts into the podman tree |
| `deploy/setup.sh` | run it from this repo | One shot fresh host bootstrap. It runs host setup, then config, then start |
| `deploy/lib.sh` | sourced by setup scripts | Shared paths plus secret generation plus ownership plus run as podman |
| `deploy/deploy.sh` | `/home/podman/bin/deploy` (via install.sh) | Pull → recreate → health-verify → auto-rollback |
| `deploy/remove.sh` | `/home/podman/bin/remove` (via install.sh) | Remove a service container (keeps image/volumes) |
| `deploy/setup-*.sh` | run it from this repo; KalaNidhi's copies land in `/home/podman/deploy/` | Generate and validate the matching service env and config |
| `deploy/setup-iodine.sh` | run it from this repo (root) | Install/configure the host `iodined` DNS tunnel + Cloudflare delegation |
| `services/env/*.env.example` | read by the setup scripts | Sanitized env templates for couchdb, waha, and KalaNidhi Convex/LiveKit/payments |
| `services/livekit/config.example.yaml` | read by `setup-livekit.sh` | LiveKit SFU template (TURN, Redis, RTC ports, key placeholders) |
| `services/couchdb/docker.ini.example` | `data/couchdb/conf/docker.ini` | CouchDB local config (admin comes from `.env`) |
| `services/xray/config.example.json` | read by `setup-xray.sh` | Xray inbound template. Credentials are substituted before install |
| `services/sing-box/config.example.json` | read by `setup-sing-box.sh` | sing-box inbound template. Credentials are substituted before install |
| `services/iodine/iodine.default.example` | `/etc/default/iodine` | iodined args + tunnel password (rendered 600) |
| `services/iodine/cloudflare.env.example` | `/etc/nodus/cloudflare.env` | Cloudflare API token + zone for automatic NS delegation (600) |
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

1. **Host** installs `podman`, `podman-compose` and Docker Compose v2
   (`docker-compose`; static binary fallback), `uidmap`, `slirp4netns`,
   `curl`, `openssl`, `sudo`, `python3`, and `iodine` when missing; creates the
   `podman` user (uid 986, matching the socket paths in compose); configures
   subuid/subgid, linger, the unprivileged-port sysctl, `containers.conf`, the
   podman user socket, `podman-restart.service`, and host firewall accepts for
   80/443/443udp plus 53/udp for the DNS tunnel.
2. **Install** copies compose plus Traefik dynamic config plus `deploy` and `remove`
   into `/home/podman`, and creates `data/traefik/acme.json` if absent.
3. **Generate** writes every missing env and config from the committed examples. That covers
   CouchDB, WAHA, sing-box, Xray, Convex, LiveKit, the KalaNidhi payments
   gateway, and Minecraft. It also runs `setup-iodine.sh`, which renders
   `/etc/default/iodine`, forwarding/NAT, and (when a token exists) upserts the
   `dns.farel.is-a.dev` Cloudflare delegation.
4. **Start** pulls images and starts the stack, then waits for Traefik.
5. **Report** prints the remaining external steps and the generated paths.

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
| `data/waha/.env` | WAHA API/dashboard/swagger credentials |
| `data/sing-box/config.json`, `data/xray/config.json` | Proxy credentials |
| `/etc/default/iodine` | iodined tunnel zone, args, and password (600) |
| `/etc/nodus/cloudflare.env` | Cloudflare token + zone for automatic DNS (600) |
| `/etc/sysctl.d/99-iodine.conf` | IPv4 forwarding for DNS tunnel clients |
| `data/kalanidhi/.env` | App runtime URLs (Convex + LiveKit), no secrets |
| `data/kalanidhi/convex.env` | Convex backend env incl. `INSTANCE_SECRET` |
| `data/kalanidhi/convex-functions.env` | Convex deployment secrets applied with the CLI |
| `data/kalanidhi/convex-admin-key` | Convex admin key (written by `setup-convex.sh --post`) |
| `data/kalanidhi/livekit.env`, `data/kalanidhi/livekit.yaml` | LiveKit keypair and server config |
| `data/kalanidhi/payments.env` | Payments gateway secrets + GoPay merchant settings |
| `data/kalanidhi/convex-data/` | Convex database + file storage (back it up) |
| `data/kalanidhi/livekit-redis/` | LiveKit Redis AOF |
| `data/kalanidhi/payments-data/` | Payments gateway SQLite store (back it up) |
| `data/traefik/acme.json` | Let's Encrypt state (reissued on a fresh host) |

Still external to this repo:

- DNS for every `Host(...)` name in `services/docker-compose.yml`, and the
  Oracle/cloud firewall plus host firewall allowing TCP 80/443, UDP 443,
  UDP 53 (the iodine DNS tunnel; the host rule is automatic, the Oracle
  security list is not), and Minecraft: TCP 25565 + 19132 (signaling) /
  UDP 19132 + 19133 + 24454 (Bedrock requires UDP, TCP-only won't show the
  server).
  KalaNidhi adds `convex.kalanidhi.site`, `convex-site.kalanidhi.site`,
  `convex-admin.kalanidhi.site`, `livekit.kalanidhi.site`, and
  `rtc.kalanidhi.site`; see the KalaNidhi section for its ports and the
  Cloudflare DNS-only requirement on `livekit`/`rtc`.
- Operator API keys and the WAHA WhatsApp QR scan.
- GoPay/GoBiz merchant details (`GOPAY_MERCHANT_ID`, `GOPAY_STATIC_QRIS`) and
  the initial OTP session for the KalaNidhi payments gateway; see its section
  below. Access to the private GHCR package is also external (see image
  visibility there).
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
restore application data: CouchDB, WAHA sessions/media, Uptime Kuma's SQLite
DB, OSIS files/sessions, static webservice files, KalaNidhi's Convex database
(`data/kalanidhi/convex-data`), the payments gateway's SQLite store
(`data/kalanidhi/payments-data`), or LiveKit's Redis state
(`data/kalanidhi/livekit-redis`). Those live under `data/`; back them up before
replacing a host and copy them back after the first start. A new host also
generates a new Convex admin key and LiveKit keypair, so redeploy the app with
the new values. The payments gateway keeps its `SESSION_VAULT_PASSPHRASE` in
`data/kalanidhi/payments.env`; restore that file (or re-authenticate with OTP)
or the encrypted GoPay session in the database cannot be opened.

The DNS tunnel state lives outside `data/`: `/etc/default/iodine` holds the
tunnel password, and `/etc/nodus/cloudflare.env` holds the Cloudflare API
token. Back both up separately (or re-create the token) before replacing the
host; a new host generates a new iodine password, so re-enter it in AndIodine.

## App CI/CD

Applications are built by GitHub Actions in their own repos (`FarelRA/farelfolio`,
`FarelRA/osis-sman1bantul`, `FarelRA/sijimban`, `FarelRA/kalanidhi`,
`FarelRA/kalanidhi-payments`) and published to GHCR.
Deploying a new app version:

```bash
sudo -iu podman deploy farelfolio        # or: osis sijimban
```

Static Nuxt apps with no backend need no `env_file` or
`depends_on`; the deploy probe follows the first `Host(` router rule.

KalaNidhi reads runtime config from `data/kalanidhi/.env` plus the LiveKit
keypair from `data/kalanidhi/livekit.env` (compose loads both). `install.sh`
writes the URLs and generates the LiveKit keypair and the payments gateway
secrets, so the shared internal key and webhook secret need no manual edit. The
GoPay merchant fields still do (see the payments gateway section). After
changing either env file, run `sudo -iu podman deploy kalanidhi`.

The payments gateway is a separate private image. Update it with
`sudo -iu podman deploy kalanidhi-payments`; see the payments gateway section
for the one-time GHCR login when the package is private.

The app depends on a healthy Convex backend and on the payments gateway having
started, so deploying it also brings both up. For a brand-new deployment, push
the functions with the commands printed by `setup-convex.sh --post` (see the
KalaNidhi section).

`deploy` waits for the container to come up, probes the public route through Traefik
(auto-bounces Traefik on a stale backend), and rolls back to the previous image
automatically if the probe fails.


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
| osis       | `farelra/osis-sman1bantul`     | `osis.farel.is-a.dev`                     |
| sijimban   | `farelra/sijimban`             | `sijimban.site`                           |
| kalanidhi  | `farelra/kalanidhi`            | `kalanidhi.site` + `www.kalanidhi.site`   |
| convex     | `ghcr.io/convex/convex-backend:1447815c` | `convex.kalanidhi.site` (3210), `convex-site.kalanidhi.site` (3211) |
| convex-dashboard | `ghcr.io/convex/convex-dashboard:1447815c` | `convex-admin.kalanidhi.site` (basic auth + admin key) |
| kalanidhi-payments | `ghcr.io/farelra/kalanidhi-payments:latest` | internal only, no route (private network `http://kalanidhi-payments:8080`) |
| livekit    | `livekit/livekit-server:v1.13.11` | `livekit.kalanidhi.site` (WSS) + `rtc.kalanidhi.site:5349` (TURN/TLS) |
| livekit-redis | `redis:8.2-alpine`          | internal only, no route                   |
| uptime-kuma | `louislam/uptime-kuma:next`    | `nkuma.farel.at.eu.org` (kuma's own auth) |
| waha       | `devlikeapro/waha:arm`         | `waha.farel.at.eu.org` (API key + dashboard auth) |
| couchdb    | `couchdb:latest`               | `couchdb.farel.at.eu.org`                 |
| sing-box   | `sagernet/sing-box`            | proxy tunnels under `/sing/*` (VLESS/VMess/Trojan × ws/ht/grpc/httpupgrade; `ht` = HTTP transport over H2c) |
| xray       | `ghcr.io/xtls/xray-core`       | proxy tunnels under `/xray/*` (VLESS/VMess/Trojan × ws/grpc/httpupgrade/xh; `xh` = XHTTP over H2c) |
| iodine     | Debian `iodine` (host systemd) | authoritative `dns.farel.is-a.dev` on UDP 53 (AndIodine/iodine clients) |
| tor-proxy  | `zhaowde/rotating-tor-http-proxy` | loopback `127.0.0.1:3128` only           |
| minecraft | `ghcr.io/farelra/farelmc` (CI from `FarelRA/farelmc`) | Java `mc.farel.is-a.dev:25565`, Bedrock `:19132`, voice `:24454/udp`, map `map.mc.farel.is-a.dev` |
| exambppp-convex | `ghcr.io/farelra/exambppp-convex@sha256:…` | `convex.exambppp.farel.is-a.dev` (3210), `convex-site.exambppp.farel.is-a.dev` (3211) |
| exambppp-convex-dashboard | `ghcr.io/convex/convex-dashboard:1447815c` | `convex-admin.exambppp.farel.is-a.dev` (basic auth) |
| exambppp-admin | `ghcr.io/farelra/exambppp-admin@sha256:…` | `admin.exambppp.farel.is-a.dev` |
| exambppp-update | `ghcr.io/farelra/exambppp-update@sha256:…` | `update.exambppp.farel.is-a.dev` (rate-limited) |
| exambppp-postgres | `postgres:17-alpine` | internal only |
| exambppp-s3 | `chrislusf/seaweedfs` | internal only |


All containers run **rootless** as the `podman` user (uid 986); ports 80/443 are
bound by rootlessport (`net.ipv4.ip_unprivileged_port_start=80`). Boot persistence
via `podman-restart.service` + `restart: always` + linger. A fresh host is
bootstrapped with `sudo bash deploy/setup.sh`.


### ExamBPPP Next notes

The ExamBPPP baseline lives in `~/projects/apps/exambppp-next`. This host runs
the self-hosted backend, admin web and update server from signed, digest-pinned
GHCR images. The source repo's `compose.yaml` is the portable stack; here the
services join the existing `router` network and Traefik edge.

- Backend env: `/home/podman/services/data/exambppp/convex.env` (600).
- Postgres env: `postgres.env`; S3 init: `rclone.env`; update: `update.env`.
- Data: `data/exambppp/{postgres,s3,convex,apk}`. Back these up.
- Deploy the app: `sudo -iu podman deploy exambppp-convex exambppp-admin exambppp-update`.
- Push functions from the app repo:
  `CONVEX_SELF_HOSTED_URL=https://convex.exambppp.farel.is-a.dev CONVEX_SELF_HOSTED_ADMIN_KEY="$(...)" bunx convex deploy`.
- DNS (Cloudflare, DNS-only): `admin`, `convex`, `convex-site`, `convex-admin`,
  `update` under `exambppp.farel.is-a.dev`.
- The update server serves `/v1/app/latest` and `/apk/exambppp-next.apk`; place
  the signed APK in `data/exambppp/apk/`.

### KalaNidhi Convex notes

KalaNidhi runs a **self-hosted Convex** backend (`convex`, ports 3210/3211) plus
the official dashboard (`convex-dashboard`, port 6791). No Convex Cloud.

- Images are pinned to `1447815c8c697c55a35ab0fff64aa7580ca01cc8`, the commit
  behind upstream release `precompiled-2026-10-22-1447815` (backend and
  dashboard share a commit). Upstream also publishes a floating `:latest`; a
  deploy of `:latest` would silently change the database version, so both stay
  pinned. Upgrade by changing both tags together, then
  `sudo -iu podman deploy convex convex-dashboard`.
- `INSTANCE_NAME=kalanidhi` and `INSTANCE_SECRET` live in
  `data/kalanidhi/convex.env` (600). Changing `INSTANCE_SECRET` after the first
  start invalidates admin keys; treat it as permanent.
- The database and file storage are the bind mount
  `data/kalanidhi/convex-data` (`/convex/data`). Nothing is stored in the
  container or in git.

DNS records (all point at the nodus box):

| Record | Purpose | Cloudflare |
| --- | --- | --- |
| `convex.kalanidhi.site` | Convex API + WebSocket (`CONVEX_CLOUD_ORIGIN`, client `CONVEX_URL`) | proxied or DNS-only |
| `convex-site.kalanidhi.site` | Convex HTTP actions (`CONVEX_SITE_ORIGIN`) | proxied or DNS-only |
| `convex-admin.kalanidhi.site` | Convex dashboard | proxied or DNS-only, basic auth enforced |

Traefik routes `convex.*` to 3210, `convex-site.*` to 3211, and
`convex-admin.*` to 6791 with `defaultAuth@file`. All three use the
`letsencrypt` resolver and `sslheader@file`. Let's Encrypt HTTP-01 needs TCP 80
to reach the box, so do not enable "Always Use HTTPS" before the certs exist.

Admin access:

- URL: <https://convex-admin.kalanidhi.site> (Traefik basic auth, then the
  Convex admin key).
- Key: `/home/podman/services/data/kalanidhi/convex-admin-key` (600). Generate
  it after the backend is healthy with
  `sudo bash deploy/setup-convex.sh --post`; the file is kept on re-runs.
- Read it with `sudo cat .../convex-admin-key`. It is never committed or
  printed by the setup script.

App env (`data/kalanidhi/.env`, generated, 600):

```dotenv
CONVEX_URL=https://convex.kalanidhi.site
NEXT_PUBLIC_CONVEX_URL=https://convex.kalanidhi.site
NEXT_PUBLIC_CONVEX_SITE_URL=https://convex-site.kalanidhi.site
```

Convex deployment env is applied by the CLI from the app repo, using the
secrets in `data/kalanidhi/convex-functions.env` (600):

```bash
export CONVEX_SELF_HOSTED_URL=https://convex.kalanidhi.site
export CONVEX_SELF_HOSTED_ADMIN_KEY="$(sudo cat /home/podman/services/data/kalanidhi/convex-admin-key)"
npx convex env set BETTER_AUTH_SECRET "$(sudo sed -n 's/^BETTER_AUTH_SECRET=//p' /home/podman/services/data/kalanidhi/convex-functions.env)"
npx convex env set SITE_URL https://kalanidhi.site
npx convex env set PAYMENTS_INTERNAL_KEY "$(sudo sed -n 's/^PAYMENTS_INTERNAL_KEY=//p' /home/podman/services/data/kalanidhi/convex-functions.env)"
npx convex deploy
```

Fresh deployment order:

```bash
sudo bash deploy/install.sh                 # files + env only, starts nothing
sudo -iu podman deploy livekit-redis livekit
sudo -iu podman deploy convex convex-dashboard
sudo bash deploy/setup-convex.sh --post     # writes the admin key + prints the CLI
# fill GOPAY_MERCHANT_ID / GOPAY_STATIC_QRIS in data/kalanidhi/payments.env first
sudo -iu podman deploy kalanidhi-payments
sudo -iu podman deploy kalanidhi            # convex healthy + payments started
```

Backup and restore of `data/kalanidhi/convex-data`:

```bash
# consistent filesystem backup: stop writes first
sudo -iu podman podman stop services-convex-1
sudo tar -C /home/podman/services/data/kalanidhi -czf /root/convex-data-$(date +%F).tgz convex-data
sudo -iu podman podman start services-convex-1

# restore (stop the backend, replace the directory, keep ownership)
sudo -iu podman podman stop services-convex-1
sudo mv /home/podman/services/data/kalanidhi/convex-data /home/podman/services/data/kalanidhi/convex-data.bak
sudo tar -C /home/podman/services/data/kalanidhi -xzf /root/convex-data-2026-01-01.tgz
sudo chown -R podman:podman /home/podman/services/data/kalanidhi/convex-data
sudo -iu podman podman start services-convex-1
```

A logical backup also works when the backend is reachable:
`npx convex export --include-file-storage --path snapshot.zip`, restored with
`npx convex import --replace-all snapshot.zip`.

### KalaNidhi LiveKit notes

LiveKit is self-hosted as `livekit/livekit-server:v1.13.11` (pinned minor
release; arm64 image available) with `redis:8.2-alpine` on a dedicated
`livekit-internal` bridge network. Redis has no published port and cannot reach
the internet; it keeps append-only state under
`data/kalanidhi/livekit-redis`. A single-node SFU does not strictly need Redis,
but it is the documented production layout and keeps room state across
restarts.

Generated state (never committed):

- `data/kalanidhi/livekit.env` (600): `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`,
  and the `LIVEKIT_KEYS` form. Generated once by `setup-livekit.sh`.
- `data/kalanidhi/livekit.yaml` (600): rendered from the env. Rotate the keypair
  by deleting both files, re-running `bash deploy/setup-livekit.sh`, then
  redeploying `livekit` and `kalanidhi`.

Ports:

| Host port | Proto | Purpose | Through Traefik? |
| --- | --- | --- | --- |
| 443 | TCP | signaling `wss://livekit.kalanidhi.site` | yes |
| 7881 | TCP | ICE/TCP fallback | no, direct |
| 50000-50100 | UDP | WebRTC media | no, direct |
| 50200-50300 | UDP | TURN relay allocations | no, direct |
| 3478 | UDP | TURN/UDP + STUN | no, direct |
| 5349 | TCP | TURN/TLS (`rtc.kalanidhi.site`) | Traefik terminates TLS, forwards plaintext TURN |

TURN/TLS deliberately uses Traefik's Let's Encrypt certificate: the TCP router
matches `HostSNI(rtc.kalanidhi.site)`, terminates TLS, and forwards to LiveKit
`5349` with `turn.external_tls: true`. LiveKit therefore needs no cert files,
and there is no second ACME client. TURN/UDP 3478 and the relay range stay
direct. Firewall/security-list rules must allow all six rows.

Because TLS terminates at Traefik, TURN's XOR-MAPPED-ADDRESS is Traefik's
private container IP instead of the client's. That is accepted by the clients
used here, but if one ever rejects it, either terminate TURN TLS inside LiveKit
with certificate files or enable Traefik's PROXY protocol v2 on the TCP
service and set `turn.proxy_protocol: true` with the router subnet as a trusted
CIDR.

DNS and proxy rules:

| Record | Cloudflare | Why |
| --- | --- | --- |
| `livekit.kalanidhi.site` | **DNS-only** | keeps WSS signaling on the origin instead of depending on Cloudflare's WebSocket/proxy behavior; media is direct anyway |
| `rtc.kalanidhi.site` | **DNS-only** | Cloudflare only proxies HTTP(S) on specific ports; 5349 and the UDP ranges must reach the origin unchanged |

Both records still need ACME HTTP-01 on TCP 80 (DNS-only does not affect that).
If `rtc` is proxied, TURN/TLS breaks. `livekit` can technically be proxied, but
DNS-only is the supported layout here.

App env (the keypair arrives through `env_file: livekit.env`):

```dotenv
LIVEKIT_URL=http://livekit:7880
NEXT_PUBLIC_LIVEKIT_URL=wss://livekit.kalanidhi.site
```

LiveKit recommends host networking for maximum media throughput. This stack
uses bridge networking because the service also needs Traefik labels for the
signaling route; published port ranges are 1:1, so `use_external_ip: true` still
advertises the correct public ports. If the box ever saturates CPU on
`rootlessport`, moving LiveKit to host networking means giving up the Traefik
signaling route or fronting it with a separate proxy.

### KalaNidhi payments gateway notes

`kalanidhi-payments` is the self-hosted GoPay/GoBiz gateway from
`FarelRA/kalanidhi-payments`. Its own CI publishes
`ghcr.io/farelra/kalanidhi-payments:latest`; nodus only pulls the image.

- **Private network only.** The service has no Traefik labels and no published
  port. It joins the `router` bridge and is reachable only as
  `http://kalanidhi-payments:8080` from other containers. Do not add a public
  route or a `ports:` mapping. The app's `depends_on` uses `service_started`
  so the landing site still comes up while the GoPay merchant fields are empty.
- **One instance only.** SQLite plus the single reconciler assume one writer.
  Do not scale replicas.
- **Rootless ownership.** The image runs as the non-root `app` user
  (uid 100/gid 101), so compose maps it onto the podman host account with
  `user: "100:101"` + `userns_mode: "keep-id:uid=100,gid=101"`. That is what
  makes the podman-owned `payments-data` bind mount writable. Keep both when
  editing the service; otherwise the gateway cannot create `payments.sqlite`.
- Generated state (never committed):
  - `data/kalanidhi/payments.env` (600): gateway env. Holds
    `INTERNAL_API_KEY`, `WEBHOOK_SECRET`, `SESSION_VAULT_PASSPHRASE`, and the
    provider settings.
  - `data/kalanidhi/payments-data/`: SQLite charges, encrypted session vault,
    transaction claims, and the webhook outbox (with `-wal`/`-shm` siblings).
- Env sharing: `deploy/setup-payments.sh` generates one internal key and one
  webhook secret, then shares them as:
  - app env `data/kalanidhi/.env`: `PAYMENTS_GATEWAY_URL=http://kalanidhi-payments:8080`,
    `PAYMENTS_INTERNAL_KEY`, `PAYMENTS_WEBHOOK_SECRET`;
  - `data/kalanidhi/convex-functions.env`: `PAYMENTS_INTERNAL_KEY` with the
    same value.

  The script adopts an existing `PAYMENTS_INTERNAL_KEY` from the Convex
  function env (so `install.sh`, which runs `setup-convex.sh` first, keeps one
  key), never overwrites existing non-empty values, and stops with an error if
  the existing files disagree.

- **Image visibility.** GHCR packages are private by default. If a pull fails
  with `unauthorized`, log the podman user in once with a token that can read
  packages (it is stored under the podman user's home, not in this repo):

  ```bash
  sudo -iu podman podman login ghcr.io -u <github-user>
  ```

  Otherwise make the package public. `deploy.sh` pulls the image as the podman
  user, so run the login as that user.

- **Fill the GoPay merchant fields before starting.** Edit the 600 env file and
  set `GOPAY_MERCHANT_ID` and `GOPAY_STATIC_QRIS` from the GoBiz dashboard:

  ```bash
  sudo -u podman "${EDITOR:-vi}" /home/podman/services/data/kalanidhi/payments.env
  ```

  `GOPAY_STATIC_QRIS` is the outlet's long `000201...` EMV payload. Startup
  validates its checksum and exits on an empty or placeholder value, so the
  container restarts until both fields are correct. Then deploy:

  ```bash
  sudo -iu podman deploy kalanidhi-payments
  ```

- **Connect the merchant session (OTP).** There is no host port, so call the
  gateway's `/v1/session/*` endpoints from inside the container. The container
  environment already holds the internal key, so it never appears on the host
  command line or in this repo. Check status:

  ```bash
  sudo -iu podman podman exec services-kalanidhi-payments-1 \
    node -e 'fetch("http://127.0.0.1:8080/v1/session/status",{headers:{"x-internal-key":process.env.INTERNAL_API_KEY}}).then(async r=>console.log(r.status,await r.text()))'
  ```

  Then POST `/v1/session/request-otp` with
  `{"phoneNumber":"+62..."}` and `/v1/session/verify-otp` with
  `{"otp":"...","otpToken":"..."}` using the same `x-internal-key` header; the
  gateway README has the exact request bodies. The gateway never logs the OTP,
  challenge token, or session, so keep them out of shell history and tickets.
  Confirm with `/v1/session/status` (`session` becomes `valid`). The sealed
  session survives restarts. Changing or losing `SESSION_VAULT_PASSPHRASE`
  makes the old envelope fail closed, so the operator must authenticate again
  with OTP.

- **Health.** `GET /v1/health` requires `x-internal-key`; the compose
  healthcheck sends it from the container env and never prints it. A
  `status: degraded` response with HTTP 200 only means no merchant session is
  connected. Alert on `session != valid`.

- **Backup.** Stop the gateway (or use SQLite's online backup API) and copy the
  data directory. Keep `payments.env` separately; the database does not contain
  the vault passphrase:

  ```bash
  sudo -iu podman podman stop services-kalanidhi-payments-1
  sudo tar -C /home/podman/services/data/kalanidhi -czf /root/payments-data-$(date +%F).tgz payments-data
  sudo -iu podman podman start services-kalanidhi-payments-1
  ```

  Restore the directory with ownership kept (`chown -R podman:podman
  .../payments-data`), keep the matching passphrase, start the gateway, and
  check `/v1/session/status`. Restoring only the database without the original
  passphrase requires a fresh OTP login.

- **Deployment order:** Convex -> payments gateway -> app.

  ```bash
  sudo bash deploy/install.sh
  sudo -iu podman deploy convex convex-dashboard
  sudo bash deploy/setup-convex.sh --post
  sudo -iu podman deploy kalanidhi-payments
  sudo -iu podman deploy kalanidhi
  ```

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

### uptime-kuma notes

- `louislam/uptime-kuma:next` is the rolling pre-release channel: it tracks
  the next Kuma release before it becomes stable, including database
  migrations. Back up `data/uptime-kuma` before updating, and expect possible
  breaking changes. Update with `sudo -iu podman deploy uptime-kuma`.

### waha notes

- WhatsApp HTTP API uses the NOWEB engine which is browserless with no Chromium. Sessions persist in
  `data/waha/.sessions`; media in `data/waha/.media`.
- `devlikeapro/waha:arm` is the floating arm64 build; upstream's `:latest` is
  amd64-only, so it cannot replace `:arm` on this Oracle ARM host.
- `deploy/setup-waha.sh` generates `data/waha/.env` (600): `WAHA_API_KEY`,
  dashboard + swagger creds. The committed template is
  `services/env/waha.env.example`. Re-scan the QR after a fresh host; sessions
  are not in the repo.
- Updating is easy because `:arm` floats. Run `podman compose pull waha` then `rm -f` plus `up -d` (compose
  no-ops on same tag), then `podman compose restart traefik` (stale backend).
- Used as the outbound notifier for uptime-kuma ("Orion Alert" notification).

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
  two-part change. First edit the config, then redeploy with

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
  a Traefik front. That means `ws` plus `grpc` (h2c) plus `httpupgrade` and XHTTP over h2c
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
  deprecation warnings, so prefer `xh` for new clients.
- Credentials are never committed: `bash deploy/setup-xray.sh` substitutes a
  fresh UUID (shared by the vless/vmess inbounds) and Trojan password into
  `services/xray/config.example.json`, validates the result with
  `xray run -test` in a throwaway container, and installs it to
  `data/xray/config.json` (644, podman-owned. The image runs as uid 65532).
  Pass `UUID=` / `TROJAN_PASSWORD=` to keep existing creds; to regenerate,
  delete the file and rerun.
- Apply: `sudo bash deploy/install.sh`, then `sudo -iu podman deploy xray`.
  The deploy probe follows the first router (`/xray/vless-ws`). A fresh host
  gets the same result from `sudo bash deploy/setup.sh`.
- Deliberately not exposed through Traefik: RAW (+XTLS Vision), REALITY, mKCP,
  QUIC and the Hysteria inbound stay out because they need their own TCP/UDP ports and
  terminate TLS/QUIC inside Xray. That would bypass the ACME certificate and
  Cloudflare in front of :443. Add a dedicated port + firewall rule if ever
  needed instead of bending the HTTP router.

### iodine DNS tunnel notes

`dns.farel.is-a.dev` is an authoritative DNS tunnel served by `iodined` for
AndIodine/iodine clients. It is a **host systemd service**, not a compose
service: iodine needs `/dev/net/tun` and `CAP_NET_ADMIN`, which rootless podman
cannot grant.

- Delegation (upserted by `deploy/setup-iodine.sh` through the Cloudflare API):

  | Record | Value | Notes |
  | --- | --- | --- |
  | `dns.farel.is-a.dev` | `NS nameserver.farel.is-a.dev` | tunnel zone |
  | `nameserver.farel.is-a.dev` | `A 168.110.200.57` | IPv4-only on purpose |

  `iodined` only listens on an IPv4 UDP socket. Do **not** add an AAAA to
  `nameserver`; an AAAA makes resolvers try IPv6 first and log
  `SERVFAIL`/EDE before falling back to IPv4. The legacy
  `batam.oracle.farel.is-a.dev` A/AAAA stays untouched for the web stack.

- Automation credentials live outside git in
  `/etc/nodus/cloudflare.env` (root:root 600): `CLOUDFLARE_API_TOKEN`,
  `CLOUDFLARE_ZONE_ID`, `CLOUDFLARE_ZONE_NAME`. The token needs
  `Zone -> DNS -> Edit` and `Zone -> Zone -> Read` on `farel.is-a.dev`.
  `setup-iodine.sh` sources that file, upserts the two records, and copies a
  token supplied in the environment into the file on first run. Without a
  token it prints the records to add manually.

- Config and secrets: `/etc/default/iodine` (600) holds the tunnel password
  and `IODINED_ARGS`; the Debian unit drops to the `iodine` user and chroots to
  `/run/iodine`. Back it up. Rotate the password by deleting the
  `IODINED_PASSWORD=` line and re-running `sudo bash deploy/setup-iodine.sh`
  (or just edit it and `sudo systemctl restart iodined`), then update the phone.

- Client (AndIodine):

  ```text
  Domain      dns.farel.is-a.dev
  Nameserver  1.1.1.1          # 8.8.8.8 also works
  Password    sudo sed -n 's/^IODINED_PASSWORD="\(.*\)"/\1/p' /etc/default/iodine
  ```

  Leave raw UDP mode off on mobile networks; the client falls back to DNS
  queries through the resolver. Public resolvers can log occasional
  `SERVFAIL`/`Received unsupported encoding` during codec autoprobing; the
  tunnel retries and still connects. Prefer `1.1.1.1` or `8.8.8.8` and the
  client's default autodetection.

- Firewall: host UDP 53 is opened by `setup.sh` and `setup-iodine.sh`. The
  Oracle/cloud security list must also allow UDP 53 ingress; that is external
  to this repo. Verify with `dig @1.1.1.1 dns.farel.is-a.dev NS` (should return
  `ns.dns.farel.is-a.dev` quickly, without `No Reachable Authority`).

- Operations:

  ```bash
  sudo systemctl status iodined
  sudo journalctl -u iodined -f
  sudo bash deploy/setup-iodine.sh            # converge config/DNS/firewall
  sudo bash deploy/setup-iodine.sh --no-start  # write config, do not restart
  ```

  `setup.sh` runs it automatically on a fresh host (`--no-host` skips host
  units, including iodine). Local smoke test:

  ```bash
  sudo timeout 20 iodine -f -P "$(sudo sed -n 's/^IODINED_PASSWORD="\(.*\)"/\1/p' /etc/default/iodine)" \
    10.0.0.2 dns.farel.is-a.dev
  ```

- Security: the tunnel is **not encrypted**; it only exposes IPv4. Run SSH,
  TLS, or another encrypted protocol inside it. `-c` accepts queries from any
  recursive resolver because mobile client IPs change, so treat the password
  as the only gate and keep it out of tickets/history. Egress from
  `10.20.0.0/24` is NATed to the default interface; clients can reach the
  internet, not the podman containers' private networks.

### minecraft notes

- Scope is Fabric 26.3 SMP with 61 pinned jars. The Via stack lets any Java
  version join. Geyser plus Floodgate lets current Bedrock join with no Java
  account. Ground truth is `FarelRA/farelmc`. CI builds
  `ghcr.io/farelra/farelmc` on every `main` push.
  Nodus only pulls the image and never builds it.
- Traefik manages ALL TLS: BlueMap `:8100` → `https://map.mc.farel.is-a.dev`,
  and NetherNet signaling `:19132` TCP → `https://mc.farel.is-a.dev` with plain
  HTTP to Geyser (`geyser-signal` router on its own entrypoint). Geyser trusts
  `10.89.0.0/24` via `signaling-trusted-proxies` so every Bedrock player keeps
  their real IP with no shared rate limit. Game UDP/TCP stay raw publishes.
  Traefik cannot proxy MC UDP or Bedrock WebRTC.
- Fresh deployment: `bash deploy/setup-minecraft.sh`, then
  `sudo bash deploy/install.sh`, then `sudo -iu podman deploy minecraft`.
  The deploy probe skips services with no `Host(` route because game ports
  are not HTTP, so container `running` is the gate. BlueMap route probes
  `https://map.mc.farel.is-a.dev` like every other web route.
- Live state (never in repo): `data/minecraft/` (world + player files,
  bind-mounted `/data`), `data/minecraft/config/` (tuned defaults seeded from
  farelmc; the server may add version stamps), `data/minecraft/state/nethernet/`
  (holds identity.pem which is the Geyser identity), `data/minecraft/.env`
  (mode 600). Floodgate `key.pem` now lives only on the box, never in git.
  Back it up. Rotating it orphans linked Bedrock accounts.
- Updating mods means editing `FarelRA/farelmc` and pushing (CI rebuilds),
  then running `sudo -iu podman deploy minecraft`.
  The fresh image seeds new jars with `cp -n`.
