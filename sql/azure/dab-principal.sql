\set ON_ERROR_STOP on

-- Creates the PostgreSQL role for DAB's user-assigned managed identity.
-- Run against the postgres database as the Entra administrator:
--   psql -v dab_principal=<identity name> -v dab_object_id=<principal id> -f sql/azure/dab-principal.sql
SELECT NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'dab_principal') AS create_principal \gset
\if :create_principal
    SELECT * FROM pgaadauth_create_principal_with_oid(
        :'dab_principal', :'dab_object_id', 'service', false, false
    );
\endif
