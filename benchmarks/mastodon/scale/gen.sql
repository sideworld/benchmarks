-- Mastodon scale generator: data plane, inside Postgres, with Mastodon's own id scheme and
-- referential shape. Parameters come in as psql variables (see gen.sh):
--   n_accounts, n_statuses, n_follows_longtail, n_favourites, heavy (number of mega-follow
--   accounts), heavy_followers (followers each), years (time spread), seed.
-- Everything hangs off real rows: statuses.account_id -> accounts, follows -> accounts,
-- favourites -> statuses/accounts, notifications.activity_id -> follows/favourites/reblog
-- statuses, account_stats/status_stats recomputed from the data. Ids for statuses and
-- accounts use the same snowflake layout as Mastodon's timestamp_id(): (epoch_ms << 16) | seq,
-- so the three-year time spread is in the ids themselves and index order == time order.
-- session settings (synchronous_commit, work_mem, session_replication_role) come from
-- benchmarks/lib/pg-bulk-load-begin.sql, which gen.sh prepends; -end.sql validates every FK after.
\timing on
SELECT setseed(:seed);

-- ------------------------------------------------------------------ helpers
CREATE OR REPLACE FUNCTION gen_snowflake(ts timestamp, seq bigint) RETURNS bigint LANGUAGE sql IMMUTABLE AS $$
  SELECT ((extract(epoch FROM ts) * 1000)::bigint << 16) | (seq & 65535)
$$;
-- skewed timestamp over the last :years years, denser towards now
CREATE OR REPLACE FUNCTION gen_ts(r double precision, years int) RETURNS timestamp LANGUAGE sql IMMUTABLE AS $$
  SELECT (now() - (years * 365 * power(r, 1.6)) * interval '1 day')::timestamp
$$;

-- ------------------------------------------------------------------ accounts + users
-- The admin already exists (uid 1 = instance actor, then admin). Generated accounts are local,
-- with a key pair copied from the admin (real RSA keys, so ActivityPub code paths that read
-- them do not break), and a users row each with the admin's bcrypt hash (password known).
\echo === accounts
-- the app's own admin account has no key pair and empty URLs; generated accounts match it
INSERT INTO accounts (id, username, domain, public_key, created_at, updated_at,
                      note, display_name, uri, url, inbox_url, outbox_url, shared_inbox_url,
                      followers_url, following_url, protocol, locked, discoverable, indexable)
SELECT gen_snowflake(t, g), 'u' || g, NULL, '', t, t,
       '', 'User ' || g, NULL, NULL, '', '', '', '', '', 0, false, (g % 7 = 0), (g % 11 = 0)
FROM (SELECT g, gen_ts(random(), :years) AS t FROM generate_series(1, :n_accounts) g) s;

\echo === users
INSERT INTO users (account_id, email, encrypted_password, confirmed_at, approved, created_at, updated_at, locale, role_id)
SELECT a.id, a.username || '@mastodon.test', (SELECT encrypted_password FROM users LIMIT 1),
       a.created_at, true, a.created_at, a.created_at, 'en', NULL
FROM accounts a WHERE a.domain IS NULL AND a.username LIKE 'u%' AND a.username ~ '^u[0-9]+$';

-- the heavy accounts: the :heavy lowest-numbered generated accounts, plus one "heavyfollower"
-- that follows many (the home-timeline probe target)
CREATE TEMP TABLE gen_accounts AS
  SELECT id, row_number() OVER (ORDER BY id) AS n FROM accounts WHERE domain IS NULL AND username ~ '^u[0-9]+$';
CREATE INDEX ON gen_accounts (n);
CREATE TEMP TABLE heavy AS SELECT id, n FROM gen_accounts WHERE n <= :heavy;

-- ------------------------------------------------------------------ follows
\echo === follows: heavy
INSERT INTO follows (account_id, target_account_id, created_at, updated_at, show_reblogs, notify)
SELECT f.id, h.id, gen_ts(random(), :years), now(), true, false
FROM heavy h
JOIN LATERAL (SELECT id FROM gen_accounts WHERE n > :heavy ORDER BY n LIMIT :heavy_followers OFFSET (h.n - 1) * 100) f ON true;
\echo === follows: long tail
-- random picks are computed once per row here and joined; a random() inside a WHERE is
-- re-evaluated per scanned row (volatile), which both misses and costs a full scan per pick
INSERT INTO follows (account_id, target_account_id, created_at, updated_at, show_reblogs, notify)
SELECT DISTINCT ON (a.id, b.id) a.id, b.id, gen_ts(random(), :years), now(), true, false
FROM (SELECT 1 + floor(random() * :n_accounts)::int AS an,
             1 + floor(power(random(), 2.5) * :n_accounts)::int AS bn
      FROM generate_series(1, :n_follows_longtail)) p
