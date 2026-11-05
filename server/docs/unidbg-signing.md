# 1080p 与 unidbg 签名线交接文档

> 状态（2026-11-05 更新）：**签名链路已打通，取流仍被上游静默拒绝**。
> 签名进程在镜像内可用（`/sign` 能吐出真实 `X-Argus` / `X-Gorgon` / `X-Medusa` 等），
> 但 `multi_video_model` 依旧 `HTTP 200 + 0 字节`，且**未签名请求也是同样的 0 字节**
> —— 说明这道闸不是签名校验，而是会话/风控资格。详见文末「2026-11-05 实测」。
> 本文档主体写于 2026-11-03，对应仓库 commit `2a2ce05`（`main`）。
> 相关但**不等于**本文的旧文档：`server/resolver/README.md`（描述的是 `SIGNER_CMD` 子进程契约，与当前 `hg/` 网关的 HTTP 契约**不一致**，见 §3）。

---

## 0. 五分钟速览

- 目标：让 App 能播 1080p。
- 卡点：番茄上游的 `multi_video_model` 接口对**匿名请求**返回 `HTTP 200 + content-length: 0`（0 字节，静默拒绝）。要拿到直链必须带 `X-Argus` / `X-Gorgon` / `X-Khronos` / `X-Soter` / `x-ss-stub` 等风控头。
- 这些头由 Android native 库 `libmetasec_ml.so`（metasec / mobsec SDK）生成，**iOS 无法复刻**，所以必须在服务端跑一个 unidbg 模拟器来算。
- 服务端已经**预留好**了整条链路（`hg/upstream.py` 会调签名服务，`entrypoint.sh` 会拉起 `FqTrace serve`），只是镜像里**没有签名 jar**，所以线上一直是无签名直连，`/healthz` 的 `signer` 恒为 `false`。
- 现在距离打通还差三件事：
  1. 关掉 unidbg 的 verbose（否则日志爆炸，见过 11.4 GB / 26 GB 两次）；
  2. 让 `FqTrace serve` 不再报 `Fatal: SDK not init`（缺 init 配置）；
  3. 把 jar 弄进镜像（32 MB，被 gitignore），并验证 `/resolve` 返回非空。
- 已经**精确定位**的一个修复点：`unidbg-sign.jar` 里 `MetasecSign.class` 的**文件偏移 13005**，字节 `0x04` → `0x03`，即可让 `VM.setVerbose(true)` 变 `false`（详见 §6.4，附完整复现步骤）。

---

## 1. 业务目标与验收标准

### 1.1 目标

App 播放 1080p 清晰度可用。链路：

```
iOS App
  └─ POST https://hongguo.gengbo.top/resolve   {vid}
       └─ hg/upstream.py: resolve_tracks()
            ├─ 组 query（device 指纹、_rticket 毫秒）
            ├─ 计算 x-ss-stub = MD5(body).hexdigest().upper()
            ├─ 调签名服务拿风控头            ← ★ 这一步现在拿不到
            └─ POST 上游 multi_video_model
                 └─ 返回 video_model JSON（含各清晰度直链）
```

### 1.2 验收标准（按顺序，全绿才算打通）

| # | 检查项 | 期望 |
|---|---|---|
| A1 | `unidbg-sign.jar` 单跑，无参数 | 打印一组 `X-Argus` 等头，**不**出现 online 11 GB 级别日志 |
| A2 | 本地起 `FqTrace serve` | 日志出现监听端口，`curl -X POST /sign` 返回**扁平** header dict |
| A3 | 本地 `hg/app.py` + `SIGNER_URL` | `/healthz` → `"signer": true` |
| A4 | `POST /resolve {"vid":"7521622549621378073"}` | 返回的 tracks 里 `bytes > 0`，且含 `1080p` |
| A5 | 线上镜像部署后 | 同 A3、A4 |
| A6 | 降级 | 签名进程挂掉时，索引接口（`/api/*`）不受影响，`/resolve` 退化为无签名直连并报错 |

> 判定"成功"的唯一可靠信号是 **stdout 里出现签名头或 `===SIG_START===`**。
> 这个 jar 的所有失败分支都会 `println` 后 **`return`，退出码仍然是 0**，不要用 `$?` 判断成败。

---

## 2. 为什么必须签名（证据）

2026-11-03 现场复测，匿名直接打上游（复现脚本见 `build-dd/probe.py`）：

```
$ curl -sS -D hdr_a.txt -o body_a.bin \
    -X POST 'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/?...' \
    -H 'content-type: application/json; charset=utf-8' \
    -H 'x-ss-stub: <MD5>' \
    --data @body.json
```

`hdr_a.txt`（原文，节选）：

```
HTTP/2 200
server: volc-dcdn
content-type: application/json
content-length: 0
date: Sun, 01 Nov 2026 16:52:08 GMT
tt_stable: 1
x-tt-logid: 20261102005208356158EB06A3DB48DE4A
x-dsa-origin-status: 200
```

`body_a.bin` 大小：**0 字节**。

含义：

- 不是 403、不是 401，是 **200 + 空体**。上游用"看起来成功"的方式丢弃了请求，避免暴露风控规则。
- `x-dsa-origin-status: 200` 说明 CDN 回源成功了，是**业务层**主动返回空。
- 换 host（sinfonlinea / sinfonlinec）、换 device 指纹、换 UA 全部一样。
- 结论：**没有合法风控头 = 永远 0 字节**，与参数无关。

反过来，桌面端旧 backend（`recon/app_extract/.../hongguo.py`）在有 Frida oracle 的机器上是能拿到 1080p 的，说明"签名正确 → 上游正常返回"这条路是通的，不是接口下线。

---

## 3. ⚠️ 仓库里有两套签名实现，别搞混

这是接手最容易踩的坑。`main` 分支上同时存在：

