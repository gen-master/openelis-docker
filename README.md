# OpenELIS Global 2 — gen-UAT deployment

Fork of [DIGI-UW/openelis-docker](https://github.com/DIGI-UW/openelis-docker) (the deployment repo named in
OpenELIS's own [install guide](https://github.com/DIGI-UW/OpenELIS-Global-2/blob/develop/docs/install.md)),
adapted to run OpenELIS **3.2.2.0** on a VM that already has a Postgres container. Upstream's original README
(online/offline installer) is superseded by this one; the offline installer (`build.sh`, `install/`) is not used.

## What is different from upstream

| Area | Upstream | This fork |
|---|---|---|
| Database | its own `db.openelis.org` Postgres container | **your existing Postgres container**, reached as `db.openelis.org` through a network alias — never restarted, never recreated by this stack |
| Database creation | done by the DB container's init scripts | a one-shot `db-init` service does it on `docker compose up` if database `clinlims` does not exist; no-op afterwards |
| Image tags | `:develop` (moving) | pinned `:3.2.2.0` on all 5 app images |
| Host ports | 80, 443, 8080, 8443, 8081, 8444, 15432 | two, **bound to 127.0.0.1 only**: `${OE_UI_LOCAL_PORT}` → frontend, `${OE_API_LOCAL_PORT}` → Tomcat 8443, consumed by the host nginx. Nothing is public |
| Reverse proxy / TLS | `proxy` nginx container with a self-signed cert | **removed** — the nginx installed on the VM routes `/` and `/api/` and terminates TLS with your certificate ([Host nginx](#host-nginx)) |
| autoheal | restarts unhealthy containers | **removed** — no service defines a healthcheck, and it mounted the Docker socket |
| Network | created by compose | `openelis-network` is **external** — created once on the VM so Postgres can join it before compose runs |
| Customer uploads (`nce-attachments`) | inside the repo tree | `${OE_DATA_DIR}/nce-attachments`, outside the clone |
| Configuration values | hardcoded in compose; `.env` tracked | all in `.env`, which is **not in git** — `.env.example` is the template, the real file is a Jenkins Secret file credential; missing values block startup (`${VAR:?}`) |
| Deployment | manual | `jenkins/deploy.sh` (also runnable by hand) |

Everything else — `configs/`, nginx template, plugins, translations — is upstream's, unchanged.

## `.env` — the single configuration file

Compose reads it automatically from this directory; `jenkins/deploy.sh` reads the same file. It is **not in git**
(it holds passwords). The tracked template is `.env.example`; the real `.env` lives in Jenkins as a *Secret file*
credential and is written into the clone on every build — see [Deploying with Jenkins](#deploying-with-jenkins).

| Variable | Meaning | Change it… | Secret |
|---|---|---|---|
| `PG_CONTAINER` | name of the existing Postgres container (`docker ps`) | any time | no |
| `OE_DB_PORT` | port Postgres listens on **inside** its container (`show port`). The host-published port is irrelevant — traffic is container-to-container | any time (restart stack) | no |
| `PG_SUPERUSER` / `PG_SUPERUSER_PASSWORD` | Postgres superuser. Used **only** by `db-init` to create the role and database; the application never receives it | any time | **yes** |
| `OE_DB_PASSWORD` | password of role `clinlims`. `db-init` creates the role with it; the app and FHIR server connect with it | before first `up`. Later = `ALTER ROLE clinlims PASSWORD` + update here + restart | **yes** |
| `OE_SITE_CODE` | replaces upstream's `DEV01`: the site number **and the accession-number prefix**. Short, uppercase, alphanumeric | **immutable once the first sample exists** | no |
| `OE_UI_LOCAL_PORT` / `OE_API_LOCAL_PORT` | loopback ports (defaults 3000 / 8443) on which the frontend and Tomcat are published **for the host nginx only**; unreachable from outside the VM | any time (restart stack; update the nginx `proxy_pass`) | no |
| `TZ` | timezone for the app, FHIR and autoheal containers; match the VM/Postgres zone | any time (restart) | no |
| `OE_DATA_DIR` | host directory for persistent data outside the clone; uploads go to `$OE_DATA_DIR/nce-attachments` | before first `up` | no |
| `SSL_KEYSTORE_PASSWORD` / `SSL_TRUSTSTORE_PASSWORD` | Java keystores for app ↔ FHIR TLS, generated once by the `certs` service into a named volume. **Must also match** `KEYSTORE_PW` / `TRUSTSTORE_PW` hardcoded on the `certs` service in `docker-compose.yml` | **before first `up` only**. Later requires deleting volumes `key_trust-store-volume`, `certs-vol`, `keys-vol` and re-running | yes |

Also change before first `up`, in `docker-compose.yml`: `DEFAULT_PW=adminADMIN!` on `oe.openelis.org` (the
initial UI admin password) and the FHIR admin credentials in `configs/properties/common.properties:13-14`.

### Where the real `.env` lives

In Jenkins, as a **Secret file** credential (Credentials → Add → Kind: *Secret file* → upload your filled-in
`.env` → ID `openelis-uat-env`). Nothing with a password is ever in git; `.env` is in `.gitignore`. The build
binds that credential to `OE_ENV_FILE`, and `deploy.sh` copies it to `/srv/openelis/uat/app/.env` (`chmod 600`)
before validating and deploying. To change any value — password or not — update the credential and Build.
A new *key* (not just a value) also goes into `.env.example` and `docker-compose.yml`, through git.

## Before deploying — check on the VM

```bash
docker compose version                                    # v2 ("docker compose", no dash) is required: depends_on conditions
docker exec <PG> postgres --version                       # 13+ preferred; 12 and below also work (db-init creates the extensions as superuser)
docker exec -it <PG> psql -U <SUPERUSER> -W -c 'show port' -c 'show timezone' -c 'show max_connections'
docker exec -it <PG> psql -U <SUPERUSER> -W -c "select 1 from pg_database where datname='clinlims'"   # must be empty on a first deploy
docker network inspect -f '{{.Name}}: {{range .IPAM.Config}}{{.Subnet}} {{end}}' $(docker network ls -q)  # 172.20.1.0/24 must be free
ip route | grep '172\.20\.'                                                                              # …and not the VM's LAN
ss -ltn | grep -E '127\.0\.0\.1:(3000|8443) '                                                            # must be empty, or change OE_*_LOCAL_PORT
```

Also:

- `pg_hba.conf` must accept role `clinlims` from `172.20.1.0/24` (the app's fixed address is `172.20.1.121`).
  If Postgres restricts by address: `host clinlims clinlims 172.20.1.0/24 scram-sha-256`.
- `max_connections`: the app pool is 20 and the FHIR server has its own; budget ~30 on top of your other clients.
- If `172.20.1.0/24` collides: change it in the `docker network create` below **and** `ipv4_address: 172.20.1.121`
  in `docker-compose.yml`, and in `pg_hba.conf`.

## First deployment

Manual version — `jenkins/deploy.sh` does exactly this, idempotently.

```bash
git clone --branch gen-UAT https://github.com/gen-master/openelis-docker.git /srv/openelis/uat/app
cd /srv/openelis/uat/app
cp .env.example .env && vi .env                              # fill every empty value (see table above); .env is gitignored
mkdir -p /srv/openelis/uat/nce-attachments

docker network create --subnet 172.20.1.0/24 openelis-network
docker network connect --alias db.openelis.org openelis-network <PG_CONTAINER>   # attaches the RUNNING container; no restart

docker compose config -q                                     # fails here if any ${VAR:?} is empty
docker compose up -d
docker compose logs -f db-init                               # ends with: db-init: done - 167 tables in clinlims
docker compose logs -f oe.openelis.org                       # first start runs 385 Liquibase changesets: several minutes. Do not restart mid-way.
```

Then add the [host nginx](#host-nginx) server block, reload nginx, and open `https://<your hostname>/` — user
`admin`, password = `DEFAULT_PW`. `docker compose ps` should show `oe-certs` and `openelis-db-init` as
`Exited (0)` and the other three `Up`.

The alias survives Postgres `stop`/`start`/`restart` and VM reboots. It is lost only if the Postgres
**container is recreated** (new image pulled, its compose edited, host move). For that day, add to the Postgres
stack's compose file:

```yaml
services:
  <pg service>:
    networks:
      default:
      openelis-network:
        aliases: [db.openelis.org]
networks:
  openelis-network:
    external: true
```

Do not `docker compose up -d` the Postgres stack merely to apply this — that itself recreates the container.

## Deploying with Jenkins

Jenkins runs as a container with no Docker socket; it reaches the host through a named pipe that executes
command lines, and the host filesystem mounted at `/host`. The deploy is a single Execute-shell step in the
job (no scripts in this repo): it copies the `.env` Secret-file credential (variable `OE_ENV_FILE`) to the host
clone, writes `git clone`/`git merge --ff-only` and `docker compose pull && up -d` lines to the pipe, and waits
for a result file the last piped command writes. `.env` is untracked, so the fast-forward never conflicts with it.

## Upgrading to a new OpenELIS release

On the workstation:

```bash
git fetch upstream --tags
git log <last merged SHA>..upstream/main --oneline -- docker-compose.yml configs .env   # what changed on the deployment side
git merge upstream/main                                    # conflicts, if any, are in files this fork edited
grep -n ':develop' docker-compose.yml                      # must print nothing after the merge
sed -i 's/:3\.2\.2\.0/:<NEW>/g' docker-compose.yml         # all 5 image lines (db-init uses the database image)
git commit -am "upgrade 3.2.2.0 -> <NEW>" && git push origin gen-UAT
```

Then run the Jenkins job (or `jenkins/deploy.sh` by hand). Rules:

- **Rehearse on UAT with a `pg_restore` of production first.** Liquibase migrations are forward-only; there is no
  app-level rollback. Rollback = `pg_restore --clean` of the backup the script took + revert the tag + `up -d`.
- **Do not skip releases** — step through each tag between current and target.
- Check whether the new release's DB image moved to a newer Postgres major (`db/Dockerfile` `FROM` line in the
  app repo — `postgres:14.4` today). If it exceeds your server's major, upgrade Postgres first; this stack never touches it.
- `db-init` bumps with the same tag automatically; on an existing database it does nothing.
- Upstream still tracks `.env`; this fork removed it. If a release touches upstream's `.env`, the merge reports a
  modify/delete conflict on it: resolve with `git rm .env`, and carry any *new key* into `.env.example` and the
  Jenkins credential.

## Configuration after deployment

- Prefer **Admin → Site Information** in the UI for any setting that has one. `configs/properties/SystemConfiguration.properties`
  **overrides** the database and removes UI editability for that setting — use it only for settings with no UI.
- If you set `org.openelisglobal.configuration.autocreate=true` (seed tests/sample types from
  `configs/configuration/backend/`), set `org.openelisglobal.configuration.forcereload=false` in the same change,
  or every restart re-applies the CSVs over edits made in the UI.
- UI wording: `configs/translation/` (see its README); requires `OVERRIDE_DEFAULT_TRANSLATION=true`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `compose up`: `required variable X is missing a value: set in .env` | empty value in `.env` | fill it |
| `db-init`: `Postgres not reachable after 120s` | alias not attached, wrong `OE_DB_PORT`, or wrong `PG_CONTAINER` | `docker inspect <PG>` → Networks must list `openelis-network` with alias `db.openelis.org`; check `show port` |
| `db-init`: `password authentication failed for user "<superuser>"` | `PG_SUPERUSER*` wrong | fix the Jenkins credential (or `.env` if by hand), deploy again (safe: nothing was created) |
| `db-init`: `role "clinlims" already exists` but database missing | a previous partial run | `DROP ROLE clinlims;` as superuser, `up -d` again |
| webapp: `no pg_hba.conf entry for host "172.20.1.121"` | Postgres rejects the subnet | `pg_hba.conf` line above, reload Postgres |
| webapp: `UnknownHostException: db.openelis.org` | Postgres container was recreated, alias gone | re-run the `docker network connect --alias …` line |
| webapp stuck on `Waiting for changelog lock` | crash during a previous migration | `UPDATE clinlims.databasechangeloglock SET locked=false, lockgranted=NULL, lockedby=NULL;` then restart |
| `network openelis-network declared as external, but could not be found` | network not created yet | the `docker network create` line |
| `port is already allocated` | `127.0.0.1:3000` or `:8443` already in use on the host | change `OE_UI_LOCAL_PORT` / `OE_API_LOCAL_PORT` and the nginx `proxy_pass` lines |
| browser: UI loads, every API call fails / login loops | `/api/` not routed to Tomcat, or routed to a different host than `/` (session cookie is `SameSite=strict`) | both `location` blocks must be in the **same** `server` block |
| nginx: `502` on `/api/` | Tomcat still starting (Liquibase), or `proxy_pass` scheme is `http://` against 8443 | wait; `/api/` must be `https://127.0.0.1:<OE_API_LOCAL_PORT>` |
| `compose down` prints `has active endpoints` | expected — Postgres is attached; the external network stays | nothing |

## Host nginx

The browser loads the UI from one origin and calls `/api/OpenELIS-Global/…` as a relative URL on that same
origin, so a single `server` block must serve both routes — split them across hosts or ports and the
`SameSite=strict` session cookie never reaches the API. The stack publishes the two backends on loopback
only; nginx on the VM is the only public entry point and carries your certificate.

```nginx
server {
    listen 443 ssl;
    server_name <your hostname>;
    ssl_certificate     /etc/ssl/<your>/fullchain.pem;
    ssl_certificate_key /etc/ssl/<your>/privkey.pem;
    client_max_body_size 50m;                       # NCE attachments / imports

    location / {
        proxy_pass http://127.0.0.1:3000;           # OE_UI_LOCAL_PORT
        proxy_set_header Host $host;
    }
    location /api/ {
        proxy_pass https://127.0.0.1:8443/api/;     # OE_API_LOCAL_PORT — Tomcat's own self-signed cert; nginx does not verify upstreams by default
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $server_name;
        proxy_read_timeout 300s;                    # reports and imports can be slow
    }
}
```

`nginx -t && systemctl reload nginx`. This mirrors what upstream's `configs/nginx/nginx.conf` did inside the
removed proxy container; that file stays in the repo untouched (upstream's) but nothing reads it.

The `certs` service still runs once: it generates the *Java* keystore Tomcat needs for its 8443 listener and for
talking to the FHIR server. Your certificate replaces only the browser-facing one.
