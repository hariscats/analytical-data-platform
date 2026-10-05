\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- Gives the API login its only access path and session guardrails.
-- Usage: psql -v api_login=<role name> -f sql/40-api-login.sql
-- On Azure the login is DAB's managed identity (see sql/azure/dab-principal.sql).
GRANT api_reader TO :"api_login";

ALTER ROLE :"api_login" CONNECTION LIMIT 10;
ALTER ROLE :"api_login" SET default_transaction_read_only = on;
ALTER ROLE :"api_login" SET statement_timeout = '5s';
ALTER ROLE :"api_login" SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE :"api_login" SET search_path = pg_catalog;
