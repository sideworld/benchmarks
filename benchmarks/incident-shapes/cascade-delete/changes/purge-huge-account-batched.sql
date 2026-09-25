-- cascade:no-transaction
-- PAR-76's safe form for the same account: purge it leaf-first in batches, each batch its own
-- transaction, each statement under lock_timeout 2 s and retried (0.5 s longer each time, at most
-- 30 tries) when it cannot get a lock, then delete the account row last, which cascades only
-- the rows written since their table was purged. No lock is held for longer than a batch.
-- The executor keeps writing runs for the account throughout (nothing marks it disabled first,
-- which a real purge would also do); the run loop chases those until it catches up.
-- paraglobe: expect-row-loss accounts, account_members, api_keys, audit_log, usage_counters, billing_subscriptions, invoices, invoice_lines, workspaces, env_vars, event_keys, webhooks, webhook_deliveries, apps, deploys, functions, function_versions, cron_schedules, events, event_payloads, function_runs, run_steps, step_outputs, run_events, run_logs

CREATE FUNCTION purge_try(q text, p_account bigint, ids bigint[]) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint; tries int := 0;
BEGIN
  LOOP
    BEGIN
      PERFORM set_config('lock_timeout', '2s', true);
      EXECUTE q USING p_account, ids;
      GET DIAGNOSTICS n = ROW_COUNT;
      RETURN n;
    EXCEPTION WHEN lock_not_available THEN
      tries := tries + 1;
      RAISE NOTICE 'lock_timeout, try %: %', tries, left(q, 70);
      IF tries >= 30 THEN RAISE; END IF;
      PERFORM pg_sleep(0.5 * tries);
    END;
  END LOOP;
END $$;

CREATE PROCEDURE purge_account(p_account bigint, p_batch int) LANGUAGE plpgsql AS $$
DECLARE ids bigint[]; q text; total bigint := 0; batches int := 0;
BEGIN
  -- 1. runs, and everything under them, a batch of runs at a time
  LOOP
    SELECT array_agg(id) INTO ids FROM (SELECT id FROM function_runs WHERE account_id = p_account ORDER BY id LIMIT p_batch) s;
    EXIT WHEN ids IS NULL;
    total := total + purge_try('DELETE FROM step_outputs WHERE step_id IN (SELECT id FROM run_steps WHERE run_id = ANY($2))', p_account, ids);
    total := total + purge_try('DELETE FROM run_steps WHERE run_id = ANY($2)', p_account, ids);
    total := total + purge_try('DELETE FROM run_events WHERE run_id = ANY($2)', p_account, ids);
    total := total + purge_try('DELETE FROM run_logs WHERE run_id = ANY($2)', p_account, ids);
    total := total + purge_try('DELETE FROM function_runs WHERE id = ANY($2)', p_account, ids);
    batches := batches + 1;
    COMMIT;
  END LOOP;
  -- 2. events and their payloads
  LOOP
    SELECT array_agg(id) INTO ids FROM (SELECT id FROM events WHERE account_id = p_account ORDER BY id LIMIT p_batch) s;
    EXIT WHEN ids IS NULL;
    total := total + purge_try('DELETE FROM event_payloads WHERE event_id = ANY($2)', p_account, ids);
    total := total + purge_try('DELETE FROM function_runs WHERE event_id = ANY($2)', p_account, ids);
    total := total + purge_try('DELETE FROM events WHERE id = ANY($2)', p_account, ids);
    batches := batches + 1;
    COMMIT;
  END LOOP;
  -- 3. webhook deliveries
  LOOP
    -- comma joins, not JOIN: the Migration Check's table detection reads a join condition on
    -- an alias's id column as a table named id, and its lock sampler would watch that
    SELECT array_agg(d.id) INTO ids FROM (SELECT d.id FROM webhook_deliveries d, webhooks h, workspaces w
      WHERE h.id = d.webhook_id AND w.id = h.workspace_id AND w.account_id = p_account ORDER BY d.id LIMIT p_batch) d;
    EXIT WHEN ids IS NULL;
    total := total + purge_try('DELETE FROM webhook_deliveries WHERE id = ANY($2)', p_account, ids);
    batches := batches + 1;
    COMMIT;
  END LOOP;
  -- 4. invoices and their lines
  LOOP
    SELECT array_agg(id) INTO ids FROM (SELECT id FROM invoices WHERE account_id = p_account ORDER BY id LIMIT p_batch) s;
    EXIT WHEN ids IS NULL;
    total := total + purge_try('DELETE FROM invoice_lines WHERE invoice_id = ANY($2)', p_account, ids);
    total := total + purge_try('DELETE FROM invoices WHERE id = ANY($2)', p_account, ids);
    batches := batches + 1;
    COMMIT;
  END LOOP;
  -- 5. the small tables, one transaction each, children before parents
  FOREACH q IN ARRAY ARRAY[
      'DELETE FROM function_versions WHERE function_id IN (SELECT id FROM functions WHERE account_id = $1)',
      'DELETE FROM cron_schedules WHERE function_id IN (SELECT id FROM functions WHERE account_id = $1)',
      'DELETE FROM functions WHERE account_id = $1',
      'DELETE FROM deploys WHERE app_id IN (SELECT id FROM apps WHERE account_id = $1)',
      'DELETE FROM apps WHERE account_id = $1',
      'DELETE FROM env_vars WHERE workspace_id IN (SELECT id FROM workspaces WHERE account_id = $1)',
      'DELETE FROM event_keys WHERE workspace_id IN (SELECT id FROM workspaces WHERE account_id = $1)',
      'DELETE FROM webhooks WHERE workspace_id IN (SELECT id FROM workspaces WHERE account_id = $1)',
      'DELETE FROM workspaces WHERE account_id = $1',
      'DELETE FROM billing_subscriptions WHERE account_id = $1',
      'DELETE FROM account_members WHERE account_id = $1',
      'DELETE FROM api_keys WHERE account_id = $1',
      'DELETE FROM audit_log WHERE account_id = $1'] LOOP
    total := total + purge_try(q, p_account, NULL);
    COMMIT;
  END LOOP;
  -- 6. the account itself: its cascade now reaches only what was written since its table was purged
  total := total + purge_try('DELETE FROM accounts WHERE id = $1', p_account, NULL);
  COMMIT;
  RAISE NOTICE 'purged account %: % rows directly, % batches of up to %', p_account, total, batches, p_batch;
END $$;

CALL purge_account(1, 2000);
DROP PROCEDURE purge_account(bigint, int);
DROP FUNCTION purge_try(text, bigint, bigint[]);