| | `server/hg/`（**当前生产**） | `server/resolver/`（**旧的独立网关**） |
|---|---|---|
| 入口 | `server/hg/app.py` | `server/resolver/resolver.py` |
| 是否在镜像里 | ✅ 是，`ENTRYPOINT /app/entrypoint.sh` | ❌ 否，独立 `deploy.yaml` 部署 |
| 怎么调签名 | **HTTP**：`POST {SIGNER_URL}/sign` | **子进程**：`SIGNER_CMD` stdin/stdout |
| 环境变量 | `SIGNER_URL`，回退 `SIGN_SERVERS`（逗号分隔） | `SIGNER_CMD` |
| 谁拉起签名 | `server/entrypoint.sh` 起 `FqTrace serve` | 外部，由 `SIGNER_CMD` 指定 |
| 文档 | 本文档 | `server/resolver/README.md` |

**当前线上跑的是 `hg/`。** `server/resolver/` 是更早的方案，代码还在，但 `requirements`/k8s 清单（`server/k8s.yaml`）用的是 `hg/`。

### 3.1 真实的签名契约（以代码为准）

`server/hg/upstream.py`：

```python
def _signer_url():                       # L122
    base = os.environ.get("SIGNER_URL")
    if base: return base.rstrip("/")
    servers = os.environ.get("SIGN_SERVERS") or ""
    first = servers.split(",")[0].strip()
    return first.rstrip("/") or None

def sign(url, headers, timeout=40):      # L136
    base = _signer_url()
    if not base:
        return None                      # 没配签名服务 → 无签名直连
    payload = json.loads(post_json(base + "/sign", {"url": url, "headers": headers}))
    if not isinstance(payload, dict):
        raise UpstreamError("signer_bad_reply", ...)
    if payload.get("error"):
        raise UpstreamError("signer_error", str(payload["error"]))
    return {str(k): str(v) for k, v in payload.items() if v is not None}
```

**契约定义：**

- 请求：`POST {SIGNER_URL}/sign`，`Content-Type: application/json`，body `{"url": "<完整URL>", "headers": {<当前请求头>}}`
- 响应：**扁平** JSON 对象，key 是 header 名，value 是 header 值，直接 `headers.update(...)` 合并进上游请求。例如：

```json
{
  "X-Argus": "5Rk...==",
  "X-Gorgon": "8404b0b3...",
  "X-Khronos": "1762000000",
  "X-Soter": "...",
  "x-ss-stub": "ABCD..."
}
```

- **不要**返回 `{"headers": {...}}` 这种包一层的结构 —— `sign()` 会把它当成一个名叫 `headers` 的头。

### 3.2 文档与代码的偏差（需要修）

`server/resolver/README.md` 的「## 签名插件契约（SIGNER_CMD）」一节写的是：

- stdin：`{"url","method","body": <base64>}`
- stdout：`{"headers": {...}}`

这套契约**只对 `server/resolver/resolver.py` 成立**（它在 L100 读 `SIGNER_CMD`，healthz 在 L252/L295 报 `"signer": "cmd"/"none"`）。
对当前 `hg/` 完全无效。

**接手第一件事**：要么把 `resolver/README.md` 标注为"历史方案/仅 `resolver.py` 适用"，要么把 `resolver/` 整个目录归档删除。现在这样两套并存，很容易让人照着错的契约实现。

---

## 4. 服务端已经就绪的部分

这些**不用改**，直接可用：

### 4.1 `server/entrypoint.sh`（55 行）

关键逻辑：

```sh
JAR=/app/sign/unidbg-sign.jar
LOG=/tmp/signer.log

if [ -f "$JAR" ]; then
  ( cd /app/sign && exec java -Djava.net.preferIPv4Stack=true \
      --add-opens java.base/java.lang=ALL-UNNAMED \
      -Xmx512m -XX:+ExitOnOutOfMemoryError \
      -cp unidbg-sign.jar com.hongguo.sign.FqTrace serve "${SIGNER_PORT:-0}" ) \
    > "$LOG" 2>&1 &
```

几点必须知道的：

1. **cwd 是 `/app/sign`**。这不是随便选的 —— jar 里所有资源路径都是 `../capture/...` 相对路径（见 §6.2），所以 `/app/sign` 的上一级 `/app` 下面必须有 `capture/`。
2. **日志有 5 MB 截断保护**（第 20 行起，每 30 s 检查）：

   ```sh
   # 注释原文：签名进程一旦进入异常自旋会疯狂刷日志(实测见过 26GB), 定期截断
   ```
   这个保护是**必要的**，因为 §6.4 那个 verbose 问题会让日志以 10 GB 量级暴涨。副作用：出问题时你只能看到最后 5 MB。
3. **端口是动态发现**的（`SIGNER_PORT=0` 让 OS 分配），通过 `ss -ltnp | awk` 反查 PID 拿到端口，再 `export SIGNER_URL="http://127.0.0.1:$SIGNER_LISTEN"`。
4. 拿不到端口时打印「未拿到签名端口, /resolve 将无签名直连」并**继续启动**（不阻塞目录接口）。
5. jar 不存在时打印「没打包 $JAR, /resolve 走无签名直连(索引与站点接口不受影响)」。
6. 最后 `exec python /app/app.py`。

### 4.2 `server/hg/app.py`

- `/healthz` 在 DB 信息外附加 `body["signer"] = upstream.signer_available()`（L444）—— 即**只看环境变量有没有配**，不代表签名服务真的健康。要判断真的能不能签名，得实际打一次 `/resolve`。
- `do_POST` 只处理 `/resolve`。

### 4.3 `server/hg/upstream.py`

已经写好并调好的部分：

- `PHONE_PROFILES`：6 个真实机型（Redmi 22041211AC/23021RAA2Y、OPPO PEHM00、vivo V2218A、OnePlus PHB110、HONOR FNE-AN00）。
- `QUALITY_ORDER = ["1080p","720p","540p","480p","360p"]`。
- `new_device()` / `current_device()` / `rotate_device()`：设备指纹池，用于规避风控。
- `base_query()` / `build_query()` / `build_url()`：`_rticket` 用毫秒时间戳。
- `post()`：自动算 `x-ss-stub = md5(raw).hexdigest().upper()`，然后 `if signed: headers.update(sign(...))`。
- `resolve_tracks(vid)`：依次试 `multi1024` → `multi3` → `single3` 三个接口，返回 `(tracks, {"path","notes"})`。
- `best_1080()`：按 `QUALITY_ORDER` 选最优。
- `_request_json()`：空 body → `UpstreamError("upstream_empty", f"HTTP {status} 0 bytes")` —— 就是线上现在会看到的错。

