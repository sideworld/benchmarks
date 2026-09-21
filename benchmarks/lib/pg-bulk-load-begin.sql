-- Bulk-load profile, Postgres, start of session (see BULK-LOAD.md). Session-scoped: nothing here
-- survives the generator's connection.
\set ON_ERROR_STOP on
SET synchronous_commit = off;          -- the snapshot afterwards is what must be durable
SET work_mem = '512MB';
SET session_replication_role = replica; -- no RI after-triggers: 1 event/row/FK, run at statement end
