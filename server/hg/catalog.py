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
    # 取流结果落盘缓存: 冷启动一次 js_video_model 要 6-7 秒, 客户端 /resolve
    # 超时 8 秒, 不落盘就会间歇性「播不了」。TTL 由 app.py 控制(1500s)。
    """CREATE TABLE IF NOT EXISTS vm_cache(
        vid TEXT PRIMARY KEY, payload TEXT NOT NULL, updated INTEGER DEFAULT 0)""",
    # ---- 作品(剧)与来源: 一部剧一个 work, 红果/抖音是它的 source。
    # 以前把两个来源做成 series 里两行, 靠标题碰运气对齐; 标签/搜索/最新
    # 都会把同一部剧算两次。现在对外只暴露 work, series 退化成来源明细。
    """CREATE TABLE IF NOT EXISTS work(
        wid TEXT PRIMARY KEY, title TEXT NOT NULL, cover TEXT DEFAULT '',
        intro TEXT DEFAULT '', eps INTEGER DEFAULT 0, tags TEXT DEFAULT '',
        created INTEGER DEFAULT 0, nsrc INTEGER DEFAULT 1,
        updated INTEGER DEFAULT 0)""",
    "CREATE INDEX IF NOT EXISTS ix_work_created ON work(created DESC)",
    "CREATE INDEX IF NOT EXISTS ix_work_title ON work(title)",
    """CREATE TABLE IF NOT EXISTS work_source(
        sid TEXT PRIMARY KEY, wid TEXT NOT NULL, source TEXT NOT NULL,
        eps INTEGER DEFAULT 0, priority INTEGER DEFAULT 9)""",
    "CREATE INDEX IF NOT EXISTS ix_work_source_wid ON work_source(wid)",
    "CREATE INDEX IF NOT EXISTS ix_work_source_source ON work_source(source)",
    """CREATE TABLE IF NOT EXISTS work_tag(
        tid INTEGER NOT NULL, wid TEXT NOT NULL,
        created INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(tid, wid)) WITHOUT ROWID""",
    "CREATE INDEX IF NOT EXISTS ix_work_tag_order"
    " ON work_tag(tid, created DESC, wid DESC)",
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
    """sqlite3.Row / 元组(sid,title,cover,intro,eps,tags,created[,source]) -> 统一条目。

    元组走不了 row["source"]（KeyError 之外还会抛 TypeError），所以按 sid 的
    `dy:` 前缀兜底判来源——老查询没 select source 时也能给出正确值。
    """
    try:
        source = row["source"] or "hg"
    except (IndexError, KeyError, TypeError):
        source = ""
    if not source:
        source = "dy" if str(row[0] if row else "").startswith("dy:") else "hg"
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
    _migrate_norm(c)
    c.execute("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")
    c.commit()


def _migrate_norm(c):
    """标题归一化列: 重建 work 时用 SQL 按 norm 把抖音行挂到红果作品上,
    避免 60 万行在 Python 里两两比对。"""
    cols = {r[1] for r in c.execute("PRAGMA table_info(series)")}
    if "norm" not in cols:
        c.execute("ALTER TABLE series ADD COLUMN norm TEXT NOT NULL DEFAULT ''")
    c.execute("CREATE INDEX IF NOT EXISTS ix_norm ON series(norm)")


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


def work_count(c):
    return c.execute("SELECT COUNT(*) FROM work").fetchone()[0]


def tag_index_stale(c):
    return _meta(c, "tag_index_sig") != index_signature(c)


def fill_norms(c, batch=5000):
    """给历史行补 norm 列。只跑一次, 之后新增行走 upsert 时直接写。"""
    last, n = 0, 0
    while True:
        rows = c.execute(
            "SELECT rowid, sid, title FROM series WHERE rowid > ?"
            " AND (norm IS NULL OR norm = '') ORDER BY rowid LIMIT ?",
            (last, batch)).fetchall()
        if not rows:
            break
        last = rows[-1][0]
        c.executemany("UPDATE series SET norm=? WHERE sid=?",
                      [(norm_title(t), sid) for _, sid, t in rows])
        n += len(rows)
        c.commit()
    if n:
        print(f"[catalog] 补齐 norm {n} 行", flush=True)
    return n


