-- Phase 2: everything that hangs off the posts. Runs AFTER the post indexes are back, because
-- all three of these read posts by id or group by rootid.
\set ON_ERROR_STOP on
\timing on
BEGIN;

-- ---------------------------------------------------------------- threads
INSERT INTO threads (postid, replycount, lastreplyat, participants, channelid, threaddeleteat,
  threadteamid)
SELECT r.rootid, count(*), max(r.createat),
       jsonb_agg(DISTINCT r.userid), min(r.channelid), NULL, :'team'
FROM posts r
WHERE r.rootid <> ''
GROUP BY r.rootid
ON CONFLICT DO NOTHING;

INSERT INTO threadmemberships (postid, userid, following, lastviewed, lastupdated, unreadmentions)
SELECT t.postid, p.userid, true, 0, :t0, 0
FROM threads t JOIN posts p ON p.id = t.postid
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------- reactions
-- posts.hasreactions was set by the loader for one post in twenty; this fills them in.
INSERT INTO reactions (userid, postid, emojiname, createat, updateat, deleteat, remoteid, channelid)
SELECT substr(md5('mmu:'|| (1 + ((('x'||substr(md5(p.id),1,6))::bit(24)::int + k) % :n_users)) ), 1, 26),
       p.id,
       (ARRAY['+1','tada','eyes','rocket','heart'])[1 + ((('x'||substr(md5(p.id),1,4))::bit(16)::int + k) % 5)],
       p.createat, p.createat, 0, '', p.channelid
FROM posts p
CROSS JOIN LATERAL generate_series(1, 1 + (('x'||substr(md5(p.id),1,2))::bit(8)::int % 3)) AS kk(k)
WHERE p.hasreactions
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------- file metadata -> MinIO
-- The path is exactly the layout Mattermost's S3 filestore writes, so these rows address objects
-- in the bucket the running server uses. The objects themselves are NOT uploaded: twenty million
-- posts' worth of bytes is not what is being measured, and the ledger says so plainly.
INSERT INTO fileinfo (id, creatorid, postid, createat, updateat, deleteat, path, thumbnailpath,
  previewpath, name, extension, size, mimetype, width, height, haspreviewimage, minipreview,
  content, remoteid, archived, channelid)
SELECT substr(md5('mmf:'||p.id), 1, 26), p.userid, p.id, p.createat, p.createat, 0,
       to_char(to_timestamp(p.createat / 1000), 'YYYYMMDD') || '/teams/' || :'team' ||
         '/channels/' || p.channelid || '/users/' || p.userid || '/' ||
         substr(md5('mmf:'||p.id), 1, 26) || '/capture.png',
       '', '', 'capture.png', 'png',
       40000 + (('x'||substr(md5(p.id),1,6))::bit(24)::int % 900000),
       'image/png', 1280, 720, false, NULL, '', '', false, p.channelid
FROM posts p
WHERE NOT p.hasreactions AND ('x'||substr(md5(p.id),1,4))::bit(16)::int % 50 = 0
ON CONFLICT DO NOTHING;

UPDATE posts p SET fileids = '["' || substr(md5('mmf:'||p.id), 1, 26) || '"]'
FROM fileinfo f WHERE f.postid = p.id;

COMMIT;
