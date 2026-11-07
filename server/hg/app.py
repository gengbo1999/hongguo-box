#!/usr/bin/env python3
"""短剧盒子服务端。

一个进程同时干四件事:
1. 索引 + 目录: SQLite 里存全量剧集, 标签云/标签翻页/最新/随机/搜索/详情全在这里算,
   数据来自内置老索引 + 站点定时爬取(查询部分见 catalog.py)
2. 上游代理: /resolve 把客户端的签名请求转给常驻 unidbg 签名进程
3. 只做 API: 不代理媒体字节, 播放地址发给客户端自己拉
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

import catalog
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

# RLock: /healthz 会在持锁区间里再调 conn(), 可重入才不会自锁
_db_lock = threading.RLock()
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
            catalog.ensure_schema(_conn)
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


def rebuild_catalog_index():
    """标签倒排按需重建。用独立连接: 重建是长写事务, 别和请求线程共用一个连接。"""
    c = sqlite3.connect(DB_PATH, timeout=60)
    c.row_factory = sqlite3.Row
    try:
        c.execute("PRAGMA journal_mode=WAL")
        catalog.ensure_schema(c)
        return catalog.ensure_tag_index(c)
    finally:
        c.close()


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
    # 只有真的导入过才跳过。"none" 表示上次启动时种子还不存在,
    # 之后种子补进 PVC 时必须重新尝试, 否则空库会被一个 none 永久钉住。
    seeded = db_meta("seeded")
    if seeded and seeded != "none":
        return
    if not os.path.exists(SEED_INDEX):
        print(f"[seed] 没有内置索引 {SEED_INDEX}, 跳过", flush=True)
        if not seeded:
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
        catalog.cover_hash(_s(d.get("series_cover"))),
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
    try:
        rebuild_catalog_index()
    except Exception as e:  # noqa: BLE001
        print(f"[catalog] 标签倒排重建失败 {e!r}", flush=True)
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


def _clamp_int(values, default, lo, hi):
    try:
        v = int((values or [""])[0])
    except (TypeError, ValueError):
        v = default
    return max(lo, min(v, hi))


def _page(qs, default_limit=catalog.DEFAULT_LIMIT):
    return (_clamp_int(qs.get("offset"), 0, 0, 10 ** 9),
            _clamp_int(qs.get("limit"), default_limit, 1, catalog.MAX_LIMIT))


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
            # 多个探针/客户端会同时打这里, 全局只有一个 _conn, 不加锁会撞出
            # sqlite3.InterfaceError: bad parameter or other API misuse
            with _db_lock:
                body = {
                    "ok": True, "service": "hongguo-box", "version": "1.0.0",
                    "series": count_series(), "tags": catalog.tag_count(conn()),
                    "seeded": db_meta("seeded"), "refreshed": db_meta("refreshed"),
                    "catalog_index_at": db_meta("tag_index_at"),
                }
            body["signer"] = upstream.signer_available()
            return self._send(200, body)

        if p == "/api/nav":
            return self._send(200, {"ok": True, "categories": [
                {"slug": s, "name": n} for s, n in CATEGORIES]})

        if p == "/api/search":
            q = (qs.get("q") or [""])[0].strip()
            off, lim = _page(qs, default_limit=30)
            r = catalog.search(conn(), q, offset=off, limit=lim)
            return self._send(200, {"ok": True, **r})

        if p == "/api/detail":
            sid = (qs.get("sid") or [""])[0].strip()
            if not sid:
                return self._send(400, {"ok": False, "error": "missing_sid"})
            sql = ("SELECT sid,title,cover,intro,eps,tags,created,vids"
                   " FROM series WHERE sid=?")
            row = conn().execute(sql, (sid,)).fetchone()
            vids = [v for v in (row[7] or "").split(",") if v] if row else []
            if not vids:
                d, vids = fetch_detail(sid)
                if d and not row:
                    row = conn().execute(sql, (sid,)).fetchone()
                    vids = [v for v in (row[7] or "").split(",") if v] if row else vids
            if not row:
                return self._send(404, {"ok": False, "error": "not_found"})
            series = catalog.series_json(row)
            series["eps"] = series["eps"] or len(vids)
            return self._send(200, {"ok": True, "series": series,
                                    "episodes": [{"index": i + 1, "vid": v}
                                                 for i, v in enumerate(vids)]})

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

        # ---- 目录层: 客户端原本读内置 index.bin.z, 现在全部走这里
        if p == "/api/tags":
            lim = _clamp_int(qs.get("limit"), catalog.TAG_BUCKETS_MAX,
                             1, catalog.TAG_BUCKETS_MAX)
            items = catalog.tag_buckets(conn(), lim)
            return self._send(200, {"ok": True, "count": len(items), "items": items})

        if p == "/api/tag":
            tag = (qs.get("tag") or [""])[0].strip()
            if not tag:
                return self._send(400, {"ok": False, "error": "tag_required"})
            off, lim = _page(qs)
            r = catalog.tag_page(conn(), tag, offset=off, limit=lim)
            return self._send(200, {"ok": True, **r})

        if p == "/api/newest":
            off, lim = _page(qs)
            r = catalog.newest(conn(), offset=off, limit=lim)
            return self._send(200, {"ok": True, **r})

        if p == "/api/random":
            lim = _clamp_int(qs.get("limit"), 20, 1, catalog.MAX_LIMIT)
            skip = [x for x in (qs.get("exclude") or [""])[0].split(",") if x]
            return self._send(200, {"ok": True,
                                    "items": catalog.random_series(conn(), lim, skip)})

        if p == "/api/series":
            ids = [x for x in (qs.get("ids") or [""])[0].split(",") if x.strip()]
            if not ids:
                return self._send(400, {"ok": False, "error": "ids_required"})
            if len(ids) > 200:
                return self._send(400, {"ok": False, "error": "too_many_ids"})
            return self._send(200, {"ok": True, "items": catalog.by_ids(conn(), ids)})

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
    @staticmethod
    def _wanted_vids(payload):
        """尽力从上游请求体/查询串里取出本次查询的 vid。"""
        ids = []
        if not isinstance(payload, dict):
            return ids
        for key in ("video_id", "vid"):
            v = payload.get(key)
            if isinstance(v, (str, int)) and str(v):
                ids.append(str(v))
        m = payload.get("mixed_video_id_map")
        if isinstance(m, dict):
            for lst in m.values():
                if isinstance(lst, list):
                    ids.extend(str(x) for x in lst if x)
        return ids

    @staticmethod
    def _as_video_model(v):
        """video_model 可能是 dict, 也可能是 JSON 字符串; 统一成 dict。"""
        if isinstance(v, dict):
            return v
        if isinstance(v, str) and v.lstrip().startswith("{"):
            try:
                d = json.loads(v)
            except ValueError:
                return None
            return d if isinstance(d, dict) else None
        return None

    def _find_video_model(self, obj, prefer, depth=0):
        if depth > 3 or not isinstance(obj, dict):
            return None
        hit = self._as_video_model(obj.get("video_model"))
        if hit is not None:
            return hit
        children = {k: v for k, v in obj.items() if isinstance(v, dict)}
        for vid in prefer:  # 先按请求里点名的 vid 找
            if vid in children:
                hit = self._find_video_model(children[vid], prefer, depth + 1)
                if hit is not None:
                    return hit
        for v in children.values():
            hit = self._find_video_model(v, prefer, depth + 1)
            if hit is not None:
                return hit
        return None

    def _normalize_video_model(self, got, payload=None):
        """把上游埋在 `data.<vid>.video_model` 里的内容提到顶层。

        客户端 RemoteResolver.parseTracks 只认顶层 video_model(dict) 或
        video_list(list); 而上游 multi_video_model 把它们编码成 JSON 字符串
        塞在 `data.<vid>.video_model` 里, 导致网关路径解析不到任何档位。
        这里只做加法: 原有字段一律不动, 额外补 video_model / video_list。
        """
        if not isinstance(got, dict):
            return got
        if isinstance(got.get("video_model"), dict) or isinstance(got.get("video_list"), list):
            return got  # 已经是客户端能吃的形状
        model = self._find_video_model(got, self._wanted_vids(payload))
        if model is None:
            return got
        out = dict(got)
        out["video_model"] = model
        vl = model.get("video_list")
        out["video_list"] = vl if isinstance(vl, list) else []
        return out

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

        # 取流接口走纯 JS 签名客户端：unidbg 对 multi_video_model 会被判
        # 110001，JS 实现配已注册设备可稳定返回 1080p。其余接口保持原样。
        if path.startswith(("/novel/player/multi_video_model/",
                            "/novel/player/video_model/")):
            vids = self._wanted_vids(payload)
            if vids:
                try:
                    got = upstream.js_video_model(vids[0])
                    got = self._normalize_video_model(got, payload)
                    return self._send(200, {"ok": True, "data": got})
                except upstream.UpstreamError as e:
                    return self._send(502, {"ok": False, "error": e.code,
                                            "detail": e.detail})
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
                got = upstream.post(path, payload if payload is not None else {},
                                    extra_query=dict(query), host=host)
                got = self._normalize_video_model(got, payload)
                return self._send(200, {"ok": True, "data": got})
        except upstream.UpstreamError as e:
            return self._send(502, {"ok": False, "error": e.code, "detail": e.detail})
        except Exception as e:  # noqa: BLE001
            return self._send(502, {"ok": False, "error": "upstream_failed",
                                    "detail": repr(e)[:200]})

        if not raw:
            return self._send(502, {"ok": False, "error": "upstream_empty"})
        try:
            got = self._normalize_video_model(json.loads(raw.decode()), query)
            return self._send(200, {"ok": True, "data": got})
        except ValueError:
            return self._send(502, {"ok": False, "error": "upstream_bad_json"})

    # 媒体不经过服务端: 客户端拿 /api/tracks 给的地址自己拉流并解密。


def main():
    conn()
    if os.environ.get("HG_SEED", "1") != "0":
        try:
            seed_from_legacy()
        except Exception as e:  # noqa: BLE001
            print(f"[seed] 失败 {e!r}", flush=True)
    try:
        rebuild_catalog_index()
    except Exception as e:  # noqa: BLE001
        print(f"[catalog] 标签倒排重建失败 {e!r}", flush=True)
    # PORT 可能是空串(环境里显式给了空值), int("") 会直接把进程带走, 兜回默认端口
    try:
        port = int((os.environ.get("PORT") or "").strip() or "8787")
    except ValueError:
        port = 8787
    if REFRESH_SEC > 0:
        threading.Thread(target=refresh_loop, daemon=True).start()
        print(f"[crawl] 每 {REFRESH_SEC}s 刷新一次", flush=True)
    class Server(ThreadingHTTPServer):
        # 默认 listen backlog 只有 5。k8s 探针 + 客户端并发打进来时会直接丢连接
        # (实测 64 并发丢 15 条, 表现为 connection reset), 抬高一点。
        request_queue_size = 128
        daemon_threads = True

    srv = Server(("0.0.0.0", port), Handler)
    print(f"[http] 监听 :{port}, 库存 {count_series()} 条", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "seed":
        conn()
        seed_from_legacy()
        rebuild_catalog_index()
        print("seeded", count_series(), "tags", catalog.tag_count(conn()))
    elif len(sys.argv) > 1 and sys.argv[1] == "refresh":
        conn()
        refresh()
    else:
        main()