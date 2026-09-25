# Incident shapes

Rehearsals of the *shape* of published incidents: a scratch world just large and skewed enough to
show the mechanism, the change that caused the trouble, the old and new versions of whatever was
writing, and the safe form measured beside it. Each one is built to run on the box unattended, and
its tests run against fakes, so the box only has to run it.

A rehearsal claims its shape and nothing more. Each README says what it reproduces, what was
induced to reproduce it, and what it does not claim about the company whose write-up it follows.

| rehearsal | shape | issue |
|---|---|---|
| [`clickhouse-replicated/`](clickhouse-replicated/) | replicated ClickHouse: an index-drop mutation, then an added column, then a new writer; the runner says done while a replica lags and the writer's batches are dropped. A one-off rig that runs the Check's phases itself (the Check speaks only Postgres; PAR-79) | PAR-73 |
| [`cascade-delete/`](cascade-delete/) ([write-up](cascade-delete.md)) | Postgres behind PgBouncer: an account hard-deleted through a 25-table `ON DELETE CASCADE` graph while a retrying executor keeps writing to it; its jobs pile up behind the locks, take every pooled connection, and four unrelated services queue behind them. An onboarded paraglobe world: each change is a pull request judged by the real Migration Check | PAR-76 |
