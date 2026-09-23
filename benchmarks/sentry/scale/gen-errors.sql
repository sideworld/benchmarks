-- Sideworld data-plane generator for Sentry's errors dataset.
--
-- Writes rows straight into ClickHouse's errors_local, mapped onto the 20,000 synthetic groups
-- created in Postgres by gen-groups.sql. The mapping has to be deterministic on both sides or the
-- two stores disagree, so the group index `g` is materialised in a subquery: a WITH alias in
-- ClickHouse is substituted like a macro, and `randCanonical()` used twice would produce two
-- different values and put a group in the wrong project.
--
-- Skew, chosen to look like a real installation rather than a uniform load:
--   * events per group: pow(randCanonical(), 3) over 20,000 groups -- a heavy head and a long tail
--   * groups per project: the first 40% of group indices belong to project 2, then 22% to 3, and
--     so on, so the hot groups sit in the hot projects
--   * timestamps: pow(randCanonical(), 2) over the last 85 days -- recent-weighted, and inside the
--     90-day retention the table's TTL enforces
INSERT INTO errors_local
  (project_id, timestamp, event_id, platform, environment, release, `tags.key`, `tags.value`,
   partition, offset, message_timestamp, retention_days, deleted, group_id, primary_hash,
   received, message, title, culprit, level, type, `exception_stacks.type`, `exception_stacks.value`,
   user, transaction_name)
SELECT
  multiIf(g < 8000, 2, g < 12400, 3, g < 15200, 4, g < 16800, 5,
          g < 18000, 6, g < 18800, 7, g < 19600, 8, 9)                     AS project_id,
  ts                                                                       AS timestamp,
  generateUUIDv4()                                                         AS event_id,
  ['python','javascript','java','go'][1 + (g % 4)]                         AS platform,
  ['production','production','production','staging'][1 + (n % 4)]          AS environment,
  ['1.4.2','1.4.3','1.5.0','2.0.0-rc1'][1 + (n % 4)]                       AS release,
  ['server_name','customer_tier','handled']                                AS `tags.key`,
  [concat('web-', toString(1 + (n % 12))),
   ['free','pro','enterprise'][1 + (n % 3)], 'no']                         AS `tags.value`,
  0                                                                        AS partition,
  n                                                                        AS offset,
  ts                                                                       AS message_timestamp,
  90                                                                       AS retention_days,
  0                                                                        AS deleted,
  100000 + g                                                               AS group_id,
  toUUID(concat(substring(h,1,8),'-',substring(h,9,4),'-',substring(h,13,4),'-',
                substring(h,17,4),'-',substring(h,21,12)))                 AS primary_hash,
  ts                                                                       AS received,
  msg                                                                      AS message,
  msg                                                                      AS title,
  concat('app/', ['views','tasks','models','api'][1 + (g % 4)], '.py in handle') AS culprit,
  'error'                                                                  AS level,
  'error'                                                                  AS type,
  [ concat('SyntheticError', toString(g % 97)) ]                           AS `exception_stacks.type`,
  [ ['upstream timed out','invalid literal','missing key','connection reset','duplicate key',
     'permission denied','null attribute','decode failure','rate limited','invariant violated'][1 + (g % 10)] ]
                                                                           AS `exception_stacks.value`,
  concat('id:', toString(1 + (n % 50000)))                                 AS user,
  concat('/', ['checkout','pay','search','list','admin'][1 + (n % 5)])     AS transaction_name
FROM (
  SELECT
    number                                                                 AS n,
    toUInt64(pow(randCanonical(), 3) * 20000)                              AS g,
    now() - toIntervalSecond(toUInt64(pow(randCanonical(), 2) * 86400 * 85)) AS ts,
    lower(hex(MD5(toString(toUInt64(pow(0, 1) + 0)))))                     AS _unused
  FROM numbers({OFFSET:UInt64}, {BATCH:UInt64})
)
ARRAY JOIN [lower(hex(MD5(toString(g))))] AS h,
           [concat('SyntheticError', toString(g % 97), ': ',
            ['upstream timed out','invalid literal','missing key','connection reset','duplicate key',
             'permission denied','null attribute','decode failure','rate limited','invariant violated'][1 + (g % 10)])] AS msg