JOIN gen_accounts a ON a.n = p.an JOIN gen_accounts b ON b.n = p.bn
WHERE a.id <> b.id AND b.n > :heavy;
-- heavyfollower: follows 5,000 accounts including the heavy ones
INSERT INTO accounts (id, username, domain, public_key, created_at, updated_at, note, display_name,
                      inbox_url, outbox_url, shared_inbox_url, followers_url, following_url, protocol)
VALUES (gen_snowflake(now()::timestamp - interval '2 years', 1), 'heavyfollower', NULL, '',
        now() - interval '2 years', now(), '', 'Heavy Follower', '', '', '', '', '', 0);
INSERT INTO users (account_id, email, encrypted_password, confirmed_at, approved, created_at, updated_at, locale)
SELECT id, 'heavyfollower@mastodon.test', (SELECT encrypted_password FROM users LIMIT 1), created_at, true, created_at, created_at, 'en'
FROM accounts WHERE username = 'heavyfollower' AND domain IS NULL;
INSERT INTO follows (account_id, target_account_id, created_at, updated_at, show_reblogs, notify)
SELECT hf.id, g.id, now() - interval '1 year', now(), true, false
FROM (SELECT id FROM accounts WHERE username = 'heavyfollower' AND domain IS NULL) hf,
     (SELECT id FROM gen_accounts WHERE n <= 5000) g;

-- ------------------------------------------------------------------ statuses
-- Long tail: status -> account via power-law index; heavy accounts get a fixed 2% slice.
-- 10% are reblogs of an earlier status; 15% replies; visibility mostly public.
\echo === statuses
-- Ids must be unique: (ms << 16) | seq. Originals get a strictly decreasing timestamp in g
-- (a power-law skew towards now, at least 1 ms apart once g > ~500, and seq = g below that),
-- so id order == time order and no two rows share (ms, seq).
CREATE TEMP TABLE status_src AS
SELECT g,
       (now() - ((:years)::bigint * 365 * 86400000 * power(g::double precision / :n_statuses, 1.6) + g) * interval '1 millisecond')::timestamp AS t,
       CASE WHEN r2 < 0.02 THEN 1 + floor(r3 * :heavy)::int
            ELSE 1 + floor(power(r3, 3) * :n_accounts)::int END AS an,
       r4
FROM (SELECT g, random() r1, random() r2, random() r3, random() r4 FROM generate_series(1, :n_statuses) g) x;
-- one conversation per original status, as the app does; ids allocated from the sequence
SELECT setval('conversations_id_seq', (SELECT coalesce(max(id), 0) FROM conversations) + :n_statuses + 1);
CREATE TEMP TABLE conv_base AS SELECT (SELECT coalesce(max(id), 0) FROM conversations) AS b;
INSERT INTO conversations (id, created_at, updated_at)
SELECT (SELECT b FROM conv_base) + g, gen_ts(random(), :years), now() FROM generate_series(1, :n_statuses) g;
INSERT INTO statuses (id, account_id, text, created_at, updated_at, visibility, local, reply, sensitive,
                      spoiler_text, language, conversation_id, in_reply_to_id, in_reply_to_account_id, reblog_of_id, uri, url)
SELECT gen_snowflake(s.t, s.g), a.id,
       CASE WHEN s.r4 < 0.10 THEN '' ELSE 'status ' || s.g || ' ' || repeat('lorem ipsum ', 1 + (s.g % 9)) END,
       s.t, s.t,
       CASE WHEN s.r4 < 0.85 THEN 0 WHEN s.r4 < 0.95 THEN 1 ELSE 2 END,
       true, false, false, '', 'en',
       (SELECT b FROM conv_base) + s.g, NULL, NULL, NULL,
       'https://mastodon.test/ap/users/' || a.id || '/statuses/' || gen_snowflake(s.t, s.g), NULL
FROM status_src s JOIN gen_accounts a ON a.n = s.an;
DROP TABLE status_src;

\echo === statuses: reblogs (10% of the total, sampled from originals, later in time, random account)
INSERT INTO statuses (id, account_id, text, created_at, updated_at, visibility, local, reply, sensitive,
                      spoiler_text, language, conversation_id, reblog_of_id, uri)
SELECT gen_snowflake(o.t, o.rn), a.id, '', o.t, o.t, 0, true, false, false, '', 'en', o.conversation_id, o.id,
       'https://mastodon.test/ap/users/' || a.id || '/statuses/' || gen_snowflake(o.t, o.rn)
FROM (SELECT id, conversation_id, row_number() OVER () AS rn,
             (created_at + interval '1 day' * random() * 30)::timestamp AS t,
             1 + floor(power(random(), 2) * :n_accounts)::int AS an
      FROM statuses TABLESAMPLE SYSTEM (:reblog_pct) WHERE reblog_of_id IS NULL AND visibility = 0) o
