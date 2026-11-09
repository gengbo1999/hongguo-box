#!/usr/bin/env python3
"""目录层: 全库索引的读接口。

客户端以前把 58.8 万条索引(22MB 的 index.bin.z)打进 IPA, 由 LocalIndex.swift
在本地解析。现在这部分搬到服务端, 客户端只发 HTTP:

    GET /api/tags      标签桶(热门标签 + 全量列表)
    GET /api/tag       按标签翻页
    GET /api/newest    新剧流(created 倒序)
    GET /api/random    全库随机
    GET /api/search    标题搜索
    GET /api/series    按 id 批量取

两条和客户端对齐的规矩:
1. 每条统一成 {id,title,cover,intro,eps,tags,created}, tags 是数组, created 是
   秒级时间戳(老索引没有该字段时是 0);
2. cover 在索引里只有 16 字节哈希, 这里拼成图床 URL —— 上游的签名图片地址会
   过期, 所以一个字节都不存。

标签查询走倒排表 series_tag(tid, sid, created), 不再对 58 万行做 LIKE 全表
扫描。倒排表在导入种子之后、以及每次爬取之后按需重建, 判据是签名
"条数:最大 updated" 变了没有。
"""

from __future__ import annotations

import random
import re
import threading
import time
import unicodedata

# 图床地址和客户端 LocalIndex 里的拼法完全一致
COVER_HOST = "https://p6-novel.byteimg.com/novel-pic/"
COVER_TAIL = "~tplv-shrink:640:0.image"

DEFAULT_LIMIT = 24
MAX_LIMIT = 100
TAG_BUCKETS_MAX = 1000
SEARCH_MAX_LEN = 64

_HEX32 = re.compile(r"^[0-9a-f]{32}$")
_HASH_IN_COVER_URL = re.compile(r"/novel-pic/([0-9a-f]{32})")
# LIKE 里 % _ \ 都有特殊含义, 用户搜 "100%" 时不能当成通配符
_LIKE_ESC = str.maketrans({"\\": "\\\\", "%": "\\%", "_": "\\_"})

SCHEMA = (
    """CREATE TABLE IF NOT EXISTS series(
        sid TEXT PRIMARY KEY, title TEXT NOT NULL, cover TEXT DEFAULT '',
        intro TEXT DEFAULT '', eps INTEGER DEFAULT 0, tags TEXT DEFAULT '',
        vids TEXT DEFAULT '', created INTEGER DEFAULT 0,
        accessed INTEGER DEFAULT 0, updated INTEGER DEFAULT 0)""",
    "CREATE INDEX IF NOT EXISTS ix_title ON series(title)",
    "CREATE INDEX IF NOT EXISTS ix_created ON series(created)",
    """CREATE TABLE IF NOT EXISTS tag(
        tid INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)""",
    """CREATE TABLE IF NOT EXISTS series_tag(
        tid INTEGER NOT NULL, sid TEXT NOT NULL,
        created INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(tid, sid)) WITHOUT ROWID""",
    "CREATE INDEX IF NOT EXISTS ix_series_tag_order"
    " ON series_tag(tid, created DESC, sid DESC)",
    # 抖音剧集缓存: 详情/播放按需拉一次, 别每次请求都打上游
    """CREATE TABLE IF NOT EXISTS dy_ep(
        vid TEXT PRIMARY KEY, sid TEXT NOT NULL, ep INTEGER NOT NULL,
        duration_ms INTEGER DEFAULT 0, width INTEGER DEFAULT 0,
        height INTEGER DEFAULT 0, cover TEXT DEFAULT '',
        plays TEXT DEFAULT '', updated INTEGER DEFAULT 0)""",
    "CREATE INDEX IF NOT EXISTS ix_dy_ep_sid ON dy_ep(sid, ep)",
    # 抖音待定行: 比红果最新入库还新, 先挂这里, 每次红果 refresh 后自动重判
    """CREATE TABLE IF NOT EXISTS dy_pending(
        sid TEXT PRIMARY KEY, title TEXT DEFAULT '', real_name TEXT DEFAULT '',
        eps INTEGER DEFAULT 0, created INTEGER DEFAULT 0,
        first_seen INTEGER DEFAULT 0, checked INTEGER DEFAULT 0)""",
)

