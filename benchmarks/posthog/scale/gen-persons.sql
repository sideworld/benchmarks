-- Persons and distinct ids in POSTGRES, consistent with gen-events.sql: same person uuid, same
-- distinct_id, same properties, derived from (team_id, person number) with the same hashes.
-- ClickHouse has cityHash64; Postgres does not, so the hash is computed HERE and the ClickHouse
-- side is filled from this table by gen.sh (COPY out -> INSERT), never recomputed. That is the
-- one place the two stores are tied together, and it is a copy, not a second implementation.
\set ON_ERROR_STOP on
\timing on
BEGIN;
-- (team_id, pn) -> uuid: two 64-bit halves; ids and properties are what gen-events.sql emits
-- for the same (team_id, pn), so a persons page and a trends breakdown agree.
CREATE TEMP TABLE gen_p AS
SELECT t.team_id, g.pn,
       ('u' || t.team_id || '-' || g.pn)                                             AS distinct_id,
       md5('person:' || t.team_id || ':' || g.pn)::uuid                              AS uuid,
       (ARRAY['free','pro','team','enterprise'])[1 + ((('x'||substr(md5('pp:'||t.team_id||':'||g.pn),1,8))::bit(32)::bigint % 100) / 25)] AS plan,
       (ARRAY['US','GB','DE','FR','IN','BR','JP','CA'])[1 + (('x'||substr(md5('pc:'||t.team_id||':'||g.pn),1,8))::bit(32)::bigint % 8)]   AS country
FROM (SELECT unnest(string_to_array(:'team_ids', ','))::bigint AS team_id) t
CROSS JOIN LATERAL generate_series(0, :n_persons - 1) AS g(pn);

INSERT INTO posthog_person (created_at, properties_last_updated_at, properties_last_operation, team_id,
                            properties, is_user_id, is_identified, uuid, version)
SELECT now() - interval '40 days', '{}'::jsonb, '{}'::jsonb, team_id,
       jsonb_build_object('email', 'u'||team_id||'-'||pn||'@example.test', 'plan', plan, 'country', country),
       NULL, (pn % 3 = 0), uuid, 0
FROM gen_p;

INSERT INTO posthog_persondistinctid (team_id, person_id, distinct_id, version)
SELECT p.team_id, pp.id, p.distinct_id, 0
FROM gen_p p JOIN posthog_person pp ON pp.uuid = p.uuid AND pp.team_id = p.team_id;

-- what gen.sh copies into ClickHouse's person / person_distinct_id2
CREATE TABLE IF NOT EXISTS paraglobe_gen_persons AS
SELECT p.team_id, p.pn, p.distinct_id, p.uuid, pp.properties::text AS properties, pp.is_identified::int AS is_identified, pp.created_at
FROM gen_p p JOIN posthog_person pp ON pp.uuid = p.uuid AND pp.team_id = p.team_id;
COMMIT;
