#!/usr/bin/env python3
"""抖音短剧上游（adapter）。

和 upstream.py（番茄/红果）并列的第二路上游。三个接口都**不需要 a_bogus**，
服务端也不需要浏览器：裸 GET /series 就会下发 ttwid + UIFID_TEMP，够用。

    detail(sid)      单剧元数据   /aweme/v1/web/series/detail/   （连 cookie 都不需要）
    episodes(sid)    剧集列表     /aweme/v1/web/series/aweme/    （要 cookie）
    feed(offset)     目录枚举     /aweme/v1/web/series/card/feed/（要 cookie）

已知不可用：search / aweme/post 需要 a_bogus（线上 webmssdk 1.0.0.20）；
/series/<id> 网页路由 404；网页内整剧播放要登录（接口层不校验）。

对外 id 一律带 `dy:` 前缀（见 catalog 的 source 列），避免和红果 19 位 sid 撞键。
"""

from __future__ import annotations

import http.cookiejar
import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://www.douyin.com"
UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
)
COMMON = (
    "device_platform=webapp&aid=6383&channel=channel_pc_web&pc_client_type=1"
    "&version_code=170400&version_name=17.4.0&cookie_enabled=true&platform=PC"
    "&browser_language=zh-CN&browser_platform=MacIntel&browser_name=Chrome"
    "&browser_version=124.0.0.0&browser_online=true&engine_name=Blink"
    "&engine_version=124.0.0.0&os_name=Mac%20OS&os_version=10.15.7"
)
PREFIX = "dy:"

_cookie_lock = threading.Lock()
_cookie = {"v": "", "at": 0.0}
_COOKIE_TTL = 1800  # UIFID_TEMP 寿命未知，半小时重取一次比猜便宜


class DouyinError(RuntimeError):
    pass


def strip_prefix(sid):
    s = (sid or "").strip()
    return s[len(PREFIX):] if s.startswith(PREFIX) else s


def is_dy(sid):
    return (sid or "").startswith(PREFIX)


# ------------------------------------------------------------------ HTTP

def _open(url, cookie, referer, accept):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Cookie": cookie or "",
        "Referer": referer,
        "Accept": accept,
        "Accept-Language": "zh-CN,zh;q=0.9",
        # urllib 默认带 gzip，抖音对这套头回 403/412；identity 才给正文
        "Accept-Encoding": "identity",
    })
    return urllib.request.urlopen(req, timeout=25)


def _get(path, cookie, params="", referer=BASE + "/series"):
    url = f"{BASE}{path}" + (("&" if "?" in path else "?") + params if params else "")
    with _open(url, cookie, referer, "text/html,application/json,*/*;q=0.8") as r:
        return r.read()


def _json(path, cookie, params="", referer=BASE + "/series"):
    raw = _get(path, cookie, params, referer)
    if raw[:1] != b"{":
        raise DouyinError(f"{path} 非 JSON（{len(raw)}B）：{raw[:40]!r}")
    return json.loads(raw)


def cookie(force=False):
    """自举 cookie：GET /series 的 Set-Cookie 里就有 ttwid + UIFID_TEMP。"""
    with _cookie_lock:
        if not force and _cookie["v"] and time.time() - _cookie["at"] < _COOKIE_TTL:
            return _cookie["v"]
        cj = http.cookiejar.CookieJar()
        op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
        req = urllib.request.Request(BASE + "/series", headers={
            "User-Agent": UA, "Accept": "text/html", "Accept-Encoding": "identity"})
        with op.open(req, timeout=25) as r:
            r.read()
        val = "; ".join(f"{c.name}={c.value}" for c in cj)
        if not val:
            raise DouyinError("cookie 自举失败：Set-Cookie 为空")
        _cookie.update(v=val, at=time.time())
        return val


def _call(path, params, referer=BASE + "/series"):
    """带一次 cookie 失效重试。"""
    try:
        return _json(path, cookie(), params, referer)
    except (DouyinError, urllib.error.HTTPError, urllib.error.URLError):
        return _json(path, cookie(force=True), params, referer)


# ------------------------------------------------------------------ 三个接口