**也就是说：只要签名服务能返回头，服务端一行代码都不用改。**

---

## 5. 组件清单（含哈希，便于核对）

### 5.1 需要进镜像的

| 文件 | 大小 | SHA-256 | 现状 |
|---|---|---|---|
| `unidbg-sign.jar` | 32,350,638 B | `03b6984d56682fbde0d941ca3ae7177260189a3c9da4a18732d1bae064bb1ecd` | **被 gitignore**（`server/sign/`），镜像里没有 ⇒ 线上 `signer: false` |
| `libmetasec_ml.so` | 3,447,432 B | `20d3f8dd8d0d47e4e3c0da0f377eaf69e72a72c8d214ca56e6e7493c65a8fc2d` | 在 `recon/work/capture/{so,fq_oversea}/`，与 TV APK 的 `libhongguo_signer.so` **字节相同** |
| `libc++_shared.so` | 911,696 B | — | `recon/work/capture/so/` |
| `ms_16777218.bin` | 2,014 B | — | `recon/work/capture/ms_cert/` |

jar 的 md5 `25f1fa561a2e7c1bf7e93c543c3c10f3`。

### 5.2 jar 内部结构

fat jar，含：

- unidbg **0.9.9**
- `unidbg-unicorn2`（**注意：不是官方 unidbg 自带的 unicorn1**，pom 里提到需要打过补丁的构建，这个 jar 已经内嵌好了）
- `slf4j-simple`（1.7.x，见 §7 的 SLF4J 告警）
- 内置 `android/sdk23`、`android/sdk19`、`net/fornwall/jelf`

自己的类（`com/hongguo/sign/`）：

| 类 | 大小 | 作用 |
|---|---|---|
| `MetasecSign.class` | 17,746 | 自测入口，`main` 里硬编码路径（§6.2） |
| `FqTrace.class` | 23,458 | **`serve` 模式入口**，`entrypoint.sh` 用的就是这个 |
| `EncryptRun.class` | 8,214 | 加解密小工具 |
| `FqTrace$1.class` | 2,136 | lambda / 内部类 |

`MANIFEST.MF`：`Main-Class: com.hongguo.sign.MetasecSign`，`Build-Jdk-Spec: 25`。

> ⚠️ 默认 `Main-Class` 是 `MetasecSign` 而不是 `FqTrace`，所以 `java -jar` 和 `java -cp ... FqTrace serve` 走的是**两条不同代码路径**，用的 SO 目录也不同（§6.3）。

### 5.3 提取来源（溯源）

`/Users/a123/deepseek/hongguo-ios/recon/app_extract/Contents/Resources/backend/` —— 从桌面端 App 包体里解出来的旧后端，包含：

- `hongguo.py`（1,063 行）：旧版 Python 后端，`Oracle.sign()` 走 **Frida** attach 真机算签名，`SIGNER_URL` 池默认 `http://127.0.0.1:8001,http://127.0.0.1:8002`，为空则退化为进程内 Frida。
- `sign/unidbg-sign.jar`
- `jre/`：Temurin **JRE 17.0.20.1+1**（macOS aarch64），**只有 JRE 没有 JDK**（bin 下仅 `java jfr jrunscript keytool rmiregistry`）。
- `frida/`：`oracle.py`、`decutil.py`、`extract_keybox_pairs.py`、`offline_decrypt.py`、`unwrap_spade.py`。注意 `hongguo.py:115` 引用的 `frida/oracle.js` **在磁盘上不存在**，Frida 那条路现在也走不通。
- `capture/fq_oversea/`：SO + `ms_16777218.bin`。

TV APK 解包在 `/Users/a123/deepseek/tvx/`，里面 `cn.hongguo.tv.*` 的 `classes.dex` 含 `Lms/bd/c/m;` 和 `Lcn/hongguo/TVNativeSigner;`，以及正则 `:X-(Argus|Gorgon|Helios|Khronos|Ladon|Medusa|Neptune|Soter)` —— 可以用来反推需要哪些头。

---

## 6. 已定位的根因（这部分是本文档的核心）

### 6.1 事实一：`MetasecSign.main` 完全不读 argv

`run3.sh` 传了三个**绝对路径**，仍然报「缺 libmetasec_ml.so」：

```sh
# run3.sh
cd /Users/a123/deepseek/hongguo-ios/recon/work
"$JRE" -cp sign/unidbg-sign.jar com.hongguo.sign.MetasecSign \
  "$PWD/capture/so/libmetasec_ml.so" \
  "$PWD/capture/so/libc++_shared.so" \
  "$PWD/capture/ms_cert/ms_16777218.bin"
```

`run3.log` 原文：

```
SLF4J(W): No SLF4J providers were found.
SLF4J(W): Defaulting to no-operation (NOP) logger implementation
SLF4J(W): See https://www.slf4j.org/codes.html#noProviders for further details.
SLF4J(W): Class path contains SLF4J bindings targeting slf4j-api versions 1.7.x or earlier.
SLF4J(W): Ignoring binding found at [jar:file:/.../work/sign/unidbg-sign.jar!/org/slf4j/impl/StaticLoggerBinder.class]
SLF4J(W): See https://www.slf4j.org/codes.html#ignoredBindings for an explanation.
缺 libmetasec_ml.so
EXIT=0
```

**为什么传了绝对路径还缺**：反汇编 `MetasecSign.class` 证明 `main` 里 `max_locals=8`、local 0 是 `args` 但**从头到尾没被读过**。它写死了三个 `File`：

| 常量池 | 值 |
|---|---|
| #543 / #544 | `../capture/so/libmetasec_ml.so` |
| #545 / #546 | `../capture/so/libc++_shared.so` |
| #547 / #548 | `../capture/ms_cert/ms_16777218.bin` |

