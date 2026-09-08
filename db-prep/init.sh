#!/bin/sh
# Entry point of the db-init service. Runs inside itechuw/openelis-global-2-database:<tag>,
# which ships /docker-entrypoint-initdb.d/OpenELIS-Global.sql and siteInfo.sql for that tag.
set -eu
export PGHOST=db.openelis.org PGPORT="${OE_DB_PORT:-5432}"

echo "db-init: waiting for Postgres at $PGHOST:$PGPORT"
i=0; until pg_isready -q -U "$PG_SUPERUSER"; do i=$((i+1)); [ $i -ge 60 ] && { echo "db-init: Postgres not reachable after 120s"; exit 1; }; sleep 2; done

export PGPASSWORD="$PG_SUPERUSER_PASSWORD"
if [ "$(psql -U "$PG_SUPERUSER" -d postgres -tAc "select 1 from pg_database where datname='clinlims'")" = "1" ]; then
  echo "db-init: database clinlims exists - nothing to do"; exit 0
fi

echo "db-init: creating role + database + extensions"
psql -U "$PG_SUPERUSER" -d postgres -v ON_ERROR_STOP=1 -v pw="$OE_DB_PASSWORD" -f /db-prep/roles.sql

export PGPASSWORD="$OE_DB_PASSWORD"
echo "db-init: loading baseline schema"
psql -U clinlims -d clinlims -q -v ON_ERROR_STOP=1 -f /docker-entrypoint-initdb.d/OpenELIS-Global.sql
echo "db-init: site code $OE_SITE_CODE"
sed "s/'DEV01'/'$OE_SITE_CODE'/g" /docker-entrypoint-initdb.d/siteInfo.sql | psql -U clinlims -d clinlims -q -v ON_ERROR_STOP=1

n=$(psql -U clinlims -d clinlims -tAc "select count(*) from information_schema.tables where table_schema='clinlims'")
echo "db-init: done - $n tables in clinlims"
