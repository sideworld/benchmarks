-- PostHog at scale, at the data plane: {n_events} events into ClickHouse, generated server-side.
--
-- Shape: Zipf(1.0) over {n_teams} projects (rank 1 = the hot project), ~8 hot event names carrying
-- ~80% and a 200-name tail, properties as JSON with a stable head plus a long tail of keys
-- (x_<40000 keys>, y_<20000 keys>), ~12 events per $session_id, timestamps skewed towards now
-- over {days} days. person_mode='full' with person_properties on the row (person-on-events), and
-- person_id / distinct_id are pure functions of (team, person number), so gen-persons.sql writes
-- Postgres and ClickHouse person rows that agree with these events without any join.
--
-- Goes straight into the shard table; the Distributed table `events` reads it.
INSERT INTO sharded_events
    (uuid, event, properties, timestamp, team_id, distinct_id, elements_chain, created_at,
     person_id, person_created_at, person_properties, person_mode, historical_migration,
     _timestamp, _offset)
SELECT
    generateUUIDv4()                                                                              AS uuid,
    multiIf(r_ev < 0.42, '$pageview', r_ev < 0.62, '$autocapture', r_ev < 0.70, '$pageleave',
            r_ev < 0.76, 'signup', r_ev < 0.80, 'purchase', r_ev < 0.82, '$identify',
            r_ev < 0.86, 'checkout started', r_ev < 0.88, 'feature used',
            concat('custom_', toString(1 + cityHash64(n, 7) % 200)))                              AS event,
    concat('{"$current_url":"https://app.example.test/', ['home','pricing','docs','login','dash','settings','billing','search'][1 + cityHash64(n, 11) % 8],
           '","$browser":"', ['Chrome','Safari','Firefox','Edge'][1 + cityHash64(n, 13) % 4],
           '","$os":"', ['Mac OS X','Windows','Linux','iOS','Android'][1 + cityHash64(n, 17) % 5],
           '","$device_type":"', if(cityHash64(n, 19) % 3 = 0, 'Mobile', 'Desktop'),
           '","plan":"', ['free','pro','team','enterprise'][1 + intDiv(cityHash64(n, 23) % 100, 25)],
           '","utm_source":"', ['google','twitter','newsletter','direct','partner','ads'][1 + cityHash64(n, 29) % 6],
           '","$session_id":"', toString(reinterpretAsUUID(concat(toString(cityHash64(intDiv(n, 12), 37)), toString(cityHash64(intDiv(n, 12), 38))))),
           '","$window_id":"', toString(reinterpretAsUUID(concat(toString(cityHash64(intDiv(n, 12), 41)), toString(cityHash64(intDiv(n, 12), 42))))),
           '","x_', toString(cityHash64(n, 43) % 40000), '":', toString(cityHash64(n, 47) % 1000),
           if(cityHash64(n, 53) % 4 = 0, concat(',"y_', toString(cityHash64(n, 59) % 20000), '":"v', toString(cityHash64(n, 61) % 100), '"'), ''),
           '}')                                                                                   AS properties,
    ts                                                                                            AS timestamp,
    team_id                                                                                       AS team_id,
    concat('u', toString(team_id), '-', toString(pn))                                             AS distinct_id,
    ''                                                                                            AS elements_chain,
    ts                                                                                            AS created_at,
    reinterpretAsUUID(concat(toString(cityHash64('person', team_id, pn)), toString(cityHash64('person2', team_id, pn)))) AS person_id,
    toDateTime({t_end:UInt32}, 'UTC') - toIntervalDay({days:UInt32} + 1)                              AS person_created_at,
    concat('{"email":"u', toString(team_id), '-', toString(pn), '@example.test","plan":"',
           ['free','pro','team','enterprise'][1 + intDiv(cityHash64('pp', team_id, pn) % 100, 25)],
           '","country":"', ['US','GB','DE','FR','IN','BR','JP','CA'][1 + cityHash64('pc', team_id, pn) % 8], '"}') AS person_properties,
    'full'                                                                                        AS person_mode,
    0                                                                                             AS historical_migration,
    now()                                                                                         AS _timestamp,
    n                                                                                             AS _offset
FROM
(
    SELECT
        number                                                                                    AS n,
        cityHash64(number, 3) / 18446744073709551615.0                                            AS r_ev,
        -- Zipf over projects: the smallest rank whose cumulative weight exceeds a uniform draw
        -- the actual project ids, in Zipf rank order (rank 1 = the hot project); ids need not be contiguous
        arrayElement({teams:Array(Int64)}, arrayFirstIndex(x -> x >= (cityHash64(number, 5) / 18446744073709551615.0) * zsum, zipf)) AS team_id,
        -- persons per project follow the same skew: hot persons exist
        toUInt64(floor(pow(cityHash64(number, 71) / 18446744073709551615.0, 1.5) * {n_persons:UInt64})) AS pn,
        toDateTime64(toDateTime({t_end:UInt32}, 'UTC'), 6, 'UTC')
          - toIntervalSecond(toUInt32(({days:UInt32} * 86400) * pow(cityHash64(number, 79) / 18446744073709551615.0, 0.6))) AS ts
    FROM numbers({start:UInt64}, {n_events:UInt64}) AS nums
    CROSS JOIN
    (
        SELECT arrayCumSum(arrayMap(i -> 1.0 / i, range(1, {n_teams:UInt32} + 1))) AS zipf,
               arraySum(arrayMap(i -> 1.0 / i, range(1, {n_teams:UInt32} + 1)))    AS zsum
    ) AS z
) AS gen
SETTINGS max_insert_threads = 8, max_threads = 8, max_execution_time = 0