然后：

```java
if (!meta.exists()) { System.err.println("缺 libmetasec_ml.so"); return; }   // CP #552
```

路径相对 **cwd** 解析。`run3.sh` 的 cwd 是 `recon/work`，`../capture` → `recon/capture`，不存在 ⇒ 必然失败。

**推论：cwd 是签名契约的一部分。** 想换路径只有两条路：改 cwd，或者打补丁改字节码里的常量。目前没有 `javac`（§8），后者成本高，优先走 cwd。

### 6.2 事实二：`FqTrace` 和 `MetasecSign` 用**不同的** SO 目录

| 类 | 读的路径 |
|---|---|
| `MetasecSign.main` | `../capture/so/libmetasec_ml.so` |
| `FqTrace.<init>`（L65） | `../capture/fq_oversea/libmetasec_ml.so` |

两个目录里的 SO 字节完全相同（同一 sha256），但代码里写死了两个不同位置。

这意味着要同时满足两条路径，部署布局必须是：

```
/app/                     ← 等价于 recon/work
├── sign/                 ← cwd，jar 放这里
│   └── unidbg-sign.jar
└── capture/
    ├── so/
    │   ├── libmetasec_ml.so
    │   └── libc++_shared.so
    ├── ms_cert/
    │   └── ms_16777218.bin
    ├── fq_oversea/
    │   ├── libmetasec_ml.so
    │   └── libc++_shared.so
    └── msstate/          ← 运行时状态目录，可空
```

**这不是可选优化，是硬约束。** `entrypoint.sh` 里 `cd /app/sign` 已经是这个布局的一半，缺的是把 `capture/` 也搬进镜像。

### 6.3 事实三：`FqTrace serve` 能起来，但报「SDK not init」

把 cwd 换成 `recon/work/sign`（此时 `../capture` 正确指向 `recon/work/capture`），`serve.log` / `serve2.log` 记录：

阶段一（起服务成功）：

```
[*] unidbg 离线签名服务已启动: 127.0.0.1:0/sign
```

阶段二（模拟器初始化成功）：

```
[*] 番茄海外 init 完成 base=0x122c0000
[*] 签名工作线程就绪(模拟器本线程持有)
```

阶段三（**卡在这里**）：

```
[main]E/METASEC: Fatal: SDK not init, crashing...
```

重复 **16 次**后停住。

解读：

- SO 加载成功，`JNI_OnLoad` 走完，`base=0x122c0000` 是 so 的加载基址。
- 但 metasec SDK 的内部状态机认为自己**没有被初始化**，于是主动"崩溃"（这是 SDK 的反调试/反盗用逻辑，不是真的 segfault）。
- 对比：`MetasecSign` 路径能进到真正的签名计算（然后 spun，见 §6.4），说明**签名本身能算**，问题在 init 流程。

init 缺什么？代码里的线索：

- `handleMS` 的 op 处理器只实现了 `1`（→ `op 0x4000001`，即 `driveInit`）和 `16777218`（→ 直接返回 `null`，注释「暂无,返回 null」）。
- `driveInit` 需要 license，从 `../capture/cronet/init_config.json` 读。**这个文件不存在**，所以代码打印「[!] 缺 init_config.json, 跳过 init」然后跳过。
- 有个 property 叫 `noinit`，注释「跳过 driveInit (noinit), 让 sign 惰性初始化(仿 FqTrace)」—— 说明作者也知道两条路的 init 策略不同。
- `MSROOT` 默认 `../capture/msstate`，现在是**空目录**。

所以「SDK not init」最可能的原因就是 **`init_config.json` 缺失，driveInit 被跳过**。下一步应该优先补这个文件（从真机/桌面端抓，或从 `ms_16777218.bin` 推导），或者试 `-Dnoinit=true` 让 sign 走惰性初始化。

### 6.4 事实四：verbose 日志爆炸（**已完全定位，修复方案就绪**）

现象：`MetasecSign` 进入签名计算后，在 `PC=0x1253d288`（=`[libmetasec_ml.so]0x27d288`）附近**死循环刷寄存器 dump**，日志以 GB 级增长：

- 本机实测：`sign/ms_run1.log` 达到 **11,479,957,709 B**（约 11.4 GB，111,429,276 行）
- `entrypoint.sh` 第 20 行注释记录：历史上见过 **26 GB**

根因：`MetasecSign.<init>` 里**硬编码** `VM.setVerbose(true)`，叠加我在 `0x1253d288` 下的 dbg 断点，每次命中都 dump 全部寄存器。

**修复方案（已验证定位，未执行）：**

对 `unidbg-sign.jar` 内的 `com/hongguo/sign/MetasecSign.class` 做 **1 字节**修改：

| 项 | 值 |
|---|---|
| 常量池项 | **#129** = `VM.setVerbose:(Z)V`（IMethodref） |
| 调用指令 | `invokeinterface`，位于 **文件偏移 13006** |
| 指令字节 | `b9 00 81 02 00`（opcode + idx=0x0081=129 + count=2 + 0） |
| **目标偏移** | **13005** |
| **原值 → 新值** | **`0x04`（`iconst_1`）→ `0x03`（`iconst_0`）** |

同时确认：`SyscallHandler.setVerbose` 是 CP #55，位于偏移 12854，**本来就是 `0x03`**（false），不用动。

验证这一点的只读脚本（不需要 JDK，纯 Python）：

```sh
cd /Users/a123/deepseek/hongguo-ios/recon/work
python3 jdis.py cls/com/hongguo/sign/MetasecSign.class setVerbose
```

输出会显示 `invokeinterface` 与它前面那条 `iconst_1`。

⚠️ **`recon/work/patch_verbose.py` 是错的，不要用。** 它假设 `setVerbose` 是 CP #127，去找 `b9 00 7f 02 00`，命中 0 次（`expected exactly 1 site, got 0`）。正确的 needle 是 `b9 00 81 02 00`。该脚本还没产出过任何文件。

