#!/usr/bin/env python3
"""抖音短剧接口验证探针（只读，不写仓库数据）。

用法：
    DOUYIN_COOKIE="ttwid=...; UIFID=..." python3 scripts/probe_douyin.py            # 目录 + 首条详情 + 全剧集
    DOUYIN_COOKIE="..." python3 scripts/probe_douyin.py --sid 7697093388016814134   # 指定剧
    DOUYIN_COOKIE="..." python3 scripts/probe_douyin.py --sid ... --play            # 顺带验一条直链

cookie 获取：无头 Chrome 打开 https://www.douyin.com/series 后，用 CDP
`Network.getAllCookies` 导出（ttwid / UIFID / msToken 三个必需）。

已验证可用的三个接口（都**不需要 a_bogus 签名**）：
  1) GET /series                                    —— SSR HTML，内嵌 23 条剧（需 cookie）
  2) GET /aweme/v1/web/series/detail/?series_id=    —— 单剧元数据（甚至不需要 cookie）
  3) GET /aweme/v1/web/series/aweme/?series_id=     —— **剧集列表**（需 cookie，分页 cursor/max_cursor）

反例（别浪费时间）：
  - /series/<id> 路由 → 404；网页播放整部剧要登录
  - mix/aweme/list、aweme/post、search → 需要 a_bogus（线上 webmssdk 1.0.0.20）
  - series/list、series/rank/list、series/tag/list → 参数不合法 / Unsupported path(Janus)
  - series/aweme 无 cookie 时返回 7 字节 "blocked"

取流：episode 的 video.play_addr.url_list / play_addr_h264 / bit_rate[] 都是直链，
      必须带 Referer: https://www.douyin.com/（否则部分 CDN 节点 403）。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
)
BASE = "https://www.douyin.com"
COMMON = (
    "device_platform=webapp&aid=6383&channel=channel_pc_web&pc_client_type=1"
    "&version_code=170400&version_name=17.4.0&cookie_enabled=true&platform=PC"
    "&browser_language=zh-CN&browser_platform=MacIntel&browser_name=Chrome"
    "&browser_version=124.0.0.0&browser_online=true&engine_name=Blink"
    "&engine_version=124.0.0.0&os_name=Mac%20OS&os_version=10.15.7"
)


def _open(url: str, cookie: str, referer: str, accept: str):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": UA,
            "Cookie": cookie,
            "Referer": referer,
            "Accept": accept,
            "Accept-Language": "zh-CN,zh;q=0.9",
            # urllib 默认带 gzip，抖音对这套头回 403/412；显式 identity 才给正文
            "Accept-Encoding": "identity",
        },
    )
    return urllib.request.urlopen(req, timeout=25)


def get_raw(path: str, cookie: str, params: str = "", referer: str = BASE + "/") -> bytes:
    url = f"{BASE}{path}" + (("&" if "?" in path else "?") + params if params else "")
    with _open(url, cookie, referer, "text/html,application/json,*/*;q=0.8") as r:
        return r.read()


def get_json(path: str, cookie: str, params: str, referer: str = BASE + "/series") -> dict:
    raw = get_raw(path, cookie, params, referer)
    if raw[:1] != b"{":
        raise RuntimeError(f"{path} 非 JSON（{len(raw)}B）：{raw[:60]!r}")
    return json.loads(raw)


# ---------------------------------------------------------------- 0. 免人工 cookie 自举


def bootstrap_cookie() -> str:
    """裸 GET /series 就会下发 ttwid + UIFID_TEMP，这两个足以调 detail/aweme/card-feed。

    也就是说服务端不需要浏览器、不需要人工登录，能自己续 cookie。
    """
    import http.cookiejar

    cj = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
    req = urllib.request.Request(
        BASE + "/series",
        headers={"User-Agent": UA, "Accept": "text/html", "Accept-Encoding": "identity"},
    )
    with op.open(req, timeout=25) as r:
        r.read()
    return "; ".join(f"{c.name}={c.value}" for c in cj)


# ---------------------------------------------------------------- 1. 目录流

_FEED_PAT = re.compile(
    r'\\"seriesId\\":\\"(\d+)\\",\\"seriesName\\":\\"([^"\\]{1,80})\\",'
    r'\\"status\\":(\d+),\\"playVV\\":(\d+)'
)


def feed(cookie: str) -> list[dict]:
    """从 /series 的 SSR HTML 里抠出内嵌的 23 条剧。"""
    text = get_raw("/series", cookie, "from_nav=1").decode("utf-8", "replace")
    out: list[dict] = []
    seen: set[str] = set()
    for sid, name, status, vv in _FEED_PAT.findall(text):
        if sid in seen:
            continue
        seen.add(sid)
        it = {"series_id": sid, "name": name, "play_vv": int(vv)}
        seg = text[text.find(sid) : text.find(sid) + 4000]
        m = re.search(r'\\"totalEpisode\\":(\d+)', seg)
        if m:
            it["total_episode"] = int(m.group(1))
        m = re.search(r'\\"isCharge\\":(true|false)', seg)
        if m:
            it["is_charge"] = m.group(1) == "true"
        out.append(it)
    return out


# ---------------------------------------------------------------- 2. 单剧详情


def detail(sid: str, cookie: str) -> dict:
    d = get_json(
        "/aweme/v1/web/series/detail/", cookie, f"{COMMON}&series_id={sid}&req_from=channel"
    )
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
    return {
        "series_id": si.get("series_id") or sid,
        "name": si.get("series_name"),
        "real_name": si.get("real_name"),
        "aliases": si.get("related_names") or [],
        "desc": si.get("desc") or "",
        "total_episode": stats.get("total_episode"),
        "updated_to": stats.get("updated_to_episode"),
        "author": (si.get("author") or {}).get("nickname"),
        "author_sec_uid": (si.get("author") or {}).get("sec_uid"),
        "is_charge": si.get("is_charge_series"),
        "is_iaa": si.get("is_iaa"),
        "price": si.get("series_price"),
        "categories": [c.get("name") for c in (si.get("series_content_types_new") or [])],
        "play_vv": stats.get("play_vv"),
        "collect_vv": stats.get("collect_vv"),
        "create_time": si.get("create_time"),
        "update_time": si.get("update_time"),
        "fanqie_album_id": extra.get("fanqie_publish_album_id"),
        "cp_content_id": extra.get("cp_center_content_id"),
        "status_desc": (si.get("status") or {}).get("status_desc"),
        "tags": tag if tag else None,
    }


# ---------------------------------------------------------------- 3. 剧集列表


def _video_of(item: dict) -> dict:
    v = item.get("video") or {}
    out = {
        "duration_ms": v.get("duration"),
        "width": v.get("width"),
        "height": v.get("height"),
        "ratio": v.get("ratio"),
        "cover": ((v.get("cover") or {}).get("url_list") or [None])[0],
        "play": (v.get("play_addr") or {}).get("url_list") or [],
        "play_h264": (v.get("play_addr_h264") or {}).get("url_list") or [],
        "download": (v.get("download_addr") or {}).get("url_list") or [],
        "bit_rate": [
            {
                "gear": b.get("gear_name"),
                "quality": b.get("quality_type"),
                "bit_rate": b.get("bit_rate"),
                "w": (b.get("play_addr") or {}).get("width"),
                "h": (b.get("play_addr") or {}).get("height"),
                "urls": (b.get("play_addr") or {}).get("url_list") or [],
            }
            for b in (v.get("bit_rate") or [])
        ],
    }
    return out


def episodes(sid: str, cookie: str, max_episodes: int = 500) -> list[dict]:
    """按 cursor/max_cursor 翻完一部的剧集。"""
    out: list[dict] = []
    seen: set[str] = set()
    cursor = 0
    while len(out) < max_episodes:
        d = get_json(
            "/aweme/v1/web/series/aweme/",
            cookie,
            f"{COMMON}&series_id={sid}&pull_type=2&cursor={cursor}&count=20",
        )
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
            out.append(
                {
                    "episode": ep,
                    "aweme_id": aid,
                    "title": (it.get("desc") or "")[:40],
                    "create_time": it.get("create_time"),
                    "video": _video_of(it),
                }
            )
        if not d.get("has_more"):
            break
        nxt = d.get("max_cursor")
        if nxt in (None, cursor):
            break
        cursor = nxt
    out.sort(key=lambda x: (x["episode"] or 0))
    return out[:max_episodes]


# ---------------------------------------------------------------- 4. 直链验证


def check_play(url: str, cookie: str) -> str:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": UA,
            "Cookie": cookie,
            "Referer": BASE + "/",
            "Range": "bytes=0-200000",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            body = r.read()
            head = body[4:12]
            return f"{r.status} {r.headers.get('Content-Type')} {len(body)}B head={head!r}"
    except urllib.error.HTTPError as e:
        return f"HTTP {e.code} {e.headers.get('Content-Type')} len={len(e.read())}"


# ---------------------------------------------------------------- 5. 目录枚举（card/feed）

CARD_FEED = "/aweme/v1/web/series/card/feed/"


def card_feed(offset: int, count: int, cookie: str, content_type: int | None = 1940) -> dict:
    """分类 feed，**不需要 a_bogus**；offset/count 真分页。

    content_type=1940 是「爱情」频道；传 None 得到混合全站池（题材五花八门）。
    """
    q = f"{COMMON}&offset={offset}&count={count}&update_version_code=170400"
    if content_type is not None:
        q += f"&content_type={content_type}"
    return get_json(CARD_FEED, cookie, q, referer=BASE + "/series")


def _card_row(card: dict) -> dict:
    s = card.get("series") or {}
    stats = s.get("stats") or {}
    extra = s.get("extra")
    if isinstance(extra, str):
        try:
            extra = json.loads(extra)
        except ValueError:
            extra = {}
    extra = extra if isinstance(extra, dict) else {}
    cover = (s.get("cover_url") or {})
    return {
        "sid": s.get("series_id"),
        "name": s.get("series_name"),
        "real_name": s.get("real_name"),
        "eps": stats.get("total_episode"),
        "updated_to": stats.get("updated_to_episode"),
        "play_vv": stats.get("play_vv"),
        "charge": s.get("is_charge_series"),
        "iaa": s.get("is_iaa"),
        "price": s.get("series_price"),
        "exclusive": s.get("is_exclusive"),
        "author": (s.get("author") or {}).get("nickname"),
        "cover_uri": cover.get("uri"),
        "cover": (cover.get("url_list") or [""])[0],
        "cats": [c.get("name") for c in (s.get("series_content_types_new") or [])],
        "tag": extra.get("compass_playlet_tag"),
        "fanqie": extra.get("fanqie_publish_album_id"),
        "create_time": s.get("create_time"),
    }


def crawl(path: str, cookie: str, pages: int, count: int, start: int = 0,
          sleep_s: float = 0.3, content_type: int | None = 1940) -> int:
    import time

    seen: set[str] = set()
    done_offsets: set[int] = set()
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("sid"):
                    seen.add(r["sid"])
                if isinstance(r.get("_offset"), int):
                    done_offsets.add(r["_offset"])
    out = open(path, "a", encoding="utf-8")
    written = 0
    try:
        for i in range(pages):
            off = start + i * count
            if off in done_offsets:
                continue
            try:
                d = card_feed(off, count, cookie, content_type)
            except Exception as e:  # 单页失败不整体中断
                print(f"[crawl] off={off} 失败 {type(e).__name__}: {e}", file=sys.stderr)
                time.sleep(2.0)
                continue
            rows = [_card_row(c) for c in (d.get("card_list") or [])]
            fresh = [r for r in rows if r["sid"] and r["sid"] not in seen]
            for r in fresh:
                r["_offset"] = off
                seen.add(r["sid"])
                out.write(json.dumps(r, ensure_ascii=False) + "\n")
            written += len(fresh)
            out.flush()
            print(f"[crawl] off={off:6d} n={len(rows):2d} new={len(fresh):2d} total={len(seen)} has_more={d.get('has_more')}")
            time.sleep(sleep_s)
    finally:
        out.close()
    return written


# ---------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sid", help="指定 series_id，默认取目录流第一条")
    ap.add_argument("--play", action="store_true", help="额外验证第一条直链")
    ap.add_argument("--json", help="把结果写到这个路径")
    ap.add_argument("--max-episodes", type=int, default=500)
    ap.add_argument("--crawl", metavar="OUT.jsonl", help="枚举目录到 JSONL（可续跑）")
    ap.add_argument("--pages", type=int, default=10, help="--crawl 抓多少页")
    ap.add_argument("--count", type=int, default=50, help="--crawl 每页条数")
    ap.add_argument("--start-offset", type=int, default=0)
    ap.add_argument("--content-type", type=int, default=1940,
                    help="1940=爱情；-1=混合全站池")
    args = ap.parse_args()

    cookie = os.environ.get("DOUYIN_COOKIE", "").strip()
    if not cookie:
        # 没有现成 cookie 就自举：裸 GET /series 会下发 ttwid + UIFID_TEMP
        cookie = bootstrap_cookie()
        print("[cookie] 已自举", file=sys.stderr)

    if args.crawl:
        ct = None if args.content_type < 0 else args.content_type
        n = crawl(args.crawl, cookie, args.pages, args.count, args.start_offset, content_type=ct)
        print(f"[crawl] 新增 {n} 条 -> {args.crawl}")
        return 0

    if args.sid:
        sid = args.sid
        items = []
    else:
        items = feed(cookie)
        has_more = "hasMore" in get_raw("/series", cookie, "from_nav=1")[:600000].decode(
            "utf-8", "replace"
        )
        print(f"[feed] {len(items)} 条  has_more_ssr={has_more}")
        if not items:
            print("目录流空，cookie 可能失效", file=sys.stderr)
            return 1
        sid = items[0]["series_id"]
        for it in items[:5]:
            print("  ", it["series_id"], it.get("total_episode"), it.get("is_charge"), it["name"][:28])

    info = detail(sid, cookie)
    print(f"[detail] {info['series_id']} 《{info['name']}》 共{info['total_episode']}集 "
          f"付费={info['is_charge']} IAA={info['is_iaa']} 作者={info['author']}")
    print(f"         分类={info['categories']} 别名={len(info['aliases'])} 番茄album={info['fanqie_album_id']}")

    eps = episodes(sid, cookie, args.max_episodes)
    print(f"[episodes] {len(eps)} 集（total_episode={info['total_episode']}）")
    if eps:
        e = eps[0]
        v = e["video"]
        print(f"          第{e['episode']}集 {e['aweme_id']} {v['duration_ms']}ms "
              f"{v['w'] if 'w' in v else v['width']}x{v['height']} 直链={len(v['play'])} 档位={len(v['bit_rate'])}")
        print("          ", (v["play"][0] if v["play"] else "")[:110])
        if args.play and v["play"]:
            print("[play]", check_play(v["play"][0], cookie))

    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump({"feed": items, "detail": info, "episodes": eps}, f, ensure_ascii=False, indent=1)
        print(f"[out] {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())