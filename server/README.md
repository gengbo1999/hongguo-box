# 短剧盒子服务端

把原来压在客户端里的东西搬到这里：索引、上游签名、播放地址。

```
server/
  hg/app.py          # 索引库 + 站点抓取 + /resolve 代理 + 媒体转发
  hg/upstream.py     # 上游甲方接口: 设备池 / _rticket / x-ss-stub / /sign
  Dockerfile         # python:3.12-alpine + headless JRE(跑 unidbg 签名)
  entrypoint.sh      # 先拉签名进程并发现端口, 再起 web
  k8s.yaml           # dev 命名空间: PVC + Deployment + Service + Ingress
  ../.github/workflows/build-image.yml  # v* 标签 -> ACR -> kubectl set image
```

## 索引

索引不再打包进 App。服务端第一次启动时读 `index.bin.z` 导入 SQLite：

- 老格式（`u64 rawSize` + **raw deflate**，体是 `DJIX`）由 `app.load_legacy_index` 解析
- 实测：**588,787 条**，导入 **7.1 秒**
- 搜索实测：`神医` 1183 命中 41ms / `总裁` 2741 命中 35ms / `复仇` 500 命中 35ms

之后靠 `HG_REFRESH_SEC`（默认 6 小时）在后台增量抓 `hongguoduanju.com` 的首页和四个分类，
把新剧补进库。抓取复刻了客户端 `API.swift` 的 `_ROUTER_DATA` 解析。

想让服务端继承全量库又不改镜像，就把种子索引放进构建上下文：

```sh
mkdir -p server/seed
cp ShortDramaBox/Sources/Resources/index.bin.z server/seed/index.bin.z
```

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/healthz` | 库存条数、是否已导入、签名进程是否可用 |
| GET | `/api/nav` | 分类列表 |
| GET | `/api/search?q=&limit=&offset=` | 全库搜索 |
| GET | `/api/detail?sid=` | 剧集信息 + 分集 vid（库里没有就现抓站点） |
| GET | `/api/tracks?vid=` | 取播放档位，`best` 是最高可用档 |
| GET | `/api/media?u=` | 播放地址转发，透传 Range |
| POST | `/resolve` | 兼容客户端 `RemoteResolver`：客户端给 host/path/body，服务端签名后转发 |

`/resolve` 保持和客户端现有实现字节兼容，所以换成服务端不需要重打 IPA。

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
  但还没搬进 `app.py`，目前 `/api/media` 只做透传。