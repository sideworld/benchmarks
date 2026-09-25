-- PAR-76, the change that should be fine: hard-delete one of the many small accounts (15000: 5
-- runs, ~150 rows across the tables it reaches) in one statement, every row under it removed by
-- ON DELETE CASCADE. The rehearsal opens this as a pull request (migrations/0002_*.sql).
-- paraglobe: expect-row-loss accounts, account_members, api_keys, audit_log, usage_counters, billing_subscriptions, invoices, invoice_lines, workspaces, env_vars, event_keys, webhooks, webhook_deliveries, apps, deploys, functions, function_versions, cron_schedules, events, event_payloads, function_runs, run_steps, step_outputs, run_events, run_logs
DELETE FROM accounts WHERE id = 15000;
