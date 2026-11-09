# 抖音短剧并入 hongguo-box 的可行性结论

> 验证时间 2026-11-09，脚本 `scripts/probe_douyin.py`（纯 stdlib）。
> 结论一句话：**接口层能跑通，且不需要 a_bogus；与红果重合 80.7%，价值在于给红果补上它没有的那部分（确认独有 8,072 部 = 18.5%），以及多一路播放源/长版集数。**
>
> 产品定位：**红果为主、抖音为辅**——同一资源池里红果目录是主体，抖音只做「缺失补充」（`source='dy'`），
> 不追求两边并重；配额、排序、推荐仍以红果为准。

## 1. 实测结论

| 能力 | 是否通 | 说明 |
|---|---|---|
| 目录枚举 | ✅ | `GET /aweme/v1/web/series/card/feed/?offset=&count=`，免签名、需 cookie（无 cookie 返回空 `card_list`），`has_more` 恒真 |
| 单剧元数据 | ✅ | `GET /aweme/v1/web/series/detail/?series_id=`，**连 cookie 都不需要** |
| 剧集列表 | ✅ | `GET /aweme/v1/web/series/aweme/?series_id=&pull_type=2&cursor=&count=`，需 cookie（无 cookie 返回 7 字节 `blocked`）、免签名 |
| 播放直链 | ✅ | `video.play_addr.url_list[]`，206 `video/mp4`，**整集可下**（77/77 集码率 1.2–1.6 Mbps，无试看截断） |
| 服务端 cookie | ✅ | 裸 `GET /series` 就下发 `ttwid` + `UIFID_TEMP`，够用；**不需要浏览器、不需要登录** |
| 搜索 / 作者作品 | ❌ | `search`、`aweme/post` 需要 a_bogus（线上 webmssdk 1.0.0.20，现有 `abogus@2.1.1` 算法已失效） |
| 剧集页路由 | ❌ | `/series/<id>` 是 404；网页内播放整部剧要登录（令人意外的是接口层不校验） |

### 与红果的重合度（对 `server/seed/index.bin.z` 58.8 万条做标题精确比对）

| 样本 | 标题命中 | 集数一致 |
|---|---|---|
| 全站混合池前 2000 部 | **1673 = 83.7%** | 1609/1673 = 96.2% |
| 「爱情」频道前 1998 部 | **1778 = 89.0%** | 1660/1778 = 93.4% |

- 集数不一致里，抖音**多** 48 部（平均多 30+ 集，最大 `隐狼` 99 vs 71）、**少** 16 部 ⇒ 两平台确实存在**不同剪辑/投流版本**。
- 付费标记差异极大：抖音样本 98.8% `is_charge_series=1`，`is_iaa=0`；红果侧是免费 IAA 为主。
- **没有 id 级关联键**：`fanqie_publish_album_id`、`cp_center_content_id` 都不等于红果 sid（命中 0）。同名剧两边 id 都是 19 位 snowflake，但值不同，时间片相差 ~14–60 分钟 ⇒ 同一部剧在两个平台各自入库一次。
- 只能靠 **标题 + 总集数（+ 作者昵称）** 做匹配。

## 2. 目录枚举的稳定性边界（重要）

`card/feed` 的 `offset` 不是无限可用的：

| offset | 连续两次结果 | 说明 |
|---|---|---|
| 0 – 50 000 | 一致 | 稳定，可增量扫 |
| 70 000+ | **不一致** | 变成推荐流，同一 offset 每次给不同的剧 |

所以「全量 59 万」在抖音侧走不通；能确定性枚举的是**前 5 万左右**（按 50/页 ≈ 1000 次请求 ≈ 20 分钟）。
好在 5 万 × 84% 重合已经覆盖红果库的活跃头部。

## 3. 合入方案（已落地，2026-11-09）

设计取舍：**不改 series 主键**，抖音行统一 `sid = "dy:" + series_id`、`source='dy'`，
红果行不动（`source` 默认 `hg`），既有查询/客户端零改动。两个平台的 snowflake id
命名空间不同，加前缀后天然不撞。

