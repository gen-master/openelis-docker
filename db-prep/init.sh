#!/bin/sh
# Entry point of the db-init service. Runs inside itechuw/openelis-global-2-database:<tag>,
# which ships /docker-entrypoint-initdb.d/OpenELIS-Global.sql and siteInfo.sql for that tag.
set -eu
for k in OE_DB_PASSWORD OE_SITE_CODE PG_SUPERUSER PG_SUPERUSER_PASSWORD; do
  eval "x=\${$k:-}"; [ -n "$x" ] || { echo "db-init: $k is empty in .env"; exit 1; }
done
export PGHOST=db.openelis.org PGPORT="${OE_DB_PORT:-5432}"

echo "db-init: waiting for Postgres at $PGHOST:$PGPORT"
i=0; until pg_isready -q -U "$PG_SUPERUSER"; do i=$((i+1)); [ $i -ge 60 ] && { echo "db-init: Postgres not reachable after 120s"; exit 1; }; sleep 2; done

export PGPASSWORD="$PG_SUPERUSER_PASSWORD"
q() { psql -U "$PG_SUPERUSER" -d "$1" -tAc "$2"; }
if [ "$(q postgres "select 1 from pg_database where datname='clinlims'")" = "1" ]; then
  # database exists: complete only if the baseline is in it (login_user is a baseline table)
  if [ "$(q clinlims "select 1 from information_schema.tables where table_schema='clinlims' and table_name='login_user'")" = "1" ]; then
    echo "db-init: database clinlims exists with baseline - nothing to do"; exit 0
  fi
  echo "db-init: database clinlims exists but has no baseline schema (an earlier run failed) - loading it"
  q clinlims "drop table if exists clinlims.databasechangelog, clinlims.databasechangeloglock" >/dev/null   # left by a webapp start against the empty db
  q clinlims 'create extension if not exists "uuid-ossp"; create extension if not exists unaccent' >/dev/null
else
  echo "db-init: creating role + database + extensions"
  psql -U "$PG_SUPERUSER" -d postgres -v ON_ERROR_STOP=1 -v pw="$OE_DB_PASSWORD" -f /db-prep/roles.sql
fi

# Baseline + site rows run as the superuser, exactly like the stock DB image does (the dump carries
# COMMENT ON EXTENSION and OWNER TO postgres for tablefunc, which only a superuser may run). App objects
# still end up owned by clinlims: the dump says so explicitly (OWNER TO clinlims).
echo "db-init: loading baseline schema"
psql -U "$PG_SUPERUSER" -d clinlims -q -v ON_ERROR_STOP=1 -f /docker-entrypoint-initdb.d/OpenELIS-Global.sql
echo "db-init: site code $OE_SITE_CODE"
sed "s/'DEV01'/'$OE_SITE_CODE'/g" /docker-entrypoint-initdb.d/siteInfo.sql | psql -U "$PG_SUPERUSER" -d clinlims -q -v ON_ERROR_STOP=1

export PGPASSWORD="$OE_DB_PASSWORD"
n=$(psql -U clinlims -d clinlims -tAc "select count(*) from information_schema.tables where table_schema='clinlims'")
echo "db-init: done - $n tables in clinlims"
