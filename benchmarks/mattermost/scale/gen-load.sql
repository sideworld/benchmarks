-- Mattermost at scale, generated at the data plane.
--
-- Shape: one team, :n_channels channels, :n_users users, :n_posts posts distributed Zipf(1.0)
-- across the channels, so the busiest channel carries ~12% of everything and the quietest a few
-- hundred. Threads, reactions and file metadata hang off the posts. Every id is
-- substr(md5(...),1,26), which satisfies model.IsValidId (26 chars, letters and digits) and is a
-- pure function of the row's sequence number -- that last property is what makes it possible to
-- point a reply at its root without a self-join over twenty million rows.
--
-- Rows that already exist (the API-created core) are left alone: the generator only adds.

\set ON_ERROR_STOP on
\timing on

-- One transaction: a loader that fails halfway must leave nothing behind, or the next attempt
-- starts from a database that is neither empty nor populated.
BEGIN;

-- ---------------------------------------------------------------- users
INSERT INTO users (id, createat, updateat, deleteat, username, password, authdata, authservice,
  email, emailverified, nickname, firstname, lastname, roles, allowmarketing, props, notifyprops,
  lastpasswordupdate, lastpictureupdate, failedattempts, locale, mfaactive, mfasecret, "position",
  timezone, remoteid, lastlogin, mfausedtimestamps)
SELECT substr(md5('mmu:'||g), 1, 26),
       t.createat, t.updateat, 0, 'gen'||g, t.password, NULL, '',
       'gen'||g||'@example.test', true, '', 'Gen', g::text, 'system_user', false,
       t.props, t.notifyprops, t.lastpasswordupdate, 0, 0, 'en', false, '', '',
       t.timezone, '', 0, t.mfausedtimestamps
FROM generate_series(1, :n_users) g
CROSS JOIN (SELECT * FROM users WHERE username = 'core1') t;

-- ---------------------------------------------------------------- team membership
-- Not optional. A user who belongs to three thousand channels of a team but is not a member of
-- the team is a row combination Mattermost itself can never produce, and it shows: GET
-- /teams/{id}/channels returns only the channels the CALLER is a member of, so a world without
-- these rows answers that endpoint with the twenty-odd channels the admin happens to have joined
-- and none of the generated ones. It looks like the fork lost the data. It has not.
INSERT INTO teammembers (teamid, userid, roles, deleteat, schemeuser, schemeadmin, schemeguest,
  createat)
SELECT :'team', substr(md5('mmu:'||g), 1, 26), '', 0, true, false, false, :t0
FROM generate_series(1, :n_users) g
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------- channels
-- rank 1 is the busiest. createat walks backwards so older channels look older.
INSERT INTO channels (id, createat, updateat, deleteat, teamid, type, displayname, name, header,
  purpose, lastpostat, totalmsgcount, extraupdateat, creatorid, schemeid, groupconstrained,
  shared, totalmsgcountroot, lastrootpostat, bannerinfo, defaultcategoryname, autotranslation,
  discoverable)
SELECT substr(md5('mmc:'||g), 1, 26),
       -- g::bigint first: generate_series gives int4, and g * 3600000 overflows int4 at
       -- g = 597. The cast after the multiply is too late -- `integer out of range`.
       :t0 - (g::bigint * 3600000), :t0, 0, :'team', 'O',
       'Gen '||g, 'gen-'||g, '', '', 0, 0, 0, :'creator', NULL, false, false, 0, 0,
       NULL, '', false, false
FROM generate_series(1, :n_channels) g;

