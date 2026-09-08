-- Run by db-prep/init.sh as the Postgres superuser, only when database 'clinlims' does not exist.
-- :'pw' is passed in by psql -v pw=... from OE_DB_PASSWORD in .env.
-- Same as what the stock DB image's init.sh does, minus the unused 'admin' superuser;
-- the two extensions are pre-created so Liquibase never needs superuser later.
CREATE USER clinlims PASSWORD :'pw';
CREATE DATABASE clinlims OWNER clinlims ENCODING 'UTF8';
\c clinlims
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS unaccent;
