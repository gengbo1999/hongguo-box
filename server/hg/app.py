#!/usr/bin/env python3
"""短剧盒子服务端。

一个进程同时干四件事:
1. 索引服务: SQLite 里存全量剧集, 支持搜索/详情, 数据来自内置老索引 + 站点定时爬取
2. 上游代理: /resolve 把客户端的签名请求转给常驻 unidbg 签名进程
3. 媒体代理: /api/media 直出播放地址(带 Range), 客户端不用再自己处理
4. 健康检查: /healthz

只用标准库, 方便在 alpine 里跑。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import struct
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import upstream

DB_PATH = os.environ.get("HG_DB", "/data/hongguo.db")
SEED_INDEX = os.environ.get("HG_SEED_INDEX", "/data/index.bin.z")
SITE = os.environ.get("HG_SITE", "https://hongguoduanju.com").rstrip("/")
ADMIN_TOKEN = os.environ.get("HG_ADMIN_TOKEN", "")
REFRESH_SEC = int(os.environ.get("HG_REFRESH_SEC", "0"))
CATEGORIES = [("real-drama", "真人剧"), ("comic-drama", "漫剧"),
              ("ai-drama", "AI剧"), ("comic", "漫画")]
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/17.0 Safari/605.1.15")

_db_lock = threading.Lock()
_conn = None


# ---------------------------------------------------------------- 数据库

def conn():
    global _conn
    with _db_lock:
        if _conn is None:
            os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
            _conn = sqlite3.connect(DB_PATH, check_same_thread=False)
            _conn.row_factory = sqlite3.Row
            _conn.execute("PRAGMA journal_mode=WAL")
            _conn.execute("PRAGMA synchronous=NORMAL")
            _conn.execute(
                """CREATE TABLE IF NOT EXISTS series(
                    sid TEXT PRIMARY KEY, title TEXT NOT NULL, cover TEXT DEFAULT '',
                    intro TEXT DEFAULT '', eps INTEGER DEFAULT 0, tags TEXT DEFAULT '',
                    vids TEXT DEFAULT '', created INTEGER DEFAULT 0,
                    accessed INTEGER DEFAULT 0, updated INTEGER DEFAULT 0)"""
            )
            _conn.execute("CREATE INDEX IF NOT EXISTS ix_title ON series(title)")
            _conn.execute("CREATE INDEX IF NOT EXISTS ix_created ON series(created)")
            _conn.commit()
        return _conn


def db_meta(k, default=None):
    c = conn()
    c.execute("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")
    row = c.execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone()
    return row["v"] if row else default


def db_set_meta(k, v):
    c = conn()
    c.execute("INSERT INTO meta(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",
              (k, str(v)))
    c.commit()


def upsert_many(rows):
    """rows: (sid,title,cover,intro,eps,tags,vids,created)"""
    c = conn()
    now = int(time.time())
    c.executemany(
        """INSERT INTO series(sid,title,cover,intro,eps,tags,vids,created,updated)
           VALUES(?,?,?,?,?,?,?,?,?)
           ON CONFLICT(sid) DO UPDATE SET
             title=excluded.title,
             cover=CASE WHEN excluded.cover<>'' THEN excluded.cover ELSE series.cover END,
             intro=CASE WHEN excluded.intro<>'' THEN excluded.intro ELSE series.intro END,
             eps=CASE WHEN excluded.eps>0 THEN excluded.eps ELSE series.eps END,
             tags=CASE WHEN excluded.tags<>'' THEN excluded.tags ELSE series.tags END,
             vids=CASE WHEN excluded.vids<>'' THEN excluded.vids ELSE series.vids END,
             created=CASE WHEN excluded.created>0 THEN excluded.created ELSE series.created END,
             updated=excluded.updated""",
        [(r[0], r[1], r[2] or "", r[3] or "", r[4] or 0, r[5] or "", r[6] or "",
          r[7] or 0, now) for r in rows if r[0] and r[1]],
    )
    c.commit()


def count_series():
    return conn().execute("SELECT COUNT(*) n FROM series").fetchone()["n"]


# ------------------------------------------------------- 老索引导入(一次性)

def load_legacy_index(path):
    """解析客户端老版本的 index.bin.z, 产出 (sid,title,cover,eps,tags,created)。"""
    with open(path, "rb") as f:
        raw = f.read()
    if len(raw) < 8:
        raise ValueError("索引文件太短")
    size = struct.unpack_from("<Q", raw, 0)[0]
    # 体是 raw deflate(没有 zlib/gzip 头), 必须用 -15 解
    body = zlib.decompressobj(-15).decompress(raw[8:])
    if len(body) != size:
        raise ValueError(f"解压长度不符: {len(body)} != {size}")
    if body[:4] != b"DJIX":
        raise ValueError(f"magic 不对: {body[:4]!r}")
    off = 4
    version, count, tag_count = struct.unpack_from("<III", body, off)
    off += 12
    tags = []
    for _ in range(tag_count):
        n = struct.unpack_from("<H", body, off)[0]
        off += 2
        tags.append(body[off:off + n].decode("utf-8", "replace"))
        off += n
    off = (off + 7) & ~7
    title_off = struct.unpack_from(f"<{count + 1}I", body, off)
    off += 4 * (count + 1)
    blob_len = title_off[count]
    blob = body[off:off + blob_len]
    off += blob_len
    ids = struct.unpack_from(f"<{count}Q", body, off)
    off += 8 * count
    covers = body[off:off + 16 * count]
    off += 16 * count
    eps = struct.unpack_from(f"<{count}H", body, off)
    off += 2 * count
    tag_counts = body[off:off + count]
    off += count
    total_refs = sum(tag_counts)
    tag_refs = struct.unpack_from(f"<{total_refs}H", body, off) if total_refs else ()
    off += 2 * total_refs
    created = ()
    if version >= 2 and off + 4 * count <= len(body):
        created = struct.unpack_from(f"<{count}I", body, off)

    ref = 0
    for i in range(count):
        start, end = title_off[i], title_off[i + 1]
        title = blob[start:end].decode("utf-8", "replace")
        my = tag_counts[i]
        names = [tags[t] for t in tag_refs[ref:ref + my] if t < len(tags)]
        ref += my
        cov = covers[i * 16:(i + 1) * 16].hex()
        yield (str(ids[i]), title, cov, eps[i], ",".join(names),
               created[i] if i < len(created) else 0)


def seed_from_legacy():
    if db_meta("seeded"):
        return
    if not os.path.exists(SEED_INDEX):
        print(f"[seed] 没有内置索引 {SEED_INDEX}, 跳过", flush=True)
        db_set_meta("seeded", "none")
        return
    t0 = time.time()
    batch = []
    n = 0
    for sid, title, cov, ep, tags, created in load_legacy_index(SEED_INDEX):
        batch.append((sid, title, cov, "", ep, tags, "", created))
        n += 1
        if len(batch) >= 5000:
            upsert_many(batch)
            batch.clear()
    if batch:
        upsert_many(batch)
    db_set_meta("seeded", f"{n}@{int(time.time())}")
    print(f"[seed] 载入 {n} 条, 用时 {time.time() - t0:.1f}s", flush=True)


# ------------------------------------------------------------- 站点抓取

def http_text(url, timeout=20, data=None, headers=None):
    h = {"User-Agent": UA, "Accept": "text/html,application/json,*/*",
         "Accept-Language": "zh-CN,zh;q=0.9"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=data, headers=h, method="POST" if data else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def router_json(html):
    """从 SSR HTML 里抠出 _ROUTER_DATA 的 JSON(大括号配对, 跳过字符串)。"""
    i = html.find("_ROUTER_DATA")
    if i < 0:
        return None
    i = html.find("{", i)
    if i < 0:
        return None
    depth = 0
    in_str = False
    esc = False
    start = i
    while i < len(html):
        c = html[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(html[start:i + 1])
                except ValueError:
                    return None
        i += 1
    return None


def _s(v):
    if isinstance(v, str):
        return v
    if isinstance(v, (int, float)):
        return str(v)
    return ""


def _i(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0


def series_row(d):
    tags = d.get("tags")
    tag_names = [_s(t) for t in tags] if isinstance(tags, list) else []
    return (
        _s(d.get("series_id")),
        _s(d.get("series_name")) or _s(d.get("series_title")),
        _s(d.get("series_cover")),
        _s(d.get("series_intro")),
        _i(d.get("episode_cnt")),
        ",".join([t for t in tag_names if t]),
        "",
        0,
    )


def crawl_category(slug, max_pages=8, budget=None):
    """按分类抓列表。返回新增/更新条数。"""
    total = 0
    dead = 0
    for page in range(1, max_pages + 1):
        url = f"{SITE}/category/{slug}" + (f"?page={page}" if page > 1 else "")
        try:
            j = router_json(http_text(url))
        except Exception as e:  # noqa: BLE001
            print(f"[crawl] {slug} p{page} 失败 {e!r}", flush=True)
            dead += 1
            if dead >= 2:
                break
            continue
        if not j:
            dead += 1
            if dead >= 2:
                break
            continue
        ld = j.get("loaderData") or {}
        rows = []
        for v in ld.values():
            rec = v.get("recommendList") if isinstance(v, dict) else None
            if isinstance(rec, list) and rec:
                rows = [series_row(x) for x in rec if isinstance(x, dict)]
                break
        if not rows:
            break
        upsert_many(rows)
        total += len(rows)
        if budget and time.time() > budget:
            break
    return total


def crawl_home():
    try:
        j = router_json(http_text(SITE + "/"))
    except Exception as e:  # noqa: BLE001
        print(f"[crawl] 首页失败 {e!r}", flush=True)
        return 0
    if not j:
        return 0
    page = (j.get("loaderData") or {}).get("page") or {}
    rows = []
    secs = page.get("homeSections") if isinstance(page, dict) else None
    for sec in (secs or []):
        for it in (sec.get("video_list") or []) if isinstance(sec, dict) else []:
            if isinstance(it, dict):
                rows.append(series_row(it))
    if rows:
        upsert_many(rows)
    return len(rows)


def refresh(budget_sec=120):
    t0 = time.time()
    budget = t0 + budget_sec
    n = crawl_home()
    for slug, _ in CATEGORIES:
        if time.time() > budget:
            break
        n += crawl_category(slug, max_pages=10, budget=budget)
    db_set_meta("refreshed", int(time.time()))
    db_set_meta("refresh_rows", n)
    print(f"[crawl] 本轮 {n} 条, 用时 {time.time() - t0:.1f}s, 库存 {count_series()}", flush=True)
    return n


def refresh_loop():
    while True:
        time.sleep(REFRESH_SEC)
        try:
            refresh()
        except Exception as e:  # noqa: BLE001
            print(f"[crawl] 异常 {e!r}", flush=True)


def fetch_detail(sid):
    j = router_json(http_text(f"{SITE}/detail?series_id={urllib.parse.quote(sid)}"))
    if not j:
        return None, []
    ld = j.get("loaderData") or {}
    dp = ld.get("detail_page") or {}
    sd = dp.get("seriesDetail") if isinstance(dp, dict) else None
    if not isinstance(sd, dict):
        return None, []
    row = series_row(sd)
    vids = [_s(v) for v in (sd.get("vid_list") or []) if _s(v)]
    if vids:
        upsert_many([(row[0], row[1], row[2], row[3], row[4] or len(vids),
                      row[5], ",".join(vids), row[7])])
    return row, vids


# ---------------------------------------------------------------- HTTP

def jdump(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "hongguo/1.0"

    def log_message(self, fmt, *args):  # 安静点
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, (dict, list)):
            body = jdump(body)
        elif isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.send_header("cache-control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json_body(self):
        n = int(self.headers.get("content-length") or 0)
        if n <= 0 or n > 4 * 1024 * 1024:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode())
        except ValueError:
            return {}

    # -------------------------------------------------------- GET
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(u.query)
        p = u.path.rstrip("/") or "/"

        if p in ("/healthz", "/"):
            return self._send(200, {
                "ok": True, "service": "hongguo-box", "version": "1.0.0",
                "series": count_series(), "seeded": db_meta("seeded"),
                "refreshed": db_meta("refreshed"), "signer": upstream.signer_available(),
            })

        if p == "/api/nav":
            return self._send(200, {"ok": True, "categories": [
                {"slug": s, "name": n} for s, n in CATEGORIES]})

        if p == "/api/search":
            q = (qs.get("q") or [""])[0].strip()
            try:
                limit = min(max(int((qs.get("limit") or ["30"])[0]), 1), 100)
                offset = max(int((qs.get("offset") or ["0"])[0]), 0)
            except ValueError:
                limit, offset = 30, 0
            if not q:
                return self._send(200, {"ok": True, "total": 0, "items": []})
            like = f"%{q}%"
            c = conn()
            rows = c.execute(
                """SELECT sid,title,cover,eps,tags,created FROM series
                   WHERE title LIKE ? OR sid=? ORDER BY created DESC LIMIT ? OFFSET ?""",
                (like, q, limit, offset)).fetchall()
            total = c.execute("SELECT COUNT(*) n FROM series WHERE title LIKE ?",
                              (like,)).fetchone()["n"]
            return self._send(200, {"ok": True, "total": total, "items": [
                {"id": r["sid"], "title": r["title"], "cover": r["cover"],
                 "eps": r["eps"], "tags": [t for t in r["tags"].split(",") if t]}
                for r in rows]})

        if p == "/api/detail":
            sid = (qs.get("sid") or [""])[0].strip()
            if not sid:
                return self._send(400, {"ok": False, "error": "missing_sid"})
            row = conn().execute("SELECT * FROM series WHERE sid=?", (sid,)).fetchone()
            vids = [v for v in (row["vids"] or "").split(",") if v] if row else []
            if not vids:
                d, vids = fetch_detail(sid)
                if d and not row:
                    row = conn().execute("SELECT * FROM series WHERE sid=?", (sid,)).fetchone()
            if not row:
                return self._send(404, {"ok": False, "error": "not_found"})
            return self._send(200, {"ok": True, "series": {
                "id": row["sid"], "title": row["title"], "cover": row["cover"],
                "intro": row["intro"], "eps": row["eps"] or len(vids),
                "tags": [t for t in (row["tags"] or "").split(",") if t],
            }, "episodes": [{"index": i + 1, "vid": v} for i, v in enumerate(vids)]})

        if p == "/api/tracks":
            vid = (qs.get("vid") or [""])[0].strip()
            if not re.fullmatch(r"[0-9]{8,24}", vid or ""):
                return self._send(400, {"ok": False, "error": "bad_vid"})
            try:
                tracks, diag = upstream.resolve_tracks(vid)
            except upstream.UpstreamError as e:
                return self._send(502, {"ok": False, "error": e.code, "detail": e.detail})
            best = upstream.pick_best(tracks)
            return self._send(200, {"ok": bool(best), "best": best,
                                    "tracks": tracks, "diag": diag})

        if p == "/api/media":
            src = (qs.get("u") or [""])[0]
            if not src.startswith(("http://", "https://")):
                return self._send(400, {"ok": False, "error": "bad_url"})
            return self._proxy_media(src)

        return self._send(404, {"ok": False, "error": "not_found"})

    # ------------------------------------------------------- POST
    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        p = u.path.rstrip("/")
        body = self._json_body()

        if p == "/resolve":
            return self._resolve(body)

        if p == "/api/refresh":
            if ADMIN_TOKEN and body.get("token") != ADMIN_TOKEN:
                return self._send(403, {"ok": False, "error": "forbidden"})
            n = refresh(int(body.get("budget") or 120))
            return self._send(200, {"ok": True, "rows": n, "series": count_series()})

        return self._send(404, {"ok": False, "error": "not_found"})

    # ---------------------------------------------------- 上游代理
    def _resolve(self, body):
        """兼容客户端 RemoteResolver: 客户端给 host/path/method/body, 服务端签名后转发。"""
        host = str(body.get("host") or "").strip().rstrip("/")
        path = str(body.get("path") or "").strip()
        want = (host, path)
        allow = os.environ.get("HG_ALLOW_HOSTS", "api5-normal-sinfonlineb.fqnovel.com,"
                                                  "api5-normal-sinfonlinec.fqnovel.com,"
                                                  "api5-normal-sinfonlinea.fqnovel.com")
        allowed = {h.strip() for h in allow.split(",") if h.strip()}
        u = urllib.parse.urlparse(host)
        if u.scheme not in ("http", "https") or u.hostname not in allowed:
            return self._send(403, {"ok": False, "error": "host_not_allowed", "got": want})
        if not path.startswith("/"):
            return self._send(400, {"ok": False, "error": "bad_path"})

        query = body.get("query") if isinstance(body.get("query"), dict) else {}
        payload = body.get("body")
        method = str(body.get("method") or "POST").upper()
        try:
            if method == "GET":
                url = upstream.build_url(host, path, query)
                req = urllib.request.Request(url, headers={
                    "user-agent": upstream.current_device()["user_agent"],
                    "accept": "application/json"})
                with urllib.request.urlopen(req, timeout=20) as r:
                    raw = r.read()
            else:
                data = json.dumps(payload if payload is not None else {},
                                  ensure_ascii=False, separators=(",", ":")).encode()
                extra = dict(query)
                if "video_platform" in (payload or {}).get("biz_param", {}):
                    pass
                got = upstream.post(path, payload if payload is not None else {},
                                    extra_query=extra, host=host)
                return self._send(200, {"ok": True, "data": got})
        except upstream.UpstreamError as e:
            return self._send(502, {"ok": False, "error": e.code, "detail": e.detail})
        except Exception as e:  # noqa: BLE001
            return self._send(502, {"ok": False, "error": "upstream_failed",
                                    "detail": repr(e)[:200]})

        if not raw:
            return self._send(502, {"ok": False, "error": "upstream_empty"})
        try:
            return self._send(200, {"ok": True, "data": json.loads(raw.decode())})
        except ValueError:
            return self._send(502, {"ok": False, "error": "upstream_bad_json"})

    # ---------------------------------------------------- 媒体转发
    def _proxy_media(self, src):
        rng = self.headers.get("range")
        h = {"User-Agent": UA, "Referer": SITE + "/"}
        if rng:
            h["Range"] = rng
        req = urllib.request.Request(src, headers=h)
        try:
            r = urllib.request.urlopen(req, timeout=30)
        except urllib.error.HTTPError as e:
            return self._send(e.code, {"ok": False, "error": f"upstream_{e.code}"})
        except Exception as e:  # noqa: BLE001
            return self._send(502, {"ok": False, "error": "fetch_failed",
                                    "detail": repr(e)[:120]})
        with r:
            self.send_response(r.status)
            self.send_header("content-type", r.headers.get("content-type") or "video/mp4")
            for k in ("content-length", "content-range", "accept-ranges"):
                v = r.headers.get(k)
                if v:
                    self.send_header(k, v)
            self.send_header("cache-control", "public, max-age=3600")
            self.end_headers()
            try:
                while True:
                    chunk = r.read(256 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass


def main():
    conn()
    if os.environ.get("HG_SEED", "1") != "0":
        try:
            seed_from_legacy()
        except Exception as e:  # noqa: BLE001
            print(f"[seed] 失败 {e!r}", flush=True)
    port = int(os.environ.get("PORT", "8787"))
    if REFRESH_SEC > 0:
        threading.Thread(target=refresh_loop, daemon=True).start()
        print(f"[crawl] 每 {REFRESH_SEC}s 刷新一次", flush=True)
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"[http] 监听 :{port}, 库存 {count_series()} 条", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "seed":
        conn()
        seed_from_legacy()
        print("seeded", count_series())
    elif len(sys.argv) > 1 and sys.argv[1] == "refresh":
        conn()
        refresh()
    else:
        main()