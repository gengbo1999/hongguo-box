# 取流网关（signing gateway）

## 它解决什么问题

红果的取流接口 `/novel/player/multi_video_model/v1/` 在 **2026-10-21 之后**
对匿名请求改为**静默拒绝**：

```
HTTP/2 200
content-type: application/json
content-length: 0
server: TLB
tt_stable: 1
x-tt-trace-tag: id=11;cdn-cache=miss;type=dyn
server-timing: inner; dur=35, tt_agw; dur=29
```

响应体是空的——不是 403，不是报错，就是 0 字节。实测请求确实到达了源站
（`inner; dur≈35ms`），所以拒绝发生在**业务层**，与 IP、头部无关。
同一天源码注释里记录着 10-21 之前同一请求能拿到全部 5 档清晰度
（1080p 1080x1920 / 720p / 540p / 480p / 360p，均为 bytevc1 + spade_a），
说明这是服务端策略变更，而不是接口本身要求签名。

现在要拿到 1080p，必须带上原生客户端那套签名头：

| 头 | 说明 |
|---|---|
| `X-Argus` | 主签名 |
| `X-Gorgon` | 主签名（成对使用） |
| `X-Khronos` | 时间戳 |
| `X-Soter` | 设备指纹 |
| `x-ss-stub` | 请求体摘要 |

生成逻辑只存在于 Android 的 `libhongguo_signer.so`：

- **只导出 `JNI_OnLoad`**（加上 13 个 libc++ vtable 符号），
  真正的签名函数在 `JNI_OnLoad` 里通过 `RegisterNatives` 动态注册，
  **没有可直接 `dlsym` 的 C 符号**
- `DT_NEEDED` = `liblog.so` `libandroid.so` `libm.so` `libdl.so` `libc.so`
  —— 纯 bionic，musl/glibc 环境下无法加载
- APK 里只有 `arm64-v8a` 一个 ABI

**结论：签名不可能在 iOS 上做。** 放到服务端是唯一可行路径，而且
服务端一旦打通，全量用户立即生效，不需要重新打包、不需要重新侧载。

## 部署

```sh
# 1. 注入真实代码（ConfigMap 里的占位符会被替换）
kubectl create configmap shortdrama-resolver-src \
  --from-file=resolver.py=server/resolver/resolver.py \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. 部署
kubectl apply -f server/resolver/deploy.yaml

# 3. 让 Pod 重新读 ConfigMap
kubectl rollout restart deployment/shortdrama-resolver
kubectl rollout status  deployment/shortdrama-resolver

# 4. 自检
kubectl run -it --rm probe --image=curlimages/curl --restart=Never -- \
  curl -s http://shortdrama-resolver:8787/healthz
```

预期输出：

```json
{"ok": true, "service": "shortdrama-resolver", "version": "1.0.16", "signer": "none"}
```

> 如果 `kubectl` 拉不到 `python:3.12-alpine`（Docker Hub 不通），
> 两个替代方案：换成本机已有的 python 镜像；或者直接在 k3s-master 上用
> `nohup python3 resolver.py &` 裸跑，`resolver.py` 是纯标准库实现。

## 接口

### `GET /healthz`

```json
{"ok": true, "service": "shortdrama-resolver", "version": "1.0.16", "signer": "cmd"}
```

`signer` 为 `cmd` 表示已配置 `SIGNER_CMD`，`none` 表示未配置。

### `POST /resolve`

请求：

```json
{
  "host": "api5-normal-sinfonlineb.fqnovel.com",
  "path": "/novel/player/multi_video_model/v1/",
  "method": "POST",
  "query": {"aid": "8662", "version_code": "73532", "device_id": "...", "iid": "..."},
  "body": {"biz_param": {"video_platform": 1024}, "mixed_video_id_map": {"1": ["7598116896482806808"]}},
  "ua": "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; ...)",
  "headers": {"accept": "application/json"}
}
```

成功：

```json
{"ok": true, "status": 200, "bytes": 48213, "data": {"video_model": {"video_list": [...]}}}
```

失败（签名未生效时的典型形态）：

```json
{"ok": false, "status": 200, "error": "empty_body", "hint": "上游静默拒绝，签名未生效"}
```

`error` 可能的取值：

| 值 | 含义 |
|---|---|
| `empty_body` | 200 但响应体为空 —— 签名没生效 |
| `upstream: <状态码>` | 上游返回了非 200 |
| `bad_json` | 响应不是合法 JSON |

### 安全约束

- **主机白名单**：只允许
  `api5-normal-sinfonlineb.fqnovel.com`、`api5-normal-sinfonlinea.fqnovel.com`、
  `c.fqnovel.com`、`hongguoduanju.com`，不通配，避免被当成开放代理
- **路径必须以 `/` 开头**
- 请求体上限 1 MiB
- 12 秒上游超时、8 秒签名插件超时

## 签名插件契约（`SIGNER_CMD`）

网关通过子进程调用签名的实现，约定：

**stdin**

```json
{"url": "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/?aid=8662&...",
 "method": "POST",
 "body": "<base64 of request body>"}
```

**stdout**

```json
{"headers": {"X-Argus": "...", "X-Gorgon": "...", "X-Khronos": "...", "X-Soter": "...", "x-ss-stub": "..."}}
```

插件失败、超时、输出非法 JSON 时，网关**退化为不加签直传**，
即行为和现在的客户端直连一致——不会更差。

## 客户端如何启用

App 读 `UserDefaults` 的 `resolver_base` 键，例如：

```
http://<k3s-master-ip>:30087
```

留空即完全关闭（当前默认）。启用后：

- `Player.videoModel` 会**先问网关**，拿到档位就直接用
- 网关不可达 / 返回 `ok: false` / 档位为空 → **静默回退本地直连**
- 网关超时 8 秒，短于本地直连的 20 秒，回退不会明显拖慢播放

所以打开它最坏情况等于现在，最好情况直接拿到 1080p。

## 未来要做的

1. 在 arm64 + bionic 环境里加载 `libhongguo_signer.so`，
   通过 `RegisterNatives` 暴露的 `JNIEnv` 接口调用签名函数
2. 把签名器包成 `SIGNER_CMD`，配到环境变量里
3. 重启 Deployment —— **客户端无需任何改动**

第 3 步是这套架构最重要的性质：签名方案一旦打通，
服务端重启即全量生效，不用发版、不用重新侧载。
