# nodus-infra

Infrastructure-as-code for the **nodus** server (Oracle Cloud ARM, Debian, rootless podman).

Everything that defines the running stack lives here; the server references these files directly.

## Layout

| Path                          | Deployed to (copied by `install.sh`)          | Purpose                                 |
| ----------------------------- | -------------------------------------------- | --------------------------------------- |
| `services/docker-compose.yml` | `/home/podman/services/docker-compose.yml`   | The full 12-service stack (single source of truth) |
| `services/traefik-dynamic.yml`| `/home/podman/services/data/traefik/dynamic.yml` | Traefik middlewares (basicAuth, sslheader) |
| `deploy/deploy.sh`            | `/home/podman/bin/deploy` (via install.sh)   | Pull → recreate → health-verify → auto-rollback |

## App CI/CD

Applications are built by GitHub Actions in their own repos (`FarelRA/farelfolio`,
`FarelRA/osis-sman1bantul`, `FarelRA/sijimban`,
`FarelRA/growmate-app`) and published to GHCR. Deploying a new app version:

```bash
sudo -iu podman deploy farelfolio        # or: osis sijimban growmate
```

`deploy` waits for the container to come up, probes the public route through Traefik
(auto-bounces Traefik on a stale backend), and rolls back to the previous image
automatically if the probe fails.

## Infrastructure changes

1. Edit `services/docker-compose.yml` or `traefik-dynamic.yml` in this repo
2. Commit + push
3. Apply: `install.sh` re-links (files are symlinks, so edits apply instantly after push/pull)

## Stack inventory

| Service    | Image                          | Public route                              |
| ---------- | ------------------------------ | ----------------------------------------- |
| traefik    | `traefik:latest`               | all HTTPS ingress, dashboard (auth)       |
| webservice | static-web-server              | `farel.at.eu.org` (/priv behind auth)     |
| farelfolio | `farelra/farelfolio`           | `farel.is-a.dev`                          |
| jaringan-hayati | `farelra/jaringan-hayati` | `farel.is-a.dev/assignment/jaringan-hayati` |
| osis       | `farelra/osis-sman1bantul`     | `osis.farel.is-a.dev`                     |
| sijimban   | `farelra/sijimban`             | `sijimban.site`                           |
| uptime-kuma | `louislam/uptime-kuma:2`       | `nkuma.farel.at.eu.org` (kuma's own auth) |
| waha       | `devlikeapro/waha:arm`         | `waha.farel.at.eu.org` (API key + dashboard auth) |
| growmate   | `farelra/growmate-app`         | `growmate.bond`                           |
| convex     | `get-convex/convex-backend`    | `convex.growmate.bond`                    |
| rustfs     | `rustfs/rustfs`                | `storage.growmate.bond`                   |
| couchdb    | `couchdb:latest`               | `couchdb.farel.at.eu.org`                 |
| sing-box   | `sagernet/sing-box`            | proxy tunnels (VLESS/VMess/Trojan)        |

All containers run **rootless** as the `podman` user (uid 986); ports 80/443 are
bound by rootlessport (`net.ipv4.ip_unprivileged_port_start=80`). Boot persistence
via `podman-restart.service` + `restart: always` + linger.

### waha notes

- WhatsApp HTTP API (NOWEB engine — browserless, no Chromium). Sessions persist in
  `data/waha/.sessions`; media in `data/waha/.media`.
- Secrets in `data/waha/.env` (600, not in repo): `WAHA_API_KEY`, dashboard + swagger creds.
- Updating: `:arm` floats — `podman compose pull waha` then `rm -f` + `up -d` (compose
  no-ops on same tag), then `podman compose restart traefik` (stale backend).
- Used as the outbound notifier for uptime-kuma ("Orion Alert" notification).

### rustfs notes

- S3-compatible store for `growmate` + `convex` (MinIO is deprecated
  upstream). RustFS 1.0.1, pinned — re-pin deliberately, never `:latest`.
  S3 wire-compat verified live (bucket create/policy, presigned URLs,
  private-bucket denial, deletes) against the exact aws-sdk calls the app
  makes; app image `farelra/growmate-app:91c5c98`+ reads `RUSTFS_*` env
  (the old `MINIO_*` names are dead — rename them everywhere, values can stay).
- Fresh volume REQUIRED (`rustfs-data`): RustFS cannot read MinIO's on-disk
  format. Buckets self-create on first upload; re-upload seed images with
  `convex run seed:comprehensive`; past `recordings` regenerate under TTL.
  Keep the old `minio-data` volume on the server until the cutover is
  verified — it is the rollback path (old app image + `minio/minio`).
- Runs as upstream uid 10001; named volume needs no ownership fix.
- Secrets in `data/rustfs/.env` (600, not in repo):
  `RUSTFS_ACCESS_KEY=<random 20+ chars>`,
  `RUSTFS_SECRET_KEY=<old MINIO_ROOT_PASSWORD reuse is fine>`.
  Server-side renames needed: `data/growmate/.env` and `data/convex/.env`
  (`MINIO_ENDPOINT/ACCESS_KEY/SECRET_KEY/BUCKET_IMAGE` → `RUSTFS_*`,
  endpoint `http://rustfs:9000`) plus the matching
  `npx convex env set RUSTFS_*` values. Console enabled but unrouted;
  health at `/health`.
- Cutover order: `deploy rustfs` (empty store) → `deploy growmate`
  (pulls `:latest`) → reseed → verify `https://growmate.bond`,
  a catalog image URL, and one recording playback.

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
