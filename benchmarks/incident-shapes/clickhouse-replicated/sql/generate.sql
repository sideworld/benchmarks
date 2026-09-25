-- One chunk of history: rows {offset} .. {offset}+{rows}-1. Deterministic (hashes of the row
-- number, not rand()), so every run of the same size has the same table. The skew, from PAR-73's
-- "realistic volume and skew":
--   org_id       20,000 orgs, heavy-headed: u^4 puts about a third of all events in the top 1% of
--                orgs (org_id < 200) and half in the top 6%
--   name         40 event names, the same shape: a handful of names carry most rows
--   environment  production 80%, staging 15%, development 5%
--   ts           the last 90 days, weighted toward recent (u^2 of the age)
--   payload      16 to 320 bytes of hex, ~170 on average
INSERT INTO events (org_id, event_id, ts, name, environment, payload, batch_id)
SELECT
    toUInt32(floor(pow(cityHash64(number, 1) / 18446744073709551615.0, 4) * 20000)) AS org_id,
    number AS event_id,
    toDateTime64('{now}', 3) - toIntervalMillisecond(toUInt64(pow(cityHash64(number, 2) / 18446744073709551615.0, 2) * 7776000000)) AS ts,
    concat('event.', toString(toUInt8(floor(pow(cityHash64(number, 3) / 18446744073709551615.0, 3) * 40)))) AS name,
    multiIf(cityHash64(number, 4) % 100 < 80, 'production', cityHash64(number, 4) % 100 < 95, 'staging', 'development') AS environment,
    repeat(hex(cityHash64(number, 5)), toUInt32(1 + cityHash64(number, 6) % 20)) AS payload,
    0 AS batch_id
FROM numbers({offset}, {rows})