PUNCT = re.compile(r'[，。！？、：；""\'\'（）()\[\]【】·.…—\-_,!?:;"\']')


def norm_title(t):
    """标题归一化: 去「短剧 · 」前缀、书名号、全半角、标点、空白, 转小写。

    抖音/红果两侧入库脚本必须用同一套规则, 否则比对结果会漂。
    """
    t = (t or "").strip()
    t = re.sub(r"^短剧\s*[·•:：]\s*", "", t)
    t = re.sub(r"[《》]", "", t)
    t = unicodedata.normalize("NFKC", t)
    t = re.sub(r"[\s\u3000]", "", t)
    # 后缀必须在去标点之前剥: 否则 "1-99集" 里的 '-' 会先被当成标点删掉
    t = re.sub(r"[（(]?[0-9一二三四五六七八九十百]+[-~至到][0-9一二三四五六七八九十百]+集[）)]?$", "", t)
    t = re.sub(r"[（(]?(完整版|未删减版|合集|全集|大结局|抢先看)[）)]?$", "", t)
    t = PUNCT.sub("", t)
    return t.lower()

_COLS = "sid,title,cover,intro,eps,tags,created"
_COLS_S = "s.sid,s.title,s.cover,s.intro,s.eps,s.tags,s.created"

_bucket_cache = {"sig": None, "limit": 0, "items": []}
_bucket_lock = threading.Lock()


# ------------------------------------------------------------------ 形状

def cover_hash(raw):
    """封面 -> 32 位哈希。老索引存哈希, 站点详情给的却是带签名的 URL, 两种都认。"""
    s = (raw or "").strip().lower()
    if not s:
        return ""
    if _HEX32.match(s):
        return "" if s == "0" * 32 else s
    m = _HASH_IN_COVER_URL.search(s)
    return m.group(1) if m else ""


def cover_url(raw):
    """封面 -> 图床 URL。认哈希也认站点 URL; 认不出来又是个 http 地址就原样给出。"""
    h = cover_hash(raw)
    if h:
        return COVER_HOST + h + COVER_TAIL
    s = (raw or "").strip()
    return s if s.startswith(("http://", "https://")) else ""


def tags_list(raw):
    """'都市,逆袭,逆袭' -> ['都市','逆袭'](去空去重, 保留原顺序)。"""
    out = []
    for name in (raw or "").split(","):
        name = name.strip()
        if name and name not in out:
            out.append(name)
    return out


def series_json(row):
    """sqlite3.Row / 元组(sid,title,cover,intro,eps,tags,created) -> 统一条目。"""
    try:
        source = row["source"] or "hg"
    except (IndexError, KeyError):
        source = "hg"
    return {
        "id": row[0],
        "title": row[1],
        "cover": cover_url(row[2]),
        "intro": row[3] or "",
        "eps": row[4] or 0,
        "tags": tags_list(row[5]),
        "created": row[6] or 0,
        "source": source,
    }


# ------------------------------------------------------------ 建表与倒排

def ensure_schema(c):
    for sql in SCHEMA:
        c.execute(sql)
    _migrate_source(c)
    c.execute("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")
    c.commit()


def _migrate_source(c):
    """给老库补 source 列(默认 hg)。不换主键: 抖音 sid 落库时带 dy: 前缀,
    两个命名空间天然不撞, 老行和所有既有查询都不用改。"""
    cols = {r[1] for r in c.execute("PRAGMA table_info(series)")}
    if "source" not in cols:
        c.execute("ALTER TABLE series ADD COLUMN source TEXT NOT NULL DEFAULT 'hg'")
    c.execute("CREATE INDEX IF NOT EXISTS ix_source ON series(source)")


def _meta(c, key, default=None):
    row = c.execute("SELECT v FROM meta WHERE k=?", (key,)).fetchone()
    return row[0] if row else default


def _set_meta(c, key, value):
    c.execute("INSERT INTO meta(k,v) VALUES(?,?)"
              " ON CONFLICT(k) DO UPDATE SET v=excluded.v", (key, str(value)))