def detail(sid):
    """单剧元数据 -> 统一形状（字段对齐 catalog 的 series_row）。"""
    sid = strip_prefix(sid)
    d = _call("/aweme/v1/web/series/detail/",
              f"{COMMON}&series_id={sid}&req_from=channel")
    si = d.get("series_info") or {}
    stats = si.get("stats") or {}
    extra = si.get("extra")
    if isinstance(extra, str):
        try:
            extra = json.loads(extra)
        except ValueError:
            extra = {}
    extra = extra if isinstance(extra, dict) else {}
    tag = extra.get("compass_playlet_tag") or {}
    tags = []
    for c in (si.get("series_content_types_new") or []):
        n = (c or {}).get("name")
        if n and n not in tags:
            tags.append(n)
    for v in (tag.get("tags") or tag.values()) if isinstance(tag, dict) else []:
        if isinstance(v, str) and v and v not in tags:
            tags.append(v)
    cover = ((si.get("cover_url") or {}).get("url_list") or [""])[0]
    name = (si.get("series_name") or "").replace("短剧 · ", "", 1)
    return {
        "sid": str(si.get("series_id") or sid),
        "name": name,
        "real_name": (si.get("real_name") or "").replace("短剧 · ", "", 1),
        "desc": si.get("desc") or "",
        "eps": stats.get("total_episode") or 0,
        "updated_to": stats.get("updated_to_episode") or 0,
        "author": (si.get("author") or {}).get("nickname") or "",
        "charge": si.get("is_charge_series"),
        "iaa": si.get("is_iaa"),
        "price": si.get("series_price") or 0,
        "cover": cover,
        "tags": tags,
        "created": si.get("create_time") or 0,
        "fanqie": extra.get("fanqie_publish_album_id"),
        "cp_id": extra.get("cp_center_content_id"),
    }


def _video_of(item):
    v = item.get("video") or {}
    return {
        "duration_ms": v.get("duration") or 0,
        "width": v.get("width") or 0,
        "height": v.get("height") or 0,
        "cover": ((v.get("cover") or {}).get("url_list") or [""])[0],
        "play": (v.get("play_addr") or {}).get("url_list") or [],
        "play_h264": (v.get("play_addr_h264") or {}).get("url_list") or [],
        "bit_rate": [{
            "gear": b.get("gear_name"),
            "bit_rate": b.get("bit_rate"),
            "w": (b.get("play_addr") or {}).get("width"),
            "h": (b.get("play_addr") or {}).get("height"),
            "urls": (b.get("play_addr") or {}).get("url_list") or [],
        } for b in (v.get("bit_rate") or [])],
    }


def episodes(sid, max_episodes=500):
    """按 cursor/max_cursor 翻完整部剧。"""
    sid = strip_prefix(sid)
    out, seen, cursor = [], set(), 0
    while len(out) < max_episodes:
        d = _call("/aweme/v1/web/series/aweme/",
                  f"{COMMON}&series_id={sid}&pull_type=2&cursor={cursor}&count=100")
        lst = d.get("aweme_list") or []
        if not lst:
            break
        for it in lst:
            aid = str(it.get("aweme_id") or "")
            if not aid or aid in seen:
                continue
            seen.add(aid)
            si = it.get("series_info") or {}
            ep = (si.get("stats") or {}).get("current_episode") or len(out) + 1
            out.append({
                "ep": int(ep),
                "vid": aid,
                "title": (it.get("desc") or "")[:60],
                "create_time": it.get("create_time") or 0,
                "video": _video_of(it),
            })
        if not d.get("has_more"):
            break
        nxt = d.get("max_cursor")
        if nxt in (None, cursor):
            break
        cursor = nxt
    out.sort(key=lambda x: x["ep"])
    return out[:max_episodes]


def feed(offset=0, count=50, content_type=None):
    """目录枚举。content_type=1940 是「爱情」频道；None 是混合全站池。"""
    q = f"{COMMON}&offset={offset}&count={count}&update_version_code=170400"
    if content_type is not None:
        q += f"&content_type={content_type}"
    d = _call("/aweme/v1/web/series/card/feed/", q)
    rows = []
    for card in (d.get("card_list") or []):
        s = card.get("series") or {}
        st = s.get("stats") or {}
        if not s.get("series_id"):
            continue
        rows.append({
            "sid": str(s["series_id"]),
            "name": (s.get("series_name") or "").replace("短剧 · ", "", 1),
            "eps": st.get("total_episode") or 0,
            "charge": s.get("is_charge_series"),
            "iaa": s.get("is_iaa"),
            "price": s.get("series_price") or 0,
            "author": (s.get("author") or {}).get("nickname") or "",
            "cover": ((s.get("cover_url") or {}).get("url_list") or [""])[0],
            "created": s.get("create_time") or 0,
            "cats": [c.get("name") for c in (s.get("series_content_types_new") or [])
                     if isinstance(c, dict) and c.get("name")],
        })
    return rows, bool(d.get("has_more"))


def play_urls(ep):
    """一条剧集的可播地址：主档 + 各码率档。"""
    v = ep.get("video") or {}
    out = list(v.get("play") or [])
    if v.get("play_h264"):
        out += [u for u in v["play_h264"] if u not in out]
    for b in v.get("bit_rate") or []:
        for u in b.get("urls") or []:
            if u not in out:
                out.append(u)
    return out