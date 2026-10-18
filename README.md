# nodus-infra

Infrastructure-as-code for the **nodus** server (Oracle Cloud ARM, Debian, rootless podman).

Everything that defines the running stack lives here; the server references these files directly.

## Layout

| Path                          | Deployed to (copied by `install.sh`)          | Purpose                                 |
| ----------------------------- | -------------------------------------------- | --------------------------------------- |
| `services/docker-compose.yml` | `/home/podman/services/docker-compose.yml`   | The full production stack (single source of truth) |
| `services/traefik-dynamic.yml`| `/home/podman/services/data/traefik/dynamic.yml` | Traefik middlewares (basicAuth, sslheader) |
| `deploy/deploy.sh`            | `/home/podman/bin/deploy` (via install.sh)   | Pull → recreate → health-verify → auto-rollback |

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
| pitch      | `farelra/growmate-pitch`       | `pitch.growmate.bond`                     |
| convex     | `get-convex/convex-backend`    | `convex.growmate.bond`                    |
| rustfs     | `rustfs/rustfs`                | `storage.growmate.bond`                   |
| fabula     | `farelra/fabula`               | `fabula.farel.at.eu.org`                  |
| fabula-convex | `convex/convex-backend` (pinned) | `fabula-api.farel.at.eu.org` (API), `fabula-site.farel.at.eu.org` (actions) |
| fabula-dashboard | `convex/convex-dashboard` (pinned) | `fabula-admin.farel.at.eu.org` (auth) |
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
  upstream). `rustfs/rustfs:latest` floats like the rest of the stack
  (rollback via deploy retag).
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

### fabula notes

- Three services: `fabula` (Next.js app), `fabula-convex` (its own Convex
  backend, image pinned so backend and dashboard stay paired), and
  `fabula-dashboard` (public behind `defaultAuth@file`; the deployment admin
  key gates the deployment on top of that).
- Functions live with the code, not the image. After every release of
  `FarelRA/fabula`, deploy functions against the server backend, then
  recreate the app:

  ```bash
  cd ~/projects/apps/fabula
  export CONVEX_SELF_HOSTED_URL=https://fabula-api.farel.at.eu.org
  export CONVEX_SELF_HOSTED_ADMIN_KEY="$(sudo -iu podman podman exec services-fabula-convex-1 ./generate_admin_key.sh | grep '|')"
  bunx convex deploy --yes     # fallback: bunx convex dev --once
  sudo -iu podman deploy fabula
  ```

- The app image bakes `NEXT_PUBLIC_CONVEX_URL` at build time from the
  repository variable of the same name (currently
  `https://fabula-api.farel.at.eu.org`). Changing the public origin needs a
  fresh release tag, not just a compose edit.
- `INSTANCE_SECRET` (hex, `openssl rand -hex 32`) lives in
  `data/fabula/.env` and must never change for the life of the instance;
  losing it means losing the deployment.
- Convex Auth keys: a fresh deployment also needs `SITE_URL` and an RS256
  keypair (`JWT_PRIVATE_KEY`, `JWKS`) or every sign-in fails. Already set on
  this box; the release drill provisions them for local stacks. If sign-in
  ever reports a missing `JWT_PRIVATE_KEY`, this is the fix.
- Deployment env (`convex env set` against the self-hosted URL with the
  admin key, or the fabula-dashboard): `OPENAI_API_KEY` and `OPENAI_BASE_URL`
  point the model gateway at the operator's OpenAI-compatible endpoint,
  `FABULA_MODEL_SPOTLIGHT` / `FABULA_MODEL_STANDARD` / `FABULA_MODEL_CHEAP`
  select the model per tier, and `FABULA_IMAGE_MODEL` enables avatar images
  through the gateway (unset keeps the gradient+monogram placeholder). Keys
  never enter this repo.
- Backups: tar the `data/fabula/convex-data` path (the backend bind-mounts
  it so the data sits on the host disk directly).
- Both convex hostnames and the app resolve their public origin to
  `host-gateway` inside the container so server-side calls re-enter through
  traefik :443 (the public IP is closed for self-hairpin, same as growmate).
- Kuma coverage: HTTP monitors for the three public routes (app 200, api
  `/version` 200, admin 401 without credentials) plus docker state monitors
  per the coverage invariant.

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
