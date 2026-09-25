-- PAR-76's history: :accounts accounts whose size falls off as a power law, so a few are huge and
-- most are tiny. At :scale 1 and 20,000 accounts:
--   runs(a) = max(5, floor(600000 * scale / a^1.3))   account 1: 600,000 runs; 2: 243,675;
--   3: 143,844; 10: 30,071; 100: 1,507; 1,000: 75; from about 2,400 on, 5 each. 2.28M runs,
--   ~26M rows in all, about 6.4M of them account 1's (every table it reaches by cascade).
-- Every other table follows from runs: 3 steps, 2 run events, 1 log line and 1 triggering event
-- (with its payload) per run, an output for half the steps; per account 1 + runs/20000 apps (at
-- most 20), 5 functions each, 12 monthly invoices of 3 lines, members, keys, audit entries and
-- webhook deliveries in proportion. Deterministic: no random(), so every world of the same size
-- is the same world. Ids are laid out per account in contiguous ranges (the plan below), which
-- is also how the workers find an account's functions (accounts.fn_lo / fn_n).
-- Run by gen.sh between benchmarks/lib's bulk-load begin and end files.

CREATE TEMP TABLE plan AS
SELECT a AS account_id,
       greatest(5, floor(:scale * 600000 / power(a, 1.3)))::bigint AS runs
  FROM generate_series(1, :accounts) a;
ALTER TABLE plan ADD COLUMN n_apps int;
UPDATE plan SET n_apps = least(20, 1 + runs / 20000);
CREATE TEMP TABLE p AS
SELECT account_id, runs, n_apps, 5 * n_apps AS n_fn,
       sum(runs) OVER w - runs + 1         AS run_lo,
       sum(n_apps) OVER w - n_apps + 1     AS app_lo,
       sum(5 * n_apps) OVER w - 5 * n_apps + 1 AS fn_lo
  FROM plan WINDOW w AS (ORDER BY account_id);
ANALYZE p;
\echo plan: accounts, runs
SELECT count(*) AS accounts, sum(runs) AS runs, max(runs) AS largest FROM p;

INSERT INTO accounts (id, name, plan, fn_lo, fn_n, created_at)
SELECT account_id, 'account-' || account_id,
       CASE WHEN runs >= 100000 THEN 'enterprise' WHEN runs >= 1000 THEN 'pro' ELSE 'free' END,
       fn_lo, n_fn, timestamptz '2024-01-01' + (account_id % 600) * interval '1 day'
  FROM p;
INSERT INTO usage_counters (account_id, runs, events) SELECT account_id, runs, runs FROM p;
INSERT INTO account_members (account_id, email, role)
SELECT account_id, 'user' || g || '@account-' || account_id || '.test', CASE WHEN g = 1 THEN 'owner' ELSE 'member' END
  FROM p, generate_series(1, least(50, 1 + runs / 5000)) g;
INSERT INTO api_keys (account_id, prefix) SELECT account_id, 'key_' || account_id || '_' || g FROM p, generate_series(1, 2) g;
INSERT INTO audit_log (account_id, action, at)
SELECT account_id, (ARRAY['login','deploy','key.create','member.invite'])[1 + g % 4], timestamptz '2026-06-01' + g * interval '1 hour'
  FROM p, generate_series(1, 10 + runs / 1000) g;

INSERT INTO billing_subscriptions (account_id, plan) SELECT account_id, 'monthly' FROM p;
INSERT INTO invoices (subscription_id, account_id, period, total_cents)
SELECT s.id, s.account_id, date '2025-10-01' + (g * interval '1 month'), 1000 + (s.account_id * 7 + g) % 90000
  FROM billing_subscriptions s, generate_series(0, 11) g;
INSERT INTO invoice_lines (invoice_id, item, cents)
SELECT i.id, (ARRAY['runs','steps','seats'])[g], i.total_cents / 3 FROM invoices i, generate_series(1, 3) g;