def rebuild_works(c, batch=20000):
    """把 series(来源明细) 重建成 work(作品) + work_source(来源) + work_tag。

    - 红果行一律自成一个 work(同名的红果行不互相合并, 避免把同名不同剧并掉);
    - 抖音行按 norm_title 挂到红果 work 上, 挂不上才成为独立 work;
    - 标签按 work 合并去重, 计数/分页都以 work 为单位。
    """
    t0 = time.time()
    fill_norms(c)
    try:
        _rebuild_works_body(c, t0, batch)
    except Exception:
        c.rollback()
        raise
    return True


def _rebuild_works_body(c, t0, batch):
    now = int(time.time())
    c.execute("DELETE FROM work_tag")
    c.execute("DELETE FROM work_source")
    c.execute("DELETE FROM work")

    c.execute(
        """INSERT INTO work(wid,title,cover,intro,eps,tags,created,nsrc,updated)
           SELECT sid,title,cover,intro,eps,tags,created,1,? FROM series
            WHERE source='hg'""", (now,))
    c.execute(
        """INSERT INTO work_source(sid,wid,source,eps,priority)
           SELECT sid,sid,'hg',eps,0 FROM series WHERE source='hg'""")

    # 抖音行挂到同名红果作品; 多个同名红果行时取 sid 最小的一个(稳定)
    c.execute("DROP TABLE IF EXISTS temp.hg_norm")
    c.execute("CREATE TEMP TABLE hg_norm(norm TEXT PRIMARY KEY, wid TEXT)")
    c.execute(
        """INSERT INTO hg_norm SELECT norm, MIN(sid) FROM series
            WHERE source='hg' AND norm <> '' GROUP BY norm""")
    c.execute(
        """INSERT INTO work_source(sid,wid,source,eps,priority)
           SELECT d.sid, COALESCE(h.wid,d.sid),'dy',d.eps,1
             FROM series d LEFT JOIN hg_norm h ON h.norm = d.norm
            WHERE d.source='dy'""")

    # 没有红果对应物的抖音行: 自己成为 work(wid 就是 dy: sid)
    c.execute(
        """INSERT INTO work(wid,title,cover,intro,eps,tags,created,nsrc,updated)
           SELECT ws.wid, s.title, s.cover, s.intro, s.eps, s.tags, s.created, 1, ?
             FROM work_source ws JOIN series s ON s.sid = ws.sid
             LEFT JOIN work w ON w.wid = ws.wid
            WHERE w.wid IS NULL""", (now,))

    c.execute("UPDATE work SET nsrc ="
              " (SELECT COUNT(*) FROM work_source ws WHERE ws.wid = work.wid)")
    # 多来源作品: 标签按单个标签去重后取并集(不能只对整串 group_concat DISTINCT)
    multi = c.execute("SELECT wid FROM work WHERE nsrc > 1").fetchall()
    for (wid,) in multi:
        names, seen = [], set()
        for (raw,) in c.execute(
                "SELECT s.tags FROM work_source ws JOIN series s ON s.sid = ws.sid"
                " WHERE ws.wid = ? ORDER BY ws.priority", (wid,)):
            for name in (x.strip() for x in (raw or "").split(",")):
                if name and name not in seen:
                    seen.add(name)
                    names.append(name)
        c.execute("UPDATE work SET tags = ? WHERE wid = ?", (",".join(names), wid))

    # 标签倒排: 以 work 为单位重建
    c.execute("DELETE FROM tag")
    name2tid = {}
    tag_rows, wt_rows = [], []
    cur = c.execute("SELECT wid, tags, created FROM work")
    try:
        while True:
            rows = cur.fetchmany(batch)
            if not rows:
                break
            for wid, tags, created in rows:
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
                    wt_rows.append((tid, wid, created or 0))
            if len(wt_rows) >= batch * 4:
                c.executemany("INSERT INTO tag(tid,name) VALUES(?,?)", tag_rows)
                c.executemany(
                    "INSERT INTO work_tag(tid,wid,created) VALUES(?,?,?)", wt_rows)
                tag_rows.clear()
                wt_rows.clear()
        c.executemany("INSERT INTO tag(tid,name) VALUES(?,?)", tag_rows)
        c.executemany("INSERT INTO work_tag(tid,wid,created) VALUES(?,?,?)", wt_rows)
        _set_meta(c, "tag_index_sig", index_signature(c))
        _set_meta(c, "tag_index_at", int(time.time()))
        _set_meta(c, "works_at", now)
        c.commit()
    except Exception:
        c.rollback()
        raise
    with _bucket_lock:
        _bucket_cache.update({"sig": None, "limit": 0, "items": []})
    print(f"[catalog] work {work_count(c)} 个 / 来源 {c.execute('SELECT COUNT(*) FROM work_source').fetchone()[0]} 条 /"
          f" 标签 {len(name2tid)} 个, 用时 {time.time() - t0:.1f}s", flush=True)
    return True


