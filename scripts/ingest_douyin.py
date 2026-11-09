#!/usr/bin/env python3
"""把抖音目录并入 hongguo-box 的同一资源池。

规则：
  * 抖音行 sid 一律写成 `dy:<series_id>`，series.source='dy'，红果行不动；
  * 入库前按「归一化标题」去重：红果已有的同名剧直接跳过（记 alias 统计）；
  * 只写目录字段（title/cover/eps/tags/created），剧集与直链按需由
    server/hg/douyin.py 在 /api/detail、/api/tracks 里现拉并缓存到 dy_ep。

用法：
    python3 scripts/ingest_douyin.py --db /data/hongguo.db --crawl build-dd/dy/catalog.jsonl
    python3 scripts/ingest_douyin.py --db /tmp/t.db --crawl ... --dry-run
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import unicodedata

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "server", "hg"))
import catalog  # noqa: E402

norm_title = catalog.norm_title


def load_crawl(path):
    seen, rows = set(), []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            sid = str(r.get("sid") or "")
            if not sid or sid in seen:
                continue
            if not (r.get("name") or "").strip():
                continue
            seen.add(sid)
            rows.append(r)
    return rows


def hg_titles(db):
    """红果侧已有标题(归一化)集合。"""
    c = sqlite3.connect(db)
    try:
        has_src = "source" in {r[1] for r in c.execute("PRAGMA table_info(series)")}
        sql = ("SELECT title, eps FROM series" +
               (" WHERE source='hg'" if has_src else ""))
        return {norm_title(t) for t, _ in c.execute(sql)}
    finally:
        c.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=os.environ.get("HG_DB", "/data/hongguo.db"))
    ap.add_argument("--crawl", required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--cutoff", default="",
                    help="红果侧最新入库时间(YYYY-MM-DD 或 unix 秒)；默认取 hg 行 max(created)")
    ap.add_argument("--pending-out", default="",
                    help="比红果 max(created) 还新、暂时判不准的条目写到这个 jsonl（默认放在目录文件旁）")
    ap.add_argument("--keep-pending", action="store_true",
                    help="待定条目也直接入库（默认只入库能确认独有/重合的）")
    args = ap.parse_args()

    rows = load_crawl(args.crawl)
    if args.limit:
        rows = rows[:args.limit]
    print(f"[in] 抖音目录 {len(rows)} 部", flush=True)

    c = sqlite3.connect(args.db)
    c.row_factory = sqlite3.Row
    catalog.ensure_schema(c)
    existing = {norm_title(r["title"]) for r in c.execute(
        "SELECT title FROM series WHERE source='hg'")}
    print(f"[hg] 红果标题索引 {len(existing)}", flush=True)

    now = int(__import__("time").time())

    # 红果库的最新入库时间：晚于它的抖音剧，红果还没来得及入库，
    # 现在判"独有"会误伤，单独放 pending，等红果刷新后再比。
    cutoff = 0
    if args.cutoff:
        v = args.cutoff.strip()
        cutoff = int(v) if v.isdigit() else int(
            __import__("time").mktime(__import__("time").strptime(v, "%Y-%m-%d") + (0, 0, -1)))
    else:
        row = c.execute("SELECT MAX(created) FROM series WHERE source='hg'").fetchone()
        cutoff = int(row[0] or 0)
    print(f"[cutoff] 红果最新入库 {cutoff} ({__import__('time').strftime('%Y-%m-%d %H:%M', __import__('time').localtime(cutoff)) if cutoff else '-'})", flush=True)

    matched, uniq, pending, batch = 0, [], [], []
    for r in rows:
        keys = {norm_title(r.get("name")), norm_title(r.get("real_name"))}
        keys.discard("")
        if keys & existing:
            matched += 1
            continue
        created = int(r.get("create_time") or r.get("created") or 0)
        if cutoff and created > cutoff and not args.keep_pending:
            pending.append(r)
            continue
        uniq.append(r)
        batch.append(("dy:" + str(r["sid"]), (r.get("name") or "").strip(),
                      r.get("cover") or "", "", int(r.get("eps") or 0),
                      ",".join(r.get("cats") or []), "",
                      created, now, "dy"))

    total_n = max(len(rows), 1)
    print(f"[diff] 红果已有 {matched}（{matched / total_n:.1%}）；"
          f"确认独有 {len(uniq)}（{len(uniq) / total_n:.1%}）；"
          f"待定 {len(pending)}（{len(pending) / total_n:.1%}，比红果最新入库还新）", flush=True)

    if pending:
        rows_p = [("dy:" + str(r["sid"]), (r.get("name") or "").strip(),
                   (r.get("real_name") or "").strip(), int(r.get("eps") or 0),
                   int(r.get("create_time") or r.get("created") or 0), now, 0)
                  for r in pending]
        with c:
            c.executemany(
                """INSERT INTO dy_pending(sid,title,real_name,eps,created,first_seen,checked)
                   VALUES(?,?,?,?,?,?,?)
                   ON CONFLICT(sid) DO UPDATE SET checked=excluded.checked""", rows_p)
        out = args.pending_out or os.path.join(os.path.dirname(os.path.abspath(args.crawl)),
                                               "pending.jsonl")
        with open(out, "w", encoding="utf-8") as f:
            for r in pending:
                f.write(json.dumps({k: r.get(k) for k in
                                    ("sid", "name", "real_name", "eps", "create_time")},
                                   ensure_ascii=False) + "\n")
        print(f"[pending] {len(pending)} 条 -> dy_pending 表 + {out}", flush=True)
    if args.dry_run:
        for r in uniq[:15]:
            print("   +", r.get("eps"), r.get("name"))
        return 0

    with c:
        c.executemany(
            """INSERT INTO series(sid,title,cover,intro,eps,tags,vids,created,updated,source)
               VALUES(?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(sid) DO UPDATE SET title=excluded.title,
                 cover=excluded.cover, eps=excluded.eps, tags=excluded.tags,
                 created=excluded.created, updated=excluded.updated, source='dy'""", batch)
    total = c.execute("SELECT COUNT(*) FROM series WHERE source='dy'").fetchone()[0]
    pend = c.execute("SELECT COUNT(*) FROM dy_pending").fetchone()[0]
    print(f"[out] 写入 {len(batch)} 条；库内抖音行 {total}；dy_pending {pend}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())