补丁脚本要点：

- 用 Python `zipfile` 复制 jar，**保持 entry 顺序和属性**（不要 `unzip`/`zip` 往返，会丢时间戳/权限/压缩方式，可能影响 `Class-Path` 之外的东西——虽然这里主要是洁癖）。
- 改完立刻自检：新 jar 里同偏移处必须是 `0x03`，且**只有这 1 个字节不同**。
- 产物命名 `unidbg-sign-quiet.jar`，**不要覆盖原 jar**（原 jar 是唯一可信副本，且没有 javac 无法重建）。

**在执行任何 rerun 之前必须先做这一步。** 否则一次跑就把磁盘打满（本机 119 GiB 可用，但也撑不住反复）。

### 6.5 事实五：所有失败路径退出码都是 0

三个日志文件（`run3.log`、`signer_run.log`、以及 `MetasecSign` 无参运行）末尾都是 `EXIT=0`。

**不要用 `echo $?` 判断成功。** 可靠信号只有：

- stdout 出现 `===SIG_START===`
- 或者出现形如 `X-Argus` / `X-Gorgon` 的 header 行

### 6.6 事实六：`FqTrace serve` 返回 404 的一例

早期抓包得到 `grab.json`：

```
<h1>404 Not Found</h1>No context found for request
```

这不是签名服务的问题，是请求打到了**错误的路径/端口**（签名服务只认 `/sign`）。记录下来避免后来人误判。

---

## 7. 环境与工具链约束（本机 macOS，实测）

这些坑会直接卡住复现，提前说明能省几个小时。

### 7.1 没有 JDK，只有 JRE

| 命令 | 状态 |
|---|---|
| `java` | ❌ `/usr/bin/java` 是 **macOS stub**，`java -version` 打印 `The operation couldn't be completed. Unable to locate a Java Runtime.` 但**退出码是 0** |
| `javac` / `javap` / `jar` | ❌ 不存在 |
| `mvn` / `gradle` | ❌ 不存在 |

**能用的 JRE**（唯一）：

```
/Users/a123/deepseek/hongguo-ios/recon/app_extract/Contents/Resources/backend/jre/bin/java
```

Temurin `17.0.20.1+1`，macOS aarch64，`IMAGE_TYPE="JRE"`。

推论：
- 不能 `javap -c` → 用 `recon/work/jdis.py`（纯 Python class 解析器 + 反汇编器）。
- 不能 `javac` → 不能重新编译 `FqTrace`/`MetasecSign`，改行为只能打字节补丁或改 cwd / 环境变量。
- 不能 `jar` → 重打包用 Python `zipfile` 或 `unzip`/`zip`。

### 7.2 macOS `strings` 读不了 `.class`

```
error: ... fat file: X.class truncated or malformed
```

它把 `.class` 当 Mach-O fat binary 解析了。要看常量池里的字符串，用：

```sh
python3 jdis.py <classfile> --strings
```

### 7.3 `jdis.py` 的使用要点

- 打印的是**常量池索引**而不是解析后的文本，`ldc_w` 之后的数字要自己去 `--strings` 里对。
- invoke 类指令会打成 `owner.mname:desc:desc`（desc 重复了一次，是显示 bug，不影响判断）。
- 分支目标显示为 `-> <target>`。
- 支持 `tableswitch` / `lookupswitch` / `wide`。

常用：

```sh
python3 jdis.py cls/com/hongguo/sign/FqTrace.class                 # 全量
python3 jdis.py cls/com/hongguo/sign/MetasecSign.class setVerbose  # 只看匹配方法
python3 jdis.py cls/.../MetasecSign.class --cp                     # dump 常量池
```

### 7.4 其他

- `timeout` 命令**不存在**（本机和 k3s 节点都没有）。要限时用 `curl --max-time N` 或自己写循环。
- 本地 bash 调用超过 ~20–30 s 会被移到后台任务，用 `job_output` 收结果；**job id 要一字不差地复制**。
- 用 `| head -3` 接后台启动的服务会**吞掉启动日志**，改成重定向到文件。
- `objdump` 可用（Apple LLVM 21.0.0），`nm`/`strings`/`unzip`/`zip`/`python3` 都有。
- `readelf` / `llvm-objdump` 没有 → 分析 SO 只能靠 `objdump`（Mach-O 模式）或纯字节扫描。
- REA / 反编译器**不可用**：`analyze_function` → `provider_unavailable`；ghidra `not_configured`；hopper 二进制缺失。所以本文档的结论全部来自**静态字节分析 + 反汇编 + 运行日志**，没有伪代码佐证。接手者若能搞到 IDA/Ghidra，可以进一步验证 §6.3 的 init 路径。

---

## 8. 下一步计划（按顺序，每步都有验收）

> 原则：**先止血，再诊断，最后集成。** 每一步都不要跳。

### 阶段 0：止血（预计 30 分钟，零风险）

1. 写正确的补丁脚本（参考 §6.4，偏移 13005，`0x04`→`0x03`），产出 `recon/work/sign/unidbg-sign-quiet.jar`。
2. 自检：
   - 新 jar 与旧 jar 的**差异字节数必须恰好为 1**；
   - 差异位置必须是 13005；
   - 用 `jdis.py` 反汇编新 jar 里的 `MetasecSign.class`，确认 `setVerbose` 前面变成 `iconst_0`。
3. 用 `ulimit -f` 或重定向 `| head -c` 兜底防爆盘（例如 `> log 2>&1` 之后再跑一个每 5 s 截断的监控循环）。

**验收**：两个 jar 只差 1 字节；反汇编确认 verbose=false。

### 阶段 1：让 `MetasecSign` 单跑吐签名（诊断）

```sh
cd /Users/a123/deepseek/hongguo-ios/recon/work/sign   # ← cwd 必须是这里
"$JRE" -cp unidbg-sign-quiet.jar com.hongguo.sign.MetasecSign
```

判断：

