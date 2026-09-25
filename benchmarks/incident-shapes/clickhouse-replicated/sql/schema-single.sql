-- PAR-73's events table, created on the single node, as plain MergeTree.
-- Two data-skipping indexes: idx_name, which queries use, and idx_payload, the "unused" one the
-- migration drops. batch_id is the writer's: 0 for generated history, the batch number for rows
-- the rehearsal's writers insert, which is how the round trip finds writes that never landed.
CREATE TABLE IF NOT EXISTS events
(
    org_id      UInt32,
    event_id    UInt64,
    ts          DateTime64(3),
    name        LowCardinality(String),
    environment LowCardinality(String),
    payload     String,
    batch_id    UInt64,
    INDEX idx_name name TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_payload payload TYPE tokenbf_v1(8192, 3, 0) GRANULARITY 4
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (org_id, ts, event_id)
