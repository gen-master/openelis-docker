#!/usr/bin/env bash
# Jenkins "Execute shell" body for the gen-UAT deploy. Runs ON THE VM (agent with docker access).
# Idempotent: the first run bootstraps (network, alias, db-init creates the DB), later runs upgrade.
# No `set -x`: the env file holds passwords.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/openelis/uat/app}"          # persistent clone - NOT $WORKSPACE: the bind mounts live here
REPO_URL="${REPO_URL:-https://github.com/gen-master/openelis-docker.git}"
GIT_REF="${GIT_REF:-gen-UAT}"
BACKUP_DIR="${BACKUP_DIR:-/srv/openelis/uat/backups}"
SECRETS_FILE="${SECRETS_FILE:-/srv/openelis/uat/secrets.env}"   # optional: OE_DB_PASSWORD / PG_SUPERUSER_PASSWORD kept out of git
C="docker compose"

echo "== 1. code"   # clone once, then fast-forward only. Never reset --hard: containers write root-owned files under configs/logs
[ -d "$APP_DIR/.git" ] || git clone --branch "$GIT_REF" "$REPO_URL" "$APP_DIR"
cd "$APP_DIR"
git fetch origin "$GIT_REF"
git merge --ff-only "origin/$GIT_REF"
echo "deploying $(git rev-parse --short HEAD) ($GIT_REF)"

ENV_FILE="$APP_DIR/.env"
[ -f "$SECRETS_FILE" ] && { set -a; . "$SECRETS_FILE"; set +a; }
v() { local x; eval "x=\${$1:-}"; [ -n "$x" ] && { echo "$x"; return; }; grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | sed 's/#.*//' | tr -d '[:space:]'; }
for k in TZ OE_DATA_DIR OE_DB_PASSWORD OE_SITE_CODE PG_SUPERUSER PG_SUPERUSER_PASSWORD PG_CONTAINER; do
  [ -n "$(v "$k")" ] || { echo "ERROR: $k is empty in $ENV_FILE (or $SECRETS_FILE)"; exit 1; }
done
PG=$(v PG_CONTAINER); DATA_DIR=$(v OE_DATA_DIR); API_PORT=$(v OE_API_LOCAL_PORT); API_PORT=${API_PORT:-8443}

echo "== 2. assertions"
! grep -q ':develop' docker-compose.yml || { echo "ERROR: ':develop' tag in docker-compose.yml"; exit 1; }
$C config -q
[ "$($C config --services | grep -c '^db.openelis.org$')" = 0 ] || { echo "ERROR: db.openelis.org service is back in compose"; exit 1; }

echo "== 3. plumbing (idempotent, no Postgres restart)"
docker inspect "$PG" >/dev/null
docker network inspect openelis-network >/dev/null 2>&1 || docker network create --subnet 172.20.1.0/24 openelis-network
docker inspect -f '{{json .NetworkSettings.Networks}}' "$PG" | grep -q '"openelis-network"' \
  || docker network connect --alias db.openelis.org openelis-network "$PG"
mkdir -p "$DATA_DIR/nce-attachments" "$BACKUP_DIR"

echo "== 4. backup (upgrades only - skipped until clinlims exists)"
if docker exec -e PGPASSWORD="$(v OE_DB_PASSWORD)" "$PG" psql -U clinlims -d clinlims -tAc 'select 1' >/dev/null 2>&1; then
  STAMP=$(date +%F-%H%M)
  docker exec -e PGPASSWORD="$(v OE_DB_PASSWORD)" "$PG" pg_dump -U clinlims -Fc clinlims > "$BACKUP_DIR/clinlims-$STAMP.dump"
  tar czf "$BACKUP_DIR/nce-$STAMP.tgz" -C "$DATA_DIR" nce-attachments
  echo "backup: $BACKUP_DIR/clinlims-$STAMP.dump"
else
  echo "first deploy: no clinlims database yet - db-init will create it"
fi

echo "== 5. deploy"   # `up -d` itself blocks on db-init and fails if db-init fails (depends_on: service_completed_successfully)
$C pull -q
$C up -d --remove-orphans
$C logs --no-color db-init | tail -3

echo "== 6. wait for the app (first start runs 385 Liquibase changesets: allow 20 min)"
for i in $(seq 1 120); do
  code=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$API_PORT/api/OpenELIS-Global/" || true)
  case "$code" in 2*|302) echo "app up after $((i*10))s (HTTP $code)"; break;; esac
  if [ "$i" = 120 ]; then echo "ERROR: app not up after 20 min (last HTTP $code)"; $C logs --no-color --tail 60 oe.openelis.org; exit 1; fi
  sleep 10
done

echo "== 7. done"
docker image prune -f >/dev/null
$C ps