def index_signature(c):
    n, updated = c.execute(
        "SELECT COUNT(*), COALESCE(MAX(updated), 0) FROM series").fetchone()
    return f"{n}:{updated}"


def tag_count(c):
    return c.execute("SELECT COUNT(*) FROM tag").fetchone()[0]


def tag_index_stale(c):
    return _meta(c, "tag_index_sig") != index_signature(c)


def ensure_tag_index(c, batch=20000):
    """倒排表过期就重建。返回 True 表示这次真的重建了。

    重建是一次 DELETE + 190 万行 INSERT, 在 58 万条的库上约 3~4 秒, 所以只在
    导入种子之后和每轮爬取之后调用, 不放在请求路径上。
    """
    sig = index_signature(c)
    if _meta(c, "tag_index_sig") == sig and tag_count(c) > 0:
        return False
    t0 = time.time()
    c.execute("DELETE FROM series_tag")
    c.execute("DELETE FROM tag")
    name2tid = {}
    tag_rows = []
    st_rows = []
    cur = c.execute("SELECT sid, tags, created FROM series")
    try:
        while True:
            rows = cur.fetchmany(batch)
            if not rows:
                break
            for sid, tags, created in rows:
                seen = set()
                for name in (x.strip() for x in (tags or "").split(",")):
                    if not name or name in seen:
                        continue
                    seen.add(name)
                    tid = name2tid.get(name)
                    if tid is None:
                        tid = len(name2tid) + 1
                        name2tid[name] = tid
                        tag_rows.append((tid, name))
                    st_rows.append((tid, sid, created or 0))
            if len(st_rows) >= batch * 4:
                c.executemany("INSERT INTO tag(tid,name) VALUES(?,?)", tag_rows)
                c.executemany("INSERT INTO series_tag(tid,sid,created) VALUES(?,?,?)", st_rows)
                tag_rows.clear()
                st_rows.clear()
        c.executemany("INSERT INTO tag(tid,name) VALUES(?,?)", tag_rows)
        c.executemany("INSERT INTO series_tag(tid,sid,created) VALUES(?,?,?)", st_rows)
        _set_meta(c, "tag_index_sig", sig)
        _set_meta(c, "tag_index_at", int(time.time()))
        c.commit()
    except Exception:
        c.rollback()
        raise
    with _bucket_lock:
        _bucket_cache.update({"sig": None, "limit": 0, "items": []})
    print(f"[catalog] 标签倒排 {len(name2tid)} 个标签,"
          f" 用时 {time.time() - t0:.1f}s", flush=True)
    return True


# ---------------------------------------------------------------- 查询

def count(c):
    return c.execute("SELECT COUNT(*) FROM series").fetchone()[0]


def tag_buckets(c, limit=TAG_BUCKETS_MAX):
    """[(tag, count)] 按数量降序、同数量按名字升序。结果带进程内缓存。"""
    sig = _meta(c, "tag_index_sig")
    with _bucket_lock:
        hit = _bucket_cache
        if hit["items"] and hit["sig"] == sig and hit["limit"] == limit:
            return hit["items"]
    n = max(1, min(int(limit or TAG_BUCKETS_MAX), TAG_BUCKETS_MAX))
    rows = c.execute(
        """SELECT t.name, count(*) AS n FROM series_tag st
             JOIN tag t ON t.tid = st.tid
            GROUP BY st.tid ORDER BY n DESC, t.name ASC LIMIT ?""", (n,)).fetchall()
    items = [{"tag": r[0], "count": r[1]} for r in rows]
    with _bucket_lock:
        _bucket_cache.update({"sig": sig, "limit": limit, "items": items})
    return items