-- ---------------------------------------------------------------- the post plan
-- One row per generated channel: its Zipf rank, how many posts it gets, and the half-open range
-- of global sequence numbers [lo, lo+n) its posts occupy. The sequence number is the only thing
-- the post insert needs, because every other column is a function of it.
DROP TABLE IF EXISTS gen_plan;
CREATE TABLE gen_plan AS
WITH r AS (
  SELECT g AS rank, substr(md5('mmc:'||g), 1, 26) AS channelid,
         1.0 / g AS w                                    -- Zipf, exponent 1.0
  FROM generate_series(1, :n_channels) g
), n AS (
  SELECT rank, channelid,
         GREATEST(1, floor(:n_posts * w / SUM(w) OVER ())::bigint) AS n_posts
  FROM r
)
-- ::bigint is load-bearing. SUM() over a bigint returns NUMERIC, which made `lo` numeric, which
-- made the generate_series below yield numeric, which turned every `n / 16` from integer division
-- into exact division. 127/16 = 7.9375, and `1 + (7.9375 % 8)` rounds to subscript 9 on an
-- 8-element array -- and an out-of-range array subscript in Postgres is NULL, not an error. The
-- result was a NULL message on 11.6% of posts. Every database-level consistency check passed;
-- it took reading a page of channel history through Mattermost's own API to see it.
SELECT rank, channelid, n_posts,
       COALESCE(SUM(n_posts) OVER (ORDER BY rank ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)::bigint AS lo
FROM n;
CREATE UNIQUE INDEX ON gen_plan (rank);
ANALYZE gen_plan;

-- ---------------------------------------------------------------- channel members
-- Busy channels have more members: 5 + 2000/rank, capped at 400. Everyone is a member of the
-- top channels, which is what makes the unread-count probe touch a realistic number of rows.
INSERT INTO channelmembers (channelid, userid, roles, lastviewedat, msgcount, mentioncount,
  notifyprops, lastupdateat, schemeuser, schemeadmin, schemeguest, mentioncountroot, msgcountroot,
  urgentmentioncount, autotranslation, autotranslationdisabled)
SELECT p.channelid, substr(md5('mmu:'||u), 1, 26), '', 0, 0, 0,
       '{}'::jsonb, :t0, true, false, false, 0, 0, 0, false, false
FROM gen_plan p
CROSS JOIN LATERAL generate_series(1, LEAST(400, 5 + (2000 / p.rank))::int) u
WHERE u <= :n_users;

-- ---------------------------------------------------------------- posts
-- n is the global sequence number. Everything below is a function of n and of the plan row.
--   reply      : two sequence numbers in every seven
--   root of it : the nearest earlier multiple-of-five boundary, clamped into the same channel
--   author     : spread over the users that are actually members of this channel
--   createat   : walks forward from :t_start to :t0, so history is ordered and recent posts are
--                the ones a first page has to find
INSERT INTO posts (id, createat, updateat, deleteat, userid, channelid, rootid, originalid,
  message, type, props, hashtags, filenames, fileids, hasreactions, editat, ispinned, remoteid)
SELECT substr(md5('mmp:'||n), 1, 26),
       ts, ts, 0,
       substr(md5('mmu:'|| (1 + (n % LEAST(:n_users, GREATEST(1, LEAST(400, 5 + (2000 / p.rank)))))) ), 1, 26),
       p.channelid,
       CASE WHEN n % 7 IN (3, 5) AND root_n > p.lo THEN substr(md5('mmp:'||root_n), 1, 26) ELSE '' END,
       '',
       w1 || ' ' || w2 || ' ' || w3 || ' — thread ' || (n % 9973),
       '', '{}'::jsonb, '', '[]', '[]',
       (n % 20 = 0), 0, false, ''
FROM gen_plan p
CROSS JOIN LATERAL generate_series(p.lo + 1, p.lo + p.n_posts) AS s(n)
CROSS JOIN LATERAL (SELECT
    (:t_start + ((n - p.lo) * ((:t0 - :t_start) / GREATEST(p.n_posts, 1))))::bigint AS ts,
    (n - (n % 5) - 1)                                                              AS root_n,
    (ARRAY['deployment','incident','rollback','latency','postgres','kafka','release','oncall',
           'dashboard','retro','migration','timeout','cache','replica','alert','runbook'])[1 + (n % 16)]  AS w1,
    (ARRAY['looks','confirmed','failing','green','slow','retried','queued','blocked'])[1 + (div(n, 16) % 8)] AS w2,
    (ARRAY['on staging','in eu-west','after the rollout','since 14:00','for tenant 42',
           'on the replica','in the canary','behind the flag'])[1 + (div(n, 128) % 8)]                       AS w3
  ) e;

COMMIT;
