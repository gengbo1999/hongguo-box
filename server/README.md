# 短剧盒子服务端

把原来压在客户端里的东西搬到这里：索引、目录、上游签名、播放地址。

```
server/
  hg/app.py          # HTTP 路由 + 站点抓取 + 老索引导入
  hg/catalog.py      # 目录层: 标签倒排 / 标签云 / 最新 / 随机 / 搜索 / 批量取
  hg/upstream.py     # 上游甲方接口: 设备池 / _rticket / x-ss-stub / /sign
  Dockerfile         # python:3.12-alpine + headless JRE(跑 unidbg 签名)
  entrypoint.sh      # 先拉签名进程并发现端口, 再起 web
  k8s.yaml           # dev 命名空间: PVC + Deployment + Service + Ingress
  ../.github/workflows/build-image.yml  # v* 标签 -> ACR -> kubectl set image
```

## 索引

索引不再打包进 App。服务端第一次启动时读 `index.bin.z` 导入 SQLite：

- 老格式（`u64 rawSize` + **raw deflate**，体是 `DJIX`）由 `app.load_legacy_index` 解析
- 实测：**588,787 条**，导入 **7.9 秒**；紧接着建标签倒排 **4.0 秒**（整轮 `app.py seed` 12 秒）
- 搜索实测（首次查询冷缓存，含 `COUNT(*)`）：`神医` 1183 命中 300ms / `总裁` 2741 命中 40ms
  / `复仇` 500 命中 40ms；翻页本身 2~10ms
- 目录接口实测：`/api/tag` 7ms、`/api/newest` 3ms、`/api/random` 5ms、
  `/api/tags` 首次 1.0s（1.9M 行倒排聚合）、之后 3ms

之后靠 `HG_REFRESH_SEC`（默认 6 小时）在后台增量抓 `hongguoduanju.com` 的首页和四个分类，
把新剧补进库。抓取复刻了客户端 `API.swift` 的 `_ROUTER_DATA` 解析。

想让服务端继承全量库又不改镜像，就把种子索引放进构建上下文。
客户端已经不再打包这份索引了，种子从历史提交里取（仓库最后一次带它的版本）：

```sh
mkdir -p server/seed
git show 4e4e266^:ShortDramaBox/Sources/Resources/index.bin.z > server/seed/index.bin.z
```

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/healthz` | 库存条数、是否已导入、签名进程是否可用 |
| GET | `/api/nav` | 分类列表 |
| GET | `/api/search?q=&limit=&offset=` | 全库搜索（`q` 可为片名片段或 sid） |
| GET | `/api/detail?sid=` | 剧集信息 + 分集 vid（库里没有就现抓站点） |
| GET | `/api/tracks?vid=` | 取播放档位，`best` 是最高可用档 |
| POST | `/resolve` | 兼容客户端 `RemoteResolver`：客户端给 host/path/body，服务端签名后转发 |

`/resolve` 保持和客户端现有实现字节兼容，所以换成服务端不需要重打 IPA。

## 目录层（替代客户端内置索引）

客户端原来把 21MB 的 `index.bin.z` 打进 IPA，自己算标签云、最新、随机、搜索。
这些现在全由服务端算，客户端只发请求、拿 JSON：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/healthz` | 库存条数、标签数、是否已导入、签名进程是否可用 |
| GET | `/api/tags?limit=` | 标签云，`[{tag,count}]`，按 count 降序、同名按字典序 |
| GET | `/api/tag?tag=&offset=&limit=` | 某标签下的剧，`{total,items,next}` |
| GET | `/api/newest?offset=&limit=` | 最新入库，`{total,items,next}`；顺序是 `created DESC, sid DESC` |
| GET | `/api/random?limit=20&exclude=sid,sid` | 随机推荐，`exclude` 排除已展示过的 |
| GET | `/api/series?ids=sid,sid` | 按 sid 批量取，最多 200 个，保持入参顺序 |

`items` 里每条都是同一个形状：

```json
{"id":"7697982343553748030","title":"...","cover":"https://p6-novel.byteimg.com/novel-pic/<32位哈希>~tplv-shrink:640:0.image",
 "intro":"","eps":54,"tags":["剧情","重生"],"created":1792326183}
```

- `tags` 是数组（库里存的是逗号串），空标签就是 `[]`。
- `cover` 每次都从 32 位哈希重建成图床 URL，不存站点给的带签名地址——那玩意会过期。
  库里若真存了整条 URL，`catalog.cover_hash()` 也能把哈希抠出来，认不出来才原样返回。
- `limit` 一律夹在 1..100（`/api/random` 默认 20，其余默认 24），`offset` 负数当 0。

标签云走倒排表，不在请求时扫全表：`tag(tid,name)` +
`series_tag(tid,sid,created)`（`WITHOUT ROWID`，索引 `(tid, created DESC, sid DESC)`）。
全量建一次实测约 **4 秒**（588,787 行、1,917,960 条倒排、378 个标签），之后靠
`meta.tag_index_sig = COUNT(*):MAX(updated)` 判断是否过期，只在导入/刷新改过库时重建；
重建用独立连接，避免和请求线程抢一条连接。

## 部署

```sh
# 一次性
kubectl apply -f server/k8s.yaml
kubectl -n dev get ingress hongguo     # hongguo.gengbo.top

# 之后靠 CI
git tag v1.0.31 && git push origin v1.0.31
```

TLS 用 cert-manager 的 `letsencrypt-prod` 自动签发（集群里已有的 ClusterIssuer）。
想复用 `*.gengbo.top` 通配证书就删掉注解、把 secretName 改成 `gengbo-wildcard-tls`。

## 签名材料（可选）

`/api/tracks` 要拿 1080p 就必须有 unidbg 签名进程。材料不进 git，构建前放到：

```sh
cp -r <App>/Contents/Resources/backend/sign    server/sign       # unidbg-sign.jar
cp -r <App>/Contents/Resources/backend/capture server/capture    # fq_oversea/{so,bin}
```

没有这两样镜像照样能构建、索引和站点接口照常工作，只是 `/resolve` 走无签名直连
（实测红果对 `video_model` 系列接口不校验 `X-Argus`，所以很多时候够用）。

`entrypoint.sh` 会拉起
`java -cp unidbg-sign.jar com.hongguo.sign.FqTrace serve 0`，
用 `ss` 找出它实际监听的临时端口再导出 `SIGNER_URL`；日志有 5MB 截断护栏，
因为签名进程异常自旋时实测刷过 26GB 日志。

## 还没做

- 客户端瘦身：删 `ShortDramaBox/Sources/Resources/index.bin.z`（21MB，占 IPA 89%）
  和 `Sources/Core/LocalIndex.swift`，改调本服务的 `/api/search`、`/api/detail`。
  这一步要跟着 Xcode 构建验证，没在本机跑过，所以没动。
- 服务端解密 1080p：`spade_a` → `unwrap_v1` → AES-128-CTR → 去 CENC 的链路已经逆清，
  但还没搬进 `app.py`。媒体字节已经不经过服务端（`/api/media` 透传已删），
  客户端拿 `/api/tracks` 给的地址自己拉流、自己解密。