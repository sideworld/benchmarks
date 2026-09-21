-- Bulk-load profile, Postgres, end of session: re-enable triggers and prove referential integrity
-- held for every FK on the loaded tables (psql var load_tables='t1,t2,...'). One anti-join per FK
-- pair; orphans must be 0. Composite FKs are reported, not checked.
SET session_replication_role = DEFAULT;
SET bulk.load_tables = :'load_tables';
\echo === RI validation (orphans per FK pair; must be 0)
DO $$
DECLARE r record; n bigint; bad int := 0; t0 timestamptz;
BEGIN
  FOR r IN
    SELECT c.conname, c.conrelid::regclass AS child, c.confrelid::regclass AS parent,
           (SELECT attname FROM pg_attribute WHERE attrelid = c.conrelid  AND attnum = c.conkey[1])  AS ccol,
           (SELECT attname FROM pg_attribute WHERE attrelid = c.confrelid AND attnum = c.confkey[1]) AS pcol,
           array_length(c.conkey, 1) AS ncols
    FROM pg_constraint c
    WHERE c.contype = 'f'
      AND c.conrelid = ANY (SELECT to_regclass(trim(x)) FROM unnest(string_to_array(current_setting('bulk.load_tables'), ',')) x)
    ORDER BY 2, 1
  LOOP
    IF r.ncols > 1 THEN RAISE NOTICE 'RI %: composite key, not checked', r.conname; CONTINUE; END IF;
    t0 := clock_timestamp();
    EXECUTE format('SELECT count(*) FROM %s c WHERE c.%I IS NOT NULL AND NOT EXISTS (SELECT 1 FROM %s p WHERE p.%I = c.%I)',
                   r.child, r.ccol, r.parent, r.pcol, r.ccol) INTO n;
    RAISE NOTICE 'RI % (%.% -> %.%): orphans % [% s]', r.conname, r.child, r.ccol, r.parent, r.pcol, n,
                 round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1);
    IF n > 0 THEN bad := bad + 1; END IF;
  END LOOP;
  IF bad > 0 THEN RAISE EXCEPTION 'referential integrity violated on % FK pair(s)', bad; END IF;
END $$;