def ensure_tag_index(c, batch=20000):
    """倒排/work 过期就重建。只在内置索引导入之后和每轮爬取之后调用。"""
    sig = index_signature(c)
    if (_meta(c, "tag_index_sig") == sig and tag_count(c) > 0
            and work_count(c) > 0):
        return False
    return rebuild_works(c, batch)


# ---------------------------------------------------------------- 查询

def count(c):
    return c.execute("SELECT COUNT(*) FROM work").fetchone()[0]


def work_of(c, ident):
    """wid 或任意来源 sid -> wid。不是已知 id 时返回 None。"""
    ident = (ident or "").strip()
    if not ident:
        return None
    row = c.execute("SELECT wid FROM work_source WHERE sid=?", (ident,)).fetchone()
    if row:
        return row[0]
    row = c.execute("SELECT wid FROM work WHERE wid=?", (ident,)).fetchone()
    return row[0] if row else None


def sources_of(c, wids):
    """{wid: [{source,sid,eps,title}]}, 按来源优先级排。"""
    out = {}
    want = [w for w in dict.fromkeys(wids) if w]
    for i in range(0, len(want), 200):
        part = want[i:i + 200]
        marks = ",".join("?" * len(part))
        for wid, sid, source, eps, title in c.execute(
                f"""SELECT ws.wid, ws.sid, ws.source, ws.eps, s.title
                      FROM work_source ws JOIN series s ON s.sid = ws.sid
                     WHERE ws.wid IN ({marks})
                     ORDER BY ws.priority, ws.eps DESC, ws.sid""", part):
            out.setdefault(wid, []).append(
                {"source": source, "sid": sid, "eps": eps or 0, "title": title or ""})
    return out


_WORK_COLS = "wid,title,cover,intro,eps,tags,created,nsrc"
_WORK_COLS_W = "w.wid,w.title,w.cover,w.intro,w.eps,w.tags,w.created,w.nsrc"


def work_json(row, sources=None):
    """work 行 -> 统一条目。多来源时带 sources, 客户端据此做「换源」。"""
    d = {
        "id": row[0], "title": row[1], "cover": cover_url(row[2]),
        "intro": row[3] or "", "eps": row[4] or 0,
        "tags": tags_list(row[5]), "created": row[6] or 0,
        "source": (sources[0]["source"] if sources else "hg"),
    }
    if sources and len(sources) > 1:
        d["sources"] = sources
    return d


def work_items(c, rows):
    wids = [r[0] for r in rows]
    src = sources_of(c, wids)
    return [work_json(r, src.get(r[0])) for r in rows]


def tag_buckets(c, limit=TAG_BUCKETS_MAX):
    """[(tag, count)] 按数量降序、同数量按名字升序。结果带进程内缓存。"""
    sig = _meta(c, "tag_index_sig")
    with _bucket_lock:
        hit = _bucket_cache
        if hit["items"] and hit["sig"] == sig and hit["limit"] == limit:
            return hit["items"]
    n = max(1, min(int(limit or TAG_BUCKETS_MAX), TAG_BUCKETS_MAX))
    rows = c.execute(
        """SELECT t.name, count(*) AS n FROM work_tag wt
             JOIN tag t ON t.tid = wt.tid
            GROUP BY wt.tid ORDER BY n DESC, t.name ASC LIMIT ?""", (n,)).fetchall()
    items = [{"tag": r[0], "count": r[1]} for r in rows]
    with _bucket_lock:
        _bucket_cache.update({"sig": sig, "limit": limit, "items": items})
    return items


def tag_page(c, tag, offset=0, limit=DEFAULT_LIMIT):
    """按标签翻页, 以 work 为单位(同一部剧多来源只出现一次)。"""
    tag = (tag or "").strip()
    offset = max(0, int(offset or 0))
    limit = max(1, min(int(limit or DEFAULT_LIMIT), MAX_LIMIT))
    row = c.execute("SELECT tid FROM tag WHERE name=?", (tag,)).fetchone()
    if not row:
        return {"tag": tag, "total": 0, "items": [], "next": 0}
    tid = row[0]
    total = c.execute("SELECT COUNT(*) FROM work_tag WHERE tid=?", (tid,)).fetchone()[0]
    if offset >= total:
        return {"tag": tag, "total": total, "items": [], "next": total}
    rows = c.execute(
        f"""SELECT {_WORK_COLS_W} FROM work_tag wt JOIN work w ON w.wid = wt.wid
             WHERE wt.tid = ? ORDER BY wt.created DESC, wt.wid DESC
             LIMIT ? OFFSET ?""", (tid, limit, offset)).fetchall()
    items = work_items(c, rows)
    return {"tag": tag, "total": total, "items": items, "next": offset + len(items)}


