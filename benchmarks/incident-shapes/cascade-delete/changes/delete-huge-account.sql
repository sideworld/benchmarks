-- PAR-76, the incident's change: hard-delete the largest account (1: at the box's scale 2, 1.2M
-- runs and ~12.7M rows across 24 tables) in one statement. The cascade runs inside it, so every
-- row lock it takes -- the account row first -- is held until the whole cascade is done, while
-- the executor keeps sending that account work. The rehearsal opens this as a pull request.
-- paraglobe: expect-row-loss accounts, account_members, api_keys, audit_log, usage_counters, billing_subscriptions, invoices, invoice_lines, workspaces, env_vars, event_keys, webhooks, webhook_deliveries, apps, deploys, functions, function_versions, cron_schedules, events, event_payloads, function_runs, run_steps, step_outputs, run_events, run_logs
DELETE FROM accounts WHERE id = 1;
