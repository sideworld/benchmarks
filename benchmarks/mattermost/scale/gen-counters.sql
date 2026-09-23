-- Phase 3: the counters Mattermost maintains incrementally as posts arrive. A generator that
-- skips these produces a database that is large and a product that is wrong: channel lists sort
-- by LastPostAt, and every unread badge is ChannelMembers.MsgCount against Channels.TotalMsgCount.
\set ON_ERROR_STOP on
\timing on

UPDATE channels c SET
  totalmsgcount     = s.n,
  totalmsgcountroot = s.n_root,
  lastpostat        = s.last_at,
  lastrootpostat    = s.last_root_at,
  updateat          = s.last_at
FROM (
  SELECT channelid,
         count(*)                                             AS n,
         count(*) FILTER (WHERE rootid = '')                  AS n_root,
         max(createat)                                        AS last_at,
         max(createat) FILTER (WHERE rootid = '')             AS last_root_at
  FROM posts GROUP BY channelid
) s
WHERE c.id = s.channelid;

-- Most members are a little behind; a few are fully caught up. The spread is what makes the
-- unread probe do real work instead of returning zero for everyone.
UPDATE channelmembers m SET
  msgcount      = GREATEST(0, c.totalmsgcount     - (('x'||substr(md5(m.channelid||m.userid),1,3))::bit(12)::int % 60)),
  msgcountroot  = GREATEST(0, c.totalmsgcountroot - (('x'||substr(md5(m.channelid||m.userid),1,3))::bit(12)::int % 60)),
  mentioncount  = (('x'||substr(md5(m.userid||m.channelid),1,2))::bit(8)::int % 4),
  lastviewedat  = GREATEST(0, c.lastpostat - (('x'||substr(md5(m.channelid||m.userid),1,4))::bit(16)::int % 86400000)),
  lastupdateat  = c.lastpostat
FROM channels c WHERE c.id = m.channelid;
