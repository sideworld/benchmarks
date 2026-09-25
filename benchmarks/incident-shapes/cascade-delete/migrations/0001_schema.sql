-- PAR-76's world: an account root and 24 tables that hang off it, every foreign key
-- ON DELETE CASCADE and every foreign-key column indexed (without the index, each cascaded row
-- would scan its child table). Seven levels at the deepest:
--   accounts > workspaces > apps > functions > function_runs > run_steps > step_outputs
-- Several tables are reachable by more than one path (function_runs from functions and straight
-- from accounts), as in a schema that denormalises account_id for its hot queries.
-- Applied by init-app.sh on first boot. A pull request's migration in this directory
-- (0002_*.sql) is what the Migration Check replays; the changes it rehearses are in ../changes/.

CREATE TABLE accounts (
    id          bigint PRIMARY KEY,
    name        text NOT NULL,
    plan        text NOT NULL,
    fn_lo       bigint NOT NULL,          -- this account's functions are ids fn_lo .. fn_lo + fn_n - 1
    fn_n        int NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE account_members (
    id          bigserial PRIMARY KEY,
    account_id  bigint NOT NULL REFERENCES accounts ON DELETE CASCADE,
    email       text NOT NULL,
    role        text NOT NULL
);
CREATE INDEX ON account_members (account_id);

CREATE TABLE api_keys (
    id          bigserial PRIMARY KEY,
    account_id  bigint NOT NULL REFERENCES accounts ON DELETE CASCADE,
    prefix      text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON api_keys (account_id);

CREATE TABLE audit_log (
    id          bigserial PRIMARY KEY,
    account_id  bigint NOT NULL REFERENCES accounts ON DELETE CASCADE,
    action      text NOT NULL,
    at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON audit_log (account_id);

-- one hot row per account: every run and every event bumps it
CREATE TABLE usage_counters (
    account_id  bigint PRIMARY KEY REFERENCES accounts ON DELETE CASCADE,
    runs        bigint NOT NULL DEFAULT 0,
    events      bigint NOT NULL DEFAULT 0,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE billing_subscriptions (
    id          bigserial PRIMARY KEY,
    account_id  bigint NOT NULL REFERENCES accounts ON DELETE CASCADE,
    plan        text NOT NULL,
    started_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON billing_subscriptions (account_id);

CREATE TABLE invoices (
    id              bigserial PRIMARY KEY,
    subscription_id bigint NOT NULL REFERENCES billing_subscriptions ON DELETE CASCADE,
    account_id      bigint NOT NULL REFERENCES accounts ON DELETE CASCADE,
    period          date NOT NULL,
    total_cents     bigint NOT NULL
);
CREATE INDEX ON invoices (subscription_id);
CREATE INDEX ON invoices (account_id, period);

CREATE TABLE invoice_lines (
    id          bigserial PRIMARY KEY,
    invoice_id  bigint NOT NULL REFERENCES invoices ON DELETE CASCADE,
    item        text NOT NULL,
    cents       bigint NOT NULL
);
CREATE INDEX ON invoice_lines (invoice_id);

CREATE TABLE workspaces (
    id          bigint PRIMARY KEY,       -- 2a-1 production, 2a staging, for account a
    account_id  bigint NOT NULL REFERENCES accounts ON DELETE CASCADE,
    name        text NOT NULL
);
CREATE INDEX ON workspaces (account_id);

CREATE TABLE env_vars (
    id           bigserial PRIMARY KEY,
    workspace_id bigint NOT NULL REFERENCES workspaces ON DELETE CASCADE,
    key          text NOT NULL,
    value        text NOT NULL
);
CREATE INDEX ON env_vars (workspace_id);

CREATE TABLE event_keys (
    id           bigserial PRIMARY KEY,
    workspace_id bigint NOT NULL REFERENCES workspaces ON DELETE CASCADE,
    key          text NOT NULL
);
CREATE INDEX ON event_keys (workspace_id);

CREATE TABLE webhooks (
    id           bigserial PRIMARY KEY,
    workspace_id bigint NOT NULL REFERENCES workspaces ON DELETE CASCADE,
    url          text NOT NULL
);
CREATE INDEX ON webhooks (workspace_id);

CREATE TABLE webhook_deliveries (
    id          bigserial PRIMARY KEY,
    webhook_id  bigint NOT NULL REFERENCES webhooks ON DELETE CASCADE,
    status      int NOT NULL,
    at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON webhook_deliveries (webhook_id);

CREATE TABLE apps (
    id           bigint PRIMARY KEY,
    workspace_id bigint NOT NULL REFERENCES workspaces ON DELETE CASCADE,
    account_id   bigint NOT NULL REFERENCES accounts ON DELETE CASCADE,
    name         text NOT NULL
);
CREATE INDEX ON apps (workspace_id);
CREATE INDEX ON apps (account_id);

CREATE TABLE deploys (
    id          bigserial PRIMARY KEY,
    app_id      bigint NOT NULL REFERENCES apps ON DELETE CASCADE,
    version     int NOT NULL,
    at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON deploys (app_id);

CREATE TABLE functions (
    id          bigint PRIMARY KEY,
    app_id      bigint NOT NULL REFERENCES apps ON DELETE CASCADE,
    account_id  bigint NOT NULL REFERENCES accounts ON DELETE CASCADE,
    slug        text NOT NULL
);
CREATE INDEX ON functions (app_id);
CREATE INDEX ON functions (account_id);

CREATE TABLE function_versions (
    id          bigserial PRIMARY KEY,
    function_id bigint NOT NULL REFERENCES functions ON DELETE CASCADE,
    version     int NOT NULL,
    config      text NOT NULL
);
CREATE INDEX ON function_versions (function_id);

CREATE TABLE cron_schedules (
    id          bigserial PRIMARY KEY,
    function_id bigint NOT NULL REFERENCES functions ON DELETE CASCADE,
    cron        text NOT NULL
);
CREATE INDEX ON cron_schedules (function_id);

CREATE TABLE events (
    id           bigserial PRIMARY KEY,
    workspace_id bigint NOT NULL REFERENCES workspaces ON DELETE CASCADE,
    account_id   bigint NOT NULL REFERENCES accounts ON DELETE CASCADE,
    name         text NOT NULL,
    received_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON events (workspace_id);
CREATE INDEX ON events (account_id, received_at);

CREATE TABLE event_payloads (
    event_id    bigint PRIMARY KEY REFERENCES events ON DELETE CASCADE,
    body        text NOT NULL
);

CREATE TABLE function_runs (
    id          bigserial PRIMARY KEY,
    function_id bigint NOT NULL REFERENCES functions ON DELETE CASCADE,
    account_id  bigint NOT NULL REFERENCES accounts ON DELETE CASCADE,
    event_id    bigint REFERENCES events ON DELETE CASCADE,
    status      text NOT NULL,
    started_at  timestamptz NOT NULL DEFAULT now(),
    ended_at    timestamptz
);
CREATE INDEX ON function_runs (function_id);
CREATE INDEX ON function_runs (account_id, started_at);
CREATE INDEX ON function_runs (event_id);

CREATE TABLE run_steps (
    id          bigserial PRIMARY KEY,
    run_id      bigint NOT NULL REFERENCES function_runs ON DELETE CASCADE,
    name        text NOT NULL,
    status      text NOT NULL,
    at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON run_steps (run_id);

CREATE TABLE step_outputs (
    step_id     bigint PRIMARY KEY REFERENCES run_steps ON DELETE CASCADE,
    output      text NOT NULL
);

CREATE TABLE run_events (
    id          bigserial PRIMARY KEY,
    run_id      bigint NOT NULL REFERENCES function_runs ON DELETE CASCADE,
    kind        text NOT NULL,
    at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON run_events (run_id);

CREATE TABLE run_logs (
    id          bigserial PRIMARY KEY,
    run_id      bigint NOT NULL REFERENCES function_runs ON DELETE CASCADE,
    line        text NOT NULL,
    at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON run_logs (run_id);
