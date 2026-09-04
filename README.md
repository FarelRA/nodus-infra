# nodus-infra

Infrastructure-as-code for the **nodus** server (Oracle Cloud ARM, Debian, rootless podman).

Everything that defines the running stack lives here; the server references these files directly.

## Layout

| Path                          | Deployed to (symlinked)                      | Purpose                                 |
| ----------------------------- | -------------------------------------------- | --------------------------------------- |
| `services/docker-compose.yml` | `/home/podman/services/docker-compose.yml`   | The full 11-service stack (single source of truth) |
| `services/traefik-dynamic.yml`| `/home/podman/services/data/traefik/dynamic.yml` | Traefik middlewares (basicAuth, sslheader) |
| `deploy/deploy.sh`            | `/home/podman/bin/deploy` (via install.sh)   | Pull → recreate → health-verify → auto-rollback |

## App CI/CD

Applications are built by GitHub Actions in their own repos (`FarelRA/farelfolio`,
`FarelRA/osis-sman1bantul`, `FarelRA/sijimban`, `FarelRA/randomting`,
`FarelRA/growmate-app`) and published to GHCR. Deploying a new app version:

```bash
sudo -iu podman deploy farelfolio        # or: osis sijimban randomting growmate
```

`deploy` waits for the container healthcheck, verifies it, and rolls back to the
previous image automatically if the new one fails to become healthy.

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
| osis       | `farelra/osis-sman1bantul`     | `osis.farel.is-a.dev`                     |
| sijimban   | `farelra/sijimban`             | `sijimban.site`                           |
| randomting | `farelra/randomting`           | internal only                             |
| growmate   | `farelra/growmate-app`         | `growmate.bond`                           |
| convex     | `get-convex/convex-backend`    | `convex.growmate.bond`                    |
| minio      | `minio/minio`                  | `storage.growmate.bond`                   |
| couchdb    | `couchdb:latest`               | `couchdb.farel.at.eu.org`                 |
| sing-box   | `sagernet/sing-box`            | proxy tunnels (VLESS/VMess/Trojan)        |

All containers run **rootless** as the `podman` user (uid 986); ports 80/443 are
bound by rootlessport (`net.ipv4.ip_unprivileged_port_start=80`). Boot persistence
via `podman-restart.service` + `restart: always` + linger.
