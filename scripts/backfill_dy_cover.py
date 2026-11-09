#!/usr/bin/env python3
"""补抖音行封面。

抖音封面是带 x-expires 的签名 URL（约 48h 过期），无签名直拼图床返回 403。
本脚本对 cover 为空（或 --all 时全部）的 source='dy' 行逐条调 series/detail，
把 detail 返回的签名封面写回 series.cover。detail 免 cookie、免签名。

用法:
    python3 scripts/backfill_dy_cover.py --db /data/hongguo.db            # 只补空封面
    python3 scripts/backfill_dy_cover.py --db /data/hongguo.db --all      # 全量刷新
    python3 scripts/backfill_dy_cover.py --db /data/hongguo.db --threads 6 --limit 100
"""
import argparse
import sqlite3
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, __file__.rsplit("/scripts/", 1)[0] + "/server/hg")
import douyin  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--all", action="store_true", help="连已有封面一起刷新")
    args = ap.parse_args()

    conn = sqlite3.connect(args.db)
    where = "source='dy'" + ("" if args.all else " AND (cover IS NULL OR cover='')")
    sql = f"SELECT sid FROM series WHERE {where}"
    if args.limit:
        sql += f" LIMIT {args.limit}"
    rows = [r[0] for r in conn.execute(sql)]
    print(f"[fill] 待补 {len(rows)} 条", flush=True)

    lock = threading.Lock()
    stat = {"ok": 0, "err": 0}
    t0 = time.time()

    def one(sid):
        try:
            d = douyin.detail(sid[3:] if sid.startswith("dy:") else sid)
            cover = d.get("cover") or ""
            if not cover:
                raise ValueError("empty cover")
            with lock:
                c = sqlite3.connect(args.db)
                c.execute("UPDATE series SET cover=?,"
                          " intro=COALESCE(NULLIF(intro,''),?) WHERE sid=?",
                          (cover, d.get("desc") or "", sid))
                c.commit()
                c.close()
                stat["ok"] += 1
        except Exception as e:  # 单条失败不中断
            with lock:
                stat["err"] += 1
                if stat["err"] <= 5:
                    print(f"[warn] {sid}: {e}", flush=True)
        with lock:
            n = stat["ok"] + stat["err"]
            if n % 1000 == 0:
                print(f"[fill] {n}/{len(rows)} ok={stat['ok']} err={stat['err']}"
                      f" {time.time() - t0:.0f}s", flush=True)

    with ThreadPoolExecutor(args.threads) as ex:
        list(ex.map(one, rows))
    print(f"[fill] 完成 ok={stat['ok']} err={stat['err']} {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