- 若出现 `===SIG_START===` 或 header → **阶段 1 成功**，跳到阶段 3。
- 若仍卡在 `0x1253d288` spin 但**日志不再爆炸** → 说明 verbose 只是放大器，真正的问题是那只 SO 在该 PC 上死循环。这时才需要上 GDB/单步（unidbg 有 `emulator.getBackend().hook_add_new(...)` 之类手段，但需要改 Java 代码 → 没 javac，改不了 ⇒ 只能靠 dbg hook 的 `addBreakPoint` 打印有限上下文）。
- 若报 `Fatal: SDK not init` → 说明 `MetasecSign` 也走了 FqTrace 的 init 分支，直接进阶段 2。

**验收**：拿到一组非空 header，或明确 spin 的具体循环条件。

### 阶段 2：解决 `SDK not init`（最关键）

按可能性排序：

1. **补 `../capture/cronet/init_config.json`**。这是代码里明写要读、且当前缺失的 license 文件。来源：
   - 桌面端 App 跑起来后抓（它会自己写这个文件）；
   - 或从 `ms_16777218.bin`（2,014 B）反推结构；
   - 或从 TV APK 的 assets 里找。
2. **试 `noinit` 属性**：`-Dnoinit=true`（注释说这是"让 sign 惰性初始化(仿 FqTrace)"的开关）。如果 FqTrace 路径本来就是 noinit，那说明 `MetasecSign` 缺的正是"不 init 也能签"的能力 —— 这条要实测。
3. **检查 `msstate`**：`MSROOT` 默认 `../capture/msstate`，当前**空目录**。真机上这个目录里有持久化状态（设备指纹、keybox 等）。空的可能就导致 SDK 认为未初始化。
4. **检查 `emulator.set(CP #92, 10174)`** 这个魔法常量覆盖是否正确。

**验收**：日志不再出现 `Fatal: SDK not init, crashing...`，且 `/sign` 能返回 header JSON。

### 阶段 3：打通 HTTP `/sign` 契约

```sh
cd /Users/a123/deepseek/hongguo-ios/recon/work/sign
"$JRE" -cp unidbg-sign-quiet.jar com.hongguo.sign.FqTrace serve 18080
# 另一个终端
curl -sS --max-time 20 -X POST http://127.0.0.1:18080/sign \
  -H 'content-type: application/json' \
  -d '{"url":"https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/?aid=1967","headers":{"user-agent":"com.phoenix.read/72232"}}'
```

**验收**：

- 返回**扁平** dict（不是 `{"headers":{...}}`）；
- 至少含 `X-Argus`、`X-Gorgon`、`X-Khronos` 三者中的两个；
- 同一 URL 连续请求 3 次，`X-Khronos` 应随时间变化（证明不是常量/缓存）。

⚠️ 签名结果是 **设备 + 时间 + 线程绑定**的。`X-Khronos` 是时间戳、`_rticket` 是毫秒，**重放抓到的旧头一定失败**。所以不要试图"录一次包然后硬编码"。

### 阶段 4：本地端到端

```sh
# 1. 起签名服务（cwd 必须是 sign/）
cd /Users/a123/deepseek/hongguo-ios/recon/work/sign
"$JRE" -cp unidbg-sign-quiet.jar com.hongguo.sign.FqTrace serve 18080 &

# 2. 起 hg 服务
cd /Users/a123/hongguo-box/server
PORT= HG_DB=$PWD/hg/hongguo.db HG_SEED_INDEX=$PWD/seed/index.bin.z HG_REFRESH_SEC=0 \
  SIGNER_URL=http://127.0.0.1:18080 nohup python3 hg/app.py > /tmp/hgp.log 2>&1 &

# 3. 验证
curl -sS --max-time 10 http://127.0.0.1:8787/healthz | python3 -m json.tool | grep signer   # 期望 true
curl -sS --max-time 30 -X POST http://127.0.0.1:8787/resolve \
  -H 'content-type: application/json' \
  -d '{"vid":"7521622549621378073"}' | head -c 2000
```

**验收**：`/resolve` 返回的 tracks 里 `bytes > 0`，且 `best_1080` 能选出 1080p。

### 阶段 5：进镜像

**好消息：Dockerfile 已经写好了，不用改。** `server/Dockerfile` 第 35–38 行：

```dockerfile
if [ -d /app/src/sign ]; then cp -r /app/src/sign /app/sign;
  echo "打包了签名 jar"; else echo "没有 server/sign, 跳过签名"; fi; \
if [ -d /app/src/capture ]; then cp -r /app/src/capture /app/capture;
  echo "打包了 capture"; else echo "没有 server/capture, 跳过"; fi; \
```

也就是说：**只要 `docker build` 的上下文里存在 `server/sign/` 和 `server/capture/`，它们就会自动被打进镜像**，位置正好是 `/app/sign` 和 `/app/capture`（符合 §6.2 的相对路径要求）。

**真正的问题是：这两个目录都在 `.gitignore` 里**，所以 CI 从 git 拉下来的上下文里没有它们，构建出来的镜像自然 `signer: false`。

所以阶段 5 要做的是**让文件在 `docker build` 之前出现在 `server/sign/` 和 `server/capture/`**，而不是改 Dockerfile。

三个交付方案（推荐 A）：

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **A（推荐）** | 把 `unidbg-sign.jar` + `capture/` 打成 `signer-bundle.tar.gz` 传到 GitHub Release asset；workflow 里 `docker build` **之前**加一步 `curl` 下载 + **校验 sha256** + 解包到 `server/sign/`、`server/capture/` | 仓库干净；哈希可审计；换版本只换 asset | 依赖 GitHub 可访问（CI 里没问题） |
| B | CI 里跑 `fetch-signer.sh`，从内网/NAS 拉 | 不依赖 GitHub | 引入外部依赖，CI 变脆 |
| C | base64 塞进仓库 | 无外部依赖 | 43 MB 文本进 git，不可接受 |

方案 A 在 `.github/workflows/build-image.yml` 里大概长这样（**注意位置**：必须在 `docker build` 之前）：