JOIN gen_accounts a ON a.n = o.an
WHERE o.t < now()
ON CONFLICT (id) DO NOTHING;

-- ------------------------------------------------------------------ favourites
\echo === favourites
INSERT INTO favourites (account_id, status_id, created_at, updated_at)
SELECT DISTINCT ON (a.id, s.id) a.id, s.id, s.created_at + interval '1 hour' * random(), now()
FROM (SELECT id, created_at, 1 + floor(random() * :n_accounts)::int AS an
      FROM statuses TABLESAMPLE SYSTEM (:fav_pct) WHERE reblog_of_id IS NULL) s
JOIN gen_accounts a ON a.n = s.an;

-- ------------------------------------------------------------------ notifications
-- follow -> Follow, favourite -> Favourite, reblog -> Status (the reblog), each to the target's owner.
\echo === notifications
INSERT INTO notifications (account_id, from_account_id, activity_id, activity_type, type, created_at, updated_at, group_key)
SELECT f.target_account_id, f.account_id, f.id, 'Follow', 'follow', f.created_at, f.created_at, NULL
FROM follows f WHERE f.target_account_id IN (SELECT id FROM gen_accounts);
INSERT INTO notifications (account_id, from_account_id, activity_id, activity_type, type, created_at, updated_at, group_key)
SELECT s.account_id, fv.account_id, fv.id, 'Favourite', 'favourite', fv.created_at, fv.created_at,
       'favourite-' || s.id || '-' || to_char(fv.created_at, 'YYYY-MM-DD')
FROM favourites fv JOIN statuses s ON s.id = fv.status_id;
INSERT INTO notifications (account_id, from_account_id, activity_id, activity_type, type, created_at, updated_at, group_key)
SELECT o.account_id, r.account_id, r.id, 'Status', 'reblog', r.created_at, r.created_at,
       'reblog-' || o.id || '-' || to_char(r.created_at, 'YYYY-MM-DD')
FROM statuses r JOIN statuses o ON o.id = r.reblog_of_id WHERE r.reblog_of_id IS NOT NULL;

-- ------------------------------------------------------------------ stats
\echo === account_stats / status_stats
DELETE FROM account_stats;
INSERT INTO account_stats (account_id, statuses_count, following_count, followers_count, last_status_at, created_at, updated_at)
SELECT a.id, coalesce(s.c, 0), coalesce(fo.c, 0), coalesce(fr.c, 0), s.last, now(), now()
FROM accounts a
LEFT JOIN (SELECT account_id, count(*) c, max(created_at) last FROM statuses GROUP BY 1) s ON s.account_id = a.id
LEFT JOIN (SELECT account_id, count(*) c FROM follows GROUP BY 1) fo ON fo.account_id = a.id
LEFT JOIN (SELECT target_account_id, count(*) c FROM follows GROUP BY 1) fr ON fr.target_account_id = a.id
WHERE a.domain IS NULL;
DELETE FROM status_stats;
INSERT INTO status_stats (status_id, replies_count, reblogs_count, favourites_count, created_at, updated_at)
SELECT id, 0, coalesce(r.c, 0), coalesce(f.c, 0), now(), now()
FROM statuses s
LEFT JOIN (SELECT reblog_of_id id, count(*) c FROM statuses WHERE reblog_of_id IS NOT NULL GROUP BY 1) r USING (id)
LEFT JOIN (SELECT status_id id, count(*) c FROM favourites GROUP BY 1) f USING (id)
WHERE r.c IS NOT NULL OR f.c IS NOT NULL;

\echo === sequences past the generated ids
SELECT setval('follows_id_seq', (SELECT max(id) FROM follows));
SELECT setval('favourites_id_seq', (SELECT max(id) FROM favourites));
SELECT setval('notifications_id_seq', (SELECT max(id) FROM notifications));
SELECT setval('account_stats_id_seq', (SELECT max(id) FROM account_stats));
SELECT setval('status_stats_id_seq', (SELECT max(id) FROM status_stats));
SELECT setval('users_id_seq', (SELECT max(id) FROM users));
SELECT setval('conversations_id_seq', (SELECT max(id) FROM conversations));
DROP FUNCTION gen_snowflake(timestamp, bigint); DROP FUNCTION gen_ts(double precision, int);
\echo === totals
SELECT (SELECT count(*) FROM accounts) accounts, (SELECT count(*) FROM users) users, (SELECT count(*) FROM statuses) statuses,
       (SELECT count(*) FROM follows) follows, (SELECT count(*) FROM favourites) favourites, (SELECT count(*) FROM notifications) notifications;