### 3.1 表结构（`server/hg/catalog.py`）

```sql
ALTER TABLE series ADD COLUMN source TEXT NOT NULL DEFAULT 'hg';   -- _migrate_source() 自动迁移
CREATE INDEX ix_source ON series(source);

CREATE TABLE dy_ep(          -- 抖音剧集/直链缓存，按需写入
  vid TEXT PRIMARY KEY, sid TEXT NOT NULL, ep INTEGER,
  duration_ms INTEGER, width INTEGER, height INTEGER,
  cover TEXT, plays TEXT, updated INTEGER);
CREATE INDEX ix_dy_ep_sid ON dy_ep(sid);
```

`series_json()` 增加 `source` 字段（老行回落 `hg`）。

### 3.2 adapter（`server/hg/douyin.py`）

对齐 `upstream.py` 形态，全部裸 HTTP + stdlib：

- `cookie(force=False)`：裸 `GET /series` 取 `ttwid`+`UIFID_TEMP`，缓存 30 分钟，失败自动重取
- `detail(sid)`：`series/detail`（**免 cookie、免签名**），名称去掉 `短剧 · ` 前缀
- `episodes(sid)`：`series/aweme` 按 `max_cursor` 翻页（20/页，需 cookie）
- `feed(offset, count, content_type=None)`：`card/feed` 目录枚举，`None`=混合池，`1940`=爱情
- `play_urls(ep)`：`play_addr.url_list` + `bit_rate[]` 各档

### 3.3 API（`server/hg/app.py`）

- `/api/detail?sid=dy:<sid>`：先 upsert 目录行（source='dy'），再读/拉 `dy_ep`，
  返回与红果同形 `{ok, series, episodes:[{index,vid}]}`
- `/api/tracks?vid=<vid>`：`dy_ep` 命中则走抖音分支（10 分钟内复用缓存，
  直链过期后现拉），返回同样 `{ok,best,tracks,diag}` 结构
- 红果路径完全不变；`_dy_vid()` 未命中时按老链路走

### 3.4 入库（`scripts/ingest_douyin.py`）

```bash
python3 scripts/ingest_douyin.py --db /data/hongguo.db --crawl build-dd/dy/catalog.jsonl
python3 scripts/ingest_douyin.py --db /data/hongguo.db --crawl ... --dry-run   # 只看差异
```

- 归一化标题（去 `短剧 · `、书名号、全半角、标点、空白、小写）后与红果
  `series(source='hg')` 比对；`name` 与 `real_name` 任一对上即视为已有
- **按红果最新入库时间分两档**（`cutoff = max(created) where source='hg'`，可用 `--cutoff` 覆盖）：
  - `created <= cutoff` → **确认独有**，入库 `source='dy'`
  - `created > cutoff` → **待定**（红果可能只是还没入库），默认不入池，写到 `build-dd/dy/pending.jsonl`；
    `--keep-pending` 可强制入库
- 模糊地带靠「刷新红果库 → 重跑本脚本」复查：pending 里被红果补上的会走"已有"分支自动跳过，幂等
- 只写目录字段，剧集与直链留给 `/api/detail`、`/api/tracks` 现拉
- 幂等：`INSERT ... ON CONFLICT(sid) DO UPDATE`

参数：`--cutoff 2026-10-27`（手动指定基准时间）、`--pending-out <path>`、`--keep-pending`、`--dry-run`、`--limit`。

### 3.5 测试库实测（`/tmp/hg_test.db`，588,787 条红果种子）

全量抓取 43,702 部（混合池，offset 0–50k，约 50 分钟）：