```yaml
- name: 下载签名材料
  run: |
    curl -fsSL -o /tmp/signer-bundle.tar.gz \
      "${{ github.server_url }}/${{ github.repository }}/releases/download/signer-v1/signer-bundle.tar.gz"
    echo "03b6984d... /tmp/signer-bundle.tar.gz" | sha256sum -c -   # 换成回填后的完整哈希
    tar -xzf /tmp/signer-bundle.tar.gz -C server/                  # 解开得到 server/sign, server/capture
    ls -l server/sign server/capture/so server/capture/fq_oversea
```

其他确认项：

- 镜像体积 +36 MB 左右（jar 32 MB，SO 4.3 MB；压缩后约 30 MB）。
- `k8s.yaml` 已有 `SIGNER_PORT: "0"`，**不用改**。
- `Dockerfile` 里 `HG_REFRESH_SEC=0`（第 51 行）表示默认不做定期刷新，符合当前预期。
- 内存限制 `1536Mi`，jar 的 `-Xmx512m` 够用；但 unidbg + unicorn 的 JIT 会额外吃内存，**首次部署后盯一下 RSS**，必要时调 limit。
- 构建日志里应该出现 `打包了签名 jar` 和 `打包了 capture` 两行。**没出现就说明文件没进去**，这是最快的自检。

**验收**：

```sh
docker build -f build-dd/dk/Dockerfile -t hg-local-test .
docker run --rm --entrypoint sh hg-local-test -c \
  'ls -l /app/sign/unidbg-sign.jar /app/capture/so/ /app/capture/fq_oversea/ /app/capture/ms_cert/'
```
布局正确 + 本地 `/healthz` 返回 `signer: true`。

### 阶段 6：发布与回归

- 打 `v*` tag 触发 `.github/workflows/build-image.yml`（**唯一**触发方式，`workflow_dispatch` 需要 token，当前没有）。
- 部署后验证 A3/A4/A5。
- **必须验证降级**（A6）：`kubectl exec` 进去 kill 掉 java 进程，确认 `/api/search` 等接口仍然 200，`/resolve` 返回明确错误而不是 500。

---

## 9. 产物保全清单

以下文件**不可再生**（没有 javac、没有原始工程），删了就没了。请勿清理 `recon/work/`。

| 路径 | 说明 |
|---|---|
| `recon/work/sign/unidbg-sign.jar` | 唯一可信的签名 jar，32 MB |
| `recon/work/capture/so/libmetasec_ml.so` | 签名核心 SO |
| `recon/work/capture/so/libc++_shared.so` | 依赖 |
| `recon/work/capture/ms_cert/ms_16777218.bin` | 2 KB 证书/配置 |
| `recon/app_extract/.../backend/` | 整个旧后端，含 JRE 和 Frida 脚本 |
| `tvx/` | TV APK 解包，`classes.dex` 可反推 header 名 |
| `recon/work/jdis.py` | 没有 javap 时唯一的 class 反汇编工具 |
| `build-dd/probe.py` | 匿名探针，复现"0 字节"用 |

已删除、**不要试图找回**：`sign/ms_run1.log`（11.4 GB 的 verbose dump）。

---

## 10. 未解问题 / 风险

### 10.1 未解问题（按重要性）

1. **签名是否充分？** 目前只证明了"缺签名 → 0 字节"。没证明"有签名 → 非 0 字节"。有可能还需要 `x-tt-token` / `cookie`（游客会话）。旧 backend `hongguo.py` 的 `DEVICE_KEYS` 里包含 `iid/device_id/cdid/klink_egdi/channel/update_version_code`，并且 `:200-219` 会合并 session headers（`cookie`、`x-tt-token`、`x-tt-store-region`、`x-tt-store-region-src`）。**这条要等阶段 3 成功后立刻验证**。
2. **`SDK not init` 的确切触发条件**：是缺 `init_config.json`、缺 `msstate`、还是缺 `driveInit` 调用？三条线索都指向 init，但没做对照实验。
3. **`0x1253d288` 到底在等什么**：是等一个从没被 set 的全局变量，还是在轮询某个 fd？需要单步才能确定。
4. **unidbg 是否需要补丁版**：jar 的 pom 提到打过补丁，但这个 fat jar 是否已经包含全部补丁、其它 unidbg 版本能否复现，未知。
5. **反调试能不能过**：TV 版 SO 里有 `proc/self/maps`、`proc/self/cmdline`、`system/bin/sh`、`dev/socket/logdw`、`android/provider/Settings`、`java/lang/Thread`、`StackTraceElement` 等字符串，说明有 root/emulator 检测。目前能加载说明**部分**检测被 unidbg 骗过了，但 `SDK not init` 有可能就是检测失败后的表现。

### 10.2 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| verbose 没关掉就 rerun | 磁盘打满（11–26 GB/次） | 阶段 0 必做；加日志截断监控 |
| jar 丢失 | 整条线报废 | §9 保全；尽快传到 Release asset |
| 上游改风控 | 签名算法失效 | 无法预防；只能监控 `/resolve` 成功率 |
| `_rticket`/`X-Khronos` 时钟漂移 | 签名被拒 | 容器内保证 NTP；`build_url()` 用本地毫秒 |
| 单进程签名并发瓶颈 | `/resolve` 变慢 | `sign()` 已有 40 s 超时；必要时 `SIGN_SERVERS` 多实例 |
| 内存 1536Mi 不够 | OOMKilled | 先观察；必要时调 limit 或降 `-Xmx` |

---

## 11. 附：速查命令