def tag_page(c, tag, offset=0, limit=DEFAULT_LIMIT):
    """按标签翻页。未知标签返回 total=0 / items=[], 与客户端 LocalIndex 一致。"""
    tag = (tag or "").strip()
    offset = max(0, int(offset or 0))
    limit = max(1, min(int(limit or DEFAULT_LIMIT), MAX_LIMIT))
    row = c.execute("SELECT tid FROM tag WHERE name=?", (tag,)).fetchone()
    if not row:
        return {"tag": tag, "total": 0, "items": [], "next": 0}
    tid = row[0]
    total = c.execute("SELECT COUNT(*) FROM series_tag WHERE tid=?", (tid,)).fetchone()[0]
    if offset >= total:
        return {"tag": tag, "total": total, "items": [], "next": total}
    rows = c.execute(
        f"""SELECT {_COLS_S} FROM series_tag st JOIN series s ON s.sid = st.sid
             WHERE st.tid = ? ORDER BY st.created DESC, st.sid DESC
             LIMIT ? OFFSET ?""", (tid, limit, offset)).fetchall()
    items = [series_json(r) for r in rows]
    return {"tag": tag, "total": total, "items": items, "next": offset + len(items)}


def newest(c, offset=0, limit=DEFAULT_LIMIT):
    offset = max(0, int(offset or 0))
    limit = max(1, min(int(limit or DEFAULT_LIMIT), MAX_LIMIT))
    rows = c.execute(
        f"SELECT {_COLS} FROM series ORDER BY created DESC, sid DESC"
        " LIMIT ? OFFSET ?", (limit, offset)).fetchall()
    items = [series_json(r) for r in rows]
    return {"total": count(c), "items": items, "next": offset + len(items)}


def random_series(c, limit=20, exclude=()):
    """全库随机: 先随机 rowid, 再取该位置之后的第一行。

    比 ORDER BY RANDOM() 便宜(不用给 58 万行排序), 又不像"随机起点后连取 N 条"
    那样一次吐出一整段相邻的剧。排除集命中就重新抽, 抽不满就少给几条。
    """
    limit = max(1, min(int(limit or 20), MAX_LIMIT))
    skip = {x for x in exclude if x}
    hi = c.execute("SELECT MAX(rowid) FROM series").fetchone()[0] or 0
    if hi <= 0:
        return []
    out = []
    seen = set(skip)
    attempts = 0
    while len(out) < limit and attempts < limit * 6:
        attempts += 1
        row = c.execute(
            f"SELECT {_COLS} FROM series WHERE rowid >= ? ORDER BY rowid LIMIT 1",
            (random.randint(1, hi),)).fetchone()
        if row is None:  # 抽到最后一行之后, 绕回开头
            row = c.execute(
                f"SELECT {_COLS} FROM series ORDER BY rowid LIMIT 1").fetchone()
        if row is None or row[0] in seen:
            continue
        seen.add(row[0])
        out.append(series_json(row))
    return out


def search(c, q, offset=0, limit=30):
    """标题子串搜索。ASCII 大小写不敏感(LIKE 的默认行为), 顺带支持按 id 精确命中。"""
    q = (q or "").strip()[:SEARCH_MAX_LEN]
    offset = max(0, int(offset or 0))
    limit = max(1, min(int(limit or 30), MAX_LIMIT))
    if not q:
        return {"q": "", "total": 0, "items": [], "next": 0}
    pat = "%" + q.translate(_LIKE_ESC) + "%"
    where = r"WHERE (title LIKE ? ESCAPE '\' OR sid = ?)"
    total = c.execute("SELECT COUNT(*) FROM series " + where, (pat, q)).fetchone()[0]
    rows = c.execute(
        f"SELECT {_COLS} FROM series " + where +
        " ORDER BY created DESC, sid DESC LIMIT ? OFFSET ?",
        (pat, q, limit, offset)).fetchall()
    items = [series_json(r) for r in rows]
    return {"q": q, "total": total, "items": items, "next": offset + len(items)}


def by_ids(c, ids, chunk=200):
    """按 id 批量取, 返回顺序跟着入参走(缺的跳过)。"""
    want = [str(x).strip() for x in ids if str(x).strip()]
    if not want:
        return []
    found = {}
    for i in range(0, len(want), chunk):
        part = want[i:i + chunk]
        marks = ",".join("?" * len(part))
        for r in c.execute(f"SELECT {_COLS} FROM series WHERE sid IN ({marks})", part):
            found[r[0]] = series_json(r)
    out = []
    seen = set()
    for sid in want:
        if sid in found and sid not in seen:
            seen.add(sid)
            out.append(found[sid])
    return out