| 指标 | 值 |
|---|---|
| 抓取 | 43,702 部（去重后） |
| 红果已有（归一化标题命中 name 或 real_name） | 35,262 = 80.7% |
| 原始判定独有（未分档） | 8,440 = 19.3% |
| **确认独有入库**（`created <= 红果 max(created)`） | **8,072 = 18.5%** |
| 待定不入池（比红果最新入库还新） | 368 = 0.8%（`build-dd/dy/pending.jsonl`） |
| 原始独有按创建年（分档前） | 2019:2 / 2020:2 / 2021:48 / 2022:109 / 2023:147 / 2024:1239 / 2025:5403 / 2026:1491 |
| 独有里 eps≥100 | 378 部（最长 700 集《虾仁：大明小县令》） |
| 单剧剧集 | 77/77 集全拉到；700 集剧实际只暴露 433 集 |
| 直链 | `206 video/mp4`，15 个档位（1080p 起，1.2–1.6 Mbps） |

独有清单：`build-dd/dy/unique.csv`（sid/title/eps/created，8,440 行，含待定）；
待定清单：`build-dd/dy/pending.jsonl`（368 条，等红果刷新后重跑复查）。

### 3.6 已知限制

1. **比对基准会过期**：本地红果库 = `seed` 快照（约 58.8 万，标题/created 只到快照时刻）+ 运行期 `refresh_loop`
   的增量（`server/hg/app.py:398`，从红果首页/分类页抓新剧）。所以拿快照的 `max(created)` 当"红果最新"会误判——
   晚于它的抖音剧其实是红果还没来得及入库。
   处理：① 比对前先手动刷一次 `POST /api/refresh`（或 `python3 server/hg/app.py refresh`）；
   ② `ingest_douyin.py` 默认以 **hg 表的 `max(created)`** 作 cutoff，把独有拆成「确认独有 / 待定」两档，待定不入池；
   ③ 隔天（或红果刷新后）重跑 ingest，pending 命中红果的自动跳过，形成"基准更新 → 重判"的闭环。
   影响面：本轮 43,702 部里只有 368 部（0.8%）落在待定区。
2. **offset 尾部漂移**：0–50k 可确定性枚举；50k 之后是推荐流，重复率升高（本轮 49.9k 处 new=0）。
3. **封面 48h 过期**：抖音封面是带 `x-expires` 的签名 URL（无签名直拼 `p3-sign.douyinpic.com` 返回 403）。刷新方式：`python3 scripts/backfill_dy_cover.py --db <库>`（8 线程约 3.5 分钟补完 8.4 千条，0 失败），或重跑 crawl + ingest，或用户点开详情时 `detail()` 覆盖更新。
4. **付费剧集可能不全**：`series/aweme` 只返回平台暴露的集（700 集声明只给 433 集），疑似付费/未上架集。
5. **`/api/tracks` 依赖先 `/api/detail`**：vid→sid 的映射只存在 `dy_ep` 缓存里，未缓存时按红果链路走。
6. **同名误判**：只靠标题（name/real_name）比对，重名剧会被误并（跳过），需要人工抽检。

## 4. 风险

1. **offset 漂移**：只能增量扫头部，尾部要另找入口（搜索/作者页需要 a_bogus，短期不建议再攻）。
2. **cookie 生命周期**：`UIFID_TEMP` 有效期未知，需定时重取；`ttwid` 约 1 年。自举逻辑要能失败重试。
3. **限流/风控**：当前 50/页、0.15s 间隔，2000 条无异常；全量扫建议 ≤5 req/s 并随机抖动。
4. **版权**：与红果同源，但抖音侧多为付费剧（`is_charge=1`）；直链绕开付费墙，自用可，分发有风险。
5. **标题匹配误判**：短剧重名多（「隐狼」「以爱之名」都出现过），自动关联要人工抽检。

## 5. 复现

```bash
cd /Users/a123/hongguo-box

# 自举 cookie + 单剧 77 集 + 直链校验
python3 -c "import sys;sys.path.insert(0,'scripts');import probe_douyin as P;\
ck=P.bootstrap_cookie();print(P.detail('7697093388016814134',ck))"

# 目录枚举（可续跑，-1 表示混合全站池）
python3 scripts/probe_douyin.py --crawl /tmp/dy.jsonl --pages 40 --count 50 --content-type -1
```