```sh
# ---- 环境 ----
JRE=/Users/a123/deepseek/hongguo-ios/recon/app_extract/Contents/Resources/backend/jre/bin/java
WORK=/Users/a123/deepseek/hongguo-ios/recon/work

# ---- 反汇编 ----
cd $WORK
python3 jdis.py cls/com/hongguo/sign/MetasecSign.class setVerbose
python3 jdis.py cls/com/hongguo/sign/FqTrace.class --strings | grep -i 'capture\|msstate\|cronet'

# ---- 跑自测（cwd 必须是 sign/）----
cd $WORK/sign
"$JRE" -cp unidbg-sign.jar com.hongguo.sign.MetasecSign

# ---- 跑 serve ----
cd $WORK/sign
"$JRE" -cp unidbg-sign.jar com.hongguo.sign.FqTrace serve 18080

# ---- 清进程 ----
pkill -f com.hongguo.sign.MetasecSign
pkill -f com.hongguo.sign.FqTrace

# ---- 本地 hg 服务 ----
cd /Users/a123/hongguo-box/server
cp ../build-dd/index.bin.z seed/index.bin.z        # 需要时重新播种
HG_DB=$PWD/hg/hongguo.db HG_SEED_INDEX=$PWD/seed/index.bin.z python3 hg/app.py seed
PORT= HG_DB=$PWD/hg/hongguo.db HG_SEED_INDEX=$PWD/seed/index.bin.z HG_REFRESH_SEC=0 \
  nohup python3 hg/app.py > /tmp/hgp.log 2>&1 &
pkill -f "hg/app.py"

# ---- 本地镜像 ----
sed 's|^FROM python:3.12-alpine|FROM docker.1panel.live/library/python:3.12-alpine|' \
  server/Dockerfile > build-dd/dk/Dockerfile
docker build -f build-dd/dk/Dockerfile -t hg-local-test .
docker run --rm --entrypoint sh hg-local-test -c 'ls -l /app/sign /app/capture/*'
```

---

## 12. 一页纸总结给接手者

> 服务端代码全好了，差的只是"一个能算签名的进程"。
>
> 这个进程的源码没有，只有一个 32 MB 的 fat jar。jar 里的 `MetasecSign` 用相对路径找 SO（`../capture/so/`），`FqTrace` 用另一个相对路径（`../capture/fq_oversea/`），所以 **cwd 和目录结构是 API 的一部分**。
>
> 现在有两条路：
> - `MetasecSign`（自测）能进 native 签名，但 verbose 会把日志刷到 10 GB 级，且在 `PC=0x1253d288` 死循环；
> - `FqTrace serve`（生产用）能起服务、能 init，但报 `Fatal: SDK not init`，怀疑缺 `capture/cronet/init_config.json`。
>
> **先打那个 1 字节补丁（偏移 13005，`04`→`03`），把日志管住，再去查 init。** 别在没关 verbose 的情况下跑第二遍。
>
> 判定成功只看 stdout 有没有 header/`===SIG_START===`，别看退出码——它永远返回 0。
>
> 打通之后，`hg/upstream.py` 一行不用改，只要 `SIGNER_URL` 指对、`/sign` 返回扁平 header dict 就行。
---

## 2026-11-05 实测：签名已通，卡在会话

### 结论

| 事实 | 证据 |
|---|---|
| 镜像内签名可用 | 容器里 `POST /sign` 返回 `X-Argus`(240) / `X-Gorgon`(52) / `X-Helios` / `X-Kronos` / `X-Ladon` / `X-Medusa`(884) / `X-Neptune` / `X-Soter`(120)；`/tmp/signer.log` 有「番茄海外 init 完成」「签名工作线程就绪」 |
| 播放接口依然 0 字节 | 签名请求、**未签名请求**、伪造 `X-Khronos`、破坏 `X-Gorgon`、错误 `x-ss-stub`、gzip 请求体，六种一律 `http=200 bytes=0` |
| 不是偶发 | 同一请求连打 10 次，2.5s 间隔，10/10 空响应 |
| 路由存在 | 同主机 `POST /novel/player/zzz_not_a_route/v1/` 返回 `404 Page not found`，而两个 player 接口返回 200+0，说明网关匹配到了 handler |
| 响应头表明进了应用层 | `Server-Timing: inner; dur=38,tt_agw; dur=33`、`X-Tt-Logid`、`X-Dynamic-Status: MISS`，不是 CDN 缓存页 |
| 换网络无效 | 本机 NAT 与阿里云 `112.124.63.35`（k3s 集群）都是 0 字节 |
| 加设备参数无效 | 补 `openudid/oaid/clientudid/dpi/ac/region/tz_offset/mcc_mnc` 等完整移动端 query 后仍 0 字节 |
| H5 cookie 无效 | `build-dd/cookie_hg.txt`（hongguoduanju.com 域）塞进 `cookie` 头后仍 0 字节，域名不同不能串 |

### 为什么说卡的是「会话」

本文档 §679 早就把这条列为未验证的假设：*"没证明「有签名 → 非 0 字节」。有可能还需要 `x-tt-token` / `cookie`（游客会话）"*。
现在的实测把「签名不足」排除了：**签名与不签名得到完全相同的空响应**，风控头不参与这个判决。

另外 `desktop_bootstrap.py` 在打包模式下把 `DEVICE_POOL_SIZE` 置 0，也就是说对外发布的桌面端**不走** devicepool 的纯游客设备，
而是一直用 `content-config.json` 里那套带 `x-tt-token` / `cookie` 的会话。`devicepool.py` 注释里「游客可用」是 CLI 场景的结论，未必适用于播放接口。

### 下一步（需要凭据）

1. 从红果官方 App 取一份登录态，注入服务端已有的两个开关即可，无需改代码：
   `HG_COOKIE`（整条 cookie）、`HG_TT_TOKEN`（`x-tt-token`）。
   设好后 `/api/tracks?vid=...` 会带着会话重新签名重试。
2. 或者抓一份官方客户端的**成功** player 请求（URL + 全部请求头 + body），
   逐字节对齐即可定位还差哪个头/哪个参数。

### 顺带修掉的镜像问题

`unidbg` 的 JNI 库 `natives/linux_64/libunicorn_java.so` 是 glibc 编译的，
Alpine/musl 下 `System.loadLibrary` 直接 `UnsatisfiedLinkError: no unicorn_java`，
表现是签名进程端口起来了但线程当场死掉，`/healthz` 里的 `signer:true` 还会骗人（它只判断 `SIGNER_URL` 非空）。
`server/Dockerfile` 已改为 `python:3.12-slim` + `openjdk-21-jre-headless`（Debian 13 只有 21/25）。