INSERT INTO workspaces (id, account_id, name)
SELECT 2 * account_id - 2 + g, account_id, (ARRAY['production','staging'])[g] FROM p, generate_series(1, 2) g;
INSERT INTO env_vars (workspace_id, key, value) SELECT w.id, 'VAR_' || g, 'value-' || g FROM workspaces w, generate_series(1, 5) g;
INSERT INTO event_keys (workspace_id, key) SELECT w.id, 'ek_' || w.id || '_' || g FROM workspaces w, generate_series(1, 2) g;
INSERT INTO webhooks (workspace_id, url) SELECT 2 * account_id - 1, 'https://hooks.account-' || account_id || '.test/in' FROM p;
INSERT INTO webhook_deliveries (webhook_id, status, at)
SELECT h.id, CASE WHEN g % 50 = 0 THEN 500 ELSE 200 END, timestamptz '2026-06-01' + g * interval '1 minute'
  FROM webhooks h JOIN workspaces w ON w.id = h.workspace_id JOIN p ON p.account_id = w.account_id, generate_series(1, p.runs / 10) g;

INSERT INTO apps (id, workspace_id, account_id, name)
SELECT app_lo + g, 2 * account_id - 1, account_id, 'app-' || g FROM p, generate_series(0, n_apps - 1) g;
INSERT INTO deploys (app_id, version, at) SELECT a.id, g, timestamptz '2026-01-01' + g * interval '30 days' FROM apps a, generate_series(1, 3) g;
INSERT INTO functions (id, app_id, account_id, slug)
SELECT fn_lo + g, app_lo + g / 5, account_id, 'fn-' || g FROM p, generate_series(0, n_fn - 1) g;
INSERT INTO function_versions (function_id, version, config) SELECT f.id, g, '{"retries":3}' FROM functions f, generate_series(1, 2) g;
INSERT INTO cron_schedules (function_id, cron) SELECT id, '*/5 * * * *' FROM functions WHERE id % 5 = 0;

-- one triggering event per run; the event's id is the run's id
INSERT INTO events (id, workspace_id, account_id, name, received_at)
SELECT r, 2 * account_id - 1, account_id, 'app/event.' || (r % 12),
       timestamptz '2026-09-24' - ((r * 2654435761) % 7776000) * interval '1 second'
  FROM p, generate_series(run_lo, run_lo + runs - 1) r;
INSERT INTO event_payloads (event_id, body) SELECT id, '{"n":' || id || ',"data":"' || md5(id::text) || '"}' FROM events;
INSERT INTO function_runs (id, function_id, account_id, event_id, status, started_at, ended_at)
SELECT e.id, a.fn_lo + e.id % a.fn_n, e.account_id, e.id,
       CASE WHEN e.id % 20 = 0 THEN 'failed' ELSE 'completed' END, e.received_at, e.received_at + interval '2 seconds'
  FROM events e JOIN accounts a ON a.id = e.account_id;
INSERT INTO run_steps (id, run_id, name, status, at)
SELECT 3 * (r.id - 1) + g, r.id, 'step-' || g, r.status, r.started_at + g * interval '500 milliseconds'
  FROM function_runs r, generate_series(1, 3) g;
INSERT INTO step_outputs (step_id, output) SELECT id, '{"ok":true,"step":' || id || '}' FROM run_steps WHERE id % 2 = 0;
INSERT INTO run_events (run_id, kind, at)
SELECT r.id, (ARRAY['started','finished'])[g], r.started_at + (g - 1) * interval '2 seconds' FROM function_runs r, generate_series(1, 2) g;
INSERT INTO run_logs (run_id, line, at) SELECT id, 'run ' || id || ' ' || status, started_at FROM function_runs;

-- the explicit ids above leave their sequences behind
SELECT setval(pg_get_serial_sequence('events', 'id'), (SELECT max(id) + 1 FROM events), false);
SELECT setval(pg_get_serial_sequence('function_runs', 'id'), (SELECT max(id) + 1 FROM function_runs), false);
SELECT setval(pg_get_serial_sequence('run_steps', 'id'), (SELECT max(id) + 1 FROM run_steps), false);