def newest(c, offset=0, limit=DEFAULT_LIMIT):
    offset = max(0, int(offset or 0))
    limit = max(1, min(int(limit or DEFAULT_LIMIT), MAX_LIMIT))
    rows = c.execute(
        f"SELECT {_WORK_COLS} FROM work ORDER BY created DESC, wid DESC"
        " LIMIT ? OFFSET ?", (limit, offset)).fetchall()
    items = work_items(c, rows)
    return {"total": count(c), "items": items, "next": offset + len(items)}


def random_series(c, limit=20, exclude=()):
    """全库随机作品: 先随机 rowid, 再取该位置之后的第一行。"""
    limit = max(1, min(int(limit or 20), MAX_LIMIT))
    skip = {x for x in exclude if x}
    hi = c.execute("SELECT MAX(rowid) FROM work").fetchone()[0] or 0
    if hi <= 0:
        return []
    out = []
    seen = set(skip)
    attempts = 0
    while len(out) < limit and attempts < limit * 6:
        attempts += 1
        row = c.execute(
            f"SELECT {_WORK_COLS} FROM work WHERE rowid >= ? ORDER BY rowid LIMIT 1",
            (random.randint(1, hi),)).fetchone()
        if row is None:
            row = c.execute(
                f"SELECT {_WORK_COLS} FROM work ORDER BY rowid LIMIT 1").fetchone()
        if row is None or row[0] in seen:
            continue
        seen.add(row[0])
        out.append(row)
    items = work_items(c, out)
    return items


def search(c, q, offset=0, limit=30):
    """标题子串搜索(按 work 去重), 也认任意来源 sid 的精确命中。"""
    q = (q or "").strip()[:SEARCH_MAX_LEN]
    offset = max(0, int(offset or 0))
    limit = max(1, min(int(limit or 30), MAX_LIMIT))
    if not q:
        return {"q": "", "total": 0, "items": [], "next": 0}
    pat = "%" + q.translate(_LIKE_ESC) + "%"
    where = (r"WHERE (w.title LIKE ? ESCAPE '\' OR w.wid = ?"
             r" OR EXISTS(SELECT 1 FROM work_source ws"
             r"            WHERE ws.wid = w.wid AND ws.sid = ?))")
    total = c.execute("SELECT COUNT(*) FROM work w " + where,
                      (pat, q, q)).fetchone()[0]
    rows = c.execute(
        f"SELECT {_WORK_COLS_W} FROM work w " + where +
        " ORDER BY w.created DESC, w.wid DESC LIMIT ? OFFSET ?",
        (pat, q, q, limit, offset)).fetchall()
    items = work_items(c, rows)
    return {"q": q, "total": total, "items": items, "next": offset + len(items)}


def by_ids(c, ids, chunk=200):
    """按 id 批量取(既认 wid 也认来源 sid), 返回顺序跟着入参走。"""
    want = [str(x).strip() for x in ids if str(x).strip()]
    if not want:
        return []
    # 入参可能是 work id, 也可能是某来源的 sid; 统一解析成 wid
    resolved = []
    for i in range(0, len(want), chunk):
        part = want[i:i + chunk]
        marks = ",".join("?" * len(part))
        m = {sid: wid for sid, wid in c.execute(
            f"SELECT sid, wid FROM work_source WHERE sid IN ({marks})", part)}
        for ident in part:
            resolved.append(m.get(ident, ident))
    found = {}
    uniq = list(dict.fromkeys(resolved))
    for i in range(0, len(uniq), chunk):
        part = uniq[i:i + chunk]
        marks = ",".join("?" * len(part))
        for r in c.execute(
                f"SELECT {_WORK_COLS} FROM work WHERE wid IN ({marks})", part):
            found[r[0]] = r
    out, seen = [], set()
    for wid in resolved:
        if wid in found and wid not in seen:
            seen.add(wid)
            out.append(found[wid])
    return work_items(c, out)
