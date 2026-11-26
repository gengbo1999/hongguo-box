"""7.4.3.32 MetaSec 取流（hg-signer sidecar + SDI token）。

上游在 2026-11-17 前后把取流门槛换到红果 APK **7.4.3.32** 的 Metasec：
签名要跑 APK 里 4.5MB 的 field13 VM（`x-medusa` 容器），并且必须用
「已注册的 iid + device_id + 注册 cookie」——匿名或身份/cookie 不配对时
上游一律回 `HTTP 200 + 0 字节`（静默拒绝，不是签名错）。

这里不做算法，只做编排：
1. `server/sign/v5` 里的 Rust `hg-signer` 负责 field13 VM 与 6 个签名头；
2. 本模块负责 SDI token 交换（`/sdi/get_token`）、身份/cookie、HTTP 与缓存。

对外只有 `available()` / `video_model(vid)` 两个入口，异常统一是
`MetaSecError`，`code` 供调用方记诊断信息。
"""

from __future__ import annotations

import base64
import gzip
import json
import os
import random
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

ORIGIN = os.environ.get("HG_METASEC_ORIGIN", "https://api5-normal-sinfonlineb.fqnovel.com")
PLAYER_PATH = "/novel/player/multi_video_model/player/v1"
PRELOAD_PATH = "/novel/player/multi_video_model/preload/v1"
DETAIL_PATH = "/novel/player/multi_video_detail/v1"
SDI_ORIGIN = "https://mssdk.zijieapi.com"
SDI_PATH = "/sdi/get_token"

# 材料（授权材料在 APK 里，用 HTTP Range 取两段后解压，缓存 5.4MB）
APK_URL = os.environ.get(
    "HG_METASEC_APK",
    "https://lf9-apk.ugapk.cn/package/apk/novelread/12267_74332/"
    "novelread_78105987a_v12267_74332_b929_1793271281.apk?v=1793271287",
)
DEX_RANGE = (64_901_723, 3_915_212)
ELF_RANGE = (112_946_914, 1_497_823)

def _pick_root():
    """仓库里是 server/hg/metasec.py(根 = server), 镜像里是平铺的 /app/metasec.py
    (根 = /app)。两种布局都要能找到 sign/: 先看上一级, 再看自己这一级。"""
    here = os.path.dirname(os.path.abspath(__file__))
    for candidate in (os.path.dirname(here), here):
        if os.path.isdir(os.path.join(candidate, "sign")):
            return candidate
    return os.path.dirname(here)


_ROOT = _pick_root()
_SIGN_DIR = os.environ.get("HG_SIGN_DIR", os.path.join(_ROOT, "sign", "v5"))
def _first_file(*candidates):
    for path in candidates:
        if path and os.path.isfile(path):
            return path
    return candidates[-1]


_BIN = os.environ.get("HG_SIGNER_BIN") or _first_file(
    os.path.join(_SIGN_DIR, "hg-signer"),
    os.path.join(_SIGN_DIR, "target", "release", "hg-signer"),
    os.path.join(_ROOT, "sign", "hg-signer"),
)
_IDENT_JS = os.path.join(_ROOT, "sign", "js", "identity.cjs")
def _data_dir():
    """状态/身份文件落盘目录：优先 HG_DB 所在目录（容器里是 /app/data），
    其次仓库的 server/var（本地开发）；都没有就退化为进程内缓存。"""
    db = os.environ.get("HG_DB") or ""
    if db:
        return os.path.dirname(os.path.abspath(db))
    local = os.path.join(_ROOT, "var")
    if os.path.isdir(local):
        return local
    return ""


_STATE = os.environ.get("HG_METASEC_STATE") or (
    os.path.join(_data_dir(), "metasec.json") if _data_dir() else ""
)

_CACHE = os.environ.get("HG_SIGNER_CACHE") or _first_file(
    os.path.join(_SIGN_DIR, "materials", "metasec-v5-74332.cache"),
    os.path.join(_data_dir(), "metasec-v5-74332.cache") if _data_dir() else "",
)

_TOKEN_TTL = 6 * 3600
_IDENT_TTL = 1800
_UA = ""  # 由 signer 侧决定（cronet UA），这里不重复

_lock = threading.RLock()


class MetaSecError(Exception):
    def __init__(self, code, detail=""):
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail


# --------------------------------------------------------------- 状态文件


def _load_state():
    if not _STATE:
        return {}
    try:
        with open(_STATE, "r", encoding="utf-8") as fp:
            data = json.load(fp)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_state(state):
    path = _STATE
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.tmp{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as fp:
            json.dump(state, fp)
        os.replace(tmp, path)
    except OSError:
        pass  # 状态写不下去只是变慢，不影响功能


# ------------------------------------------------------------------ signer


class _Signer:
    """常驻 `hg-signer serve`；进程崩了自动重启一次。"""

    def __init__(self):
        self._proc = None
        self._lock = threading.RLock()

    def _spawn(self):
        if not os.path.isfile(_BIN):
            raise MetaSecError("signer_missing", _BIN)
        if not os.path.isfile(_CACHE):
            raise MetaSecError("materials_missing", _CACHE)
        self._proc = subprocess.Popen(
            [_BIN, "serve", _CACHE],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )

    def call(self, **payload):
        with self._lock:
            for attempt in (0, 1):
                if self._proc is None or self._proc.poll() is not None:
                    self._spawn()
                try:
                    self._proc.stdin.write(json.dumps(payload) + "\n")
                    self._proc.stdin.flush()
                    line = self._proc.stdout.readline()
                except (OSError, ValueError):
                    self._proc = None
                    continue
                if not line:
                    self._proc = None
                    continue
                try:
                    reply = json.loads(line)
                except ValueError:
                    continue
                if not reply.get("ok", reply.get("ok") is True):
                    if reply.get("ok") is False:
                        return reply
                return reply
            raise MetaSecError("signer_dead", "hg-signer serve 无法启动")


_signer = _Signer()


def _call(**payload):
    with _lock:
        reply = _signer.call(**payload)
    if reply.get("ok") is False:
        raise MetaSecError(reply.get("error") or "signer_error")
    return reply


# ------------------------------------------------------------------ 材料


def _ensure_materials(timeout=60):
    """缓存不存在时按 Range 拉两段材料再解出缓存（只在首次启动做一次）。"""
    if os.path.isfile(_CACHE):
        return
    os.makedirs(os.path.dirname(_CACHE), exist_ok=True)
    parts = []
    for (start, length), name in ((DEX_RANGE, "dex.part"), (ELF_RANGE, "elf.part")):
        path = os.path.join(os.path.dirname(_CACHE), name)
        if not os.path.isfile(path) or os.path.getsize(path) != length:
            _download_range(start, length, path, timeout=timeout)
        parts.append(path)
    result = subprocess.run(
        [_BIN, "cache", parts[0], parts[1], _CACHE],
        capture_output=True,
        timeout=timeout,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        raise MetaSecError("materials_build", (result.stderr or "").strip()[:200])


def _download_range(start, length, path, timeout=60):
    req = urllib.request.Request(
        APK_URL,
        headers={"Range": f"bytes={start}-{start + length - 1}", "Accept-Encoding": "identity"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        if resp.status != 206:
            raise MetaSecError("materials_http", f"status {resp.status}")
        data = resp.read()
    if len(data) != length:
        raise MetaSecError("materials_short", f"{len(data)} != {length}")
    with open(path, "wb") as fp:
        fp.write(data)


def available():
    """签名器与材料都就绪才返回 True（不下载材料，避免启动时卡网络）。"""
    return os.path.isfile(_BIN)


# ------------------------------------------------------------------ 身份


_IDENT = {"at": 0.0, "value": None}


def identity(force=False):
    """已注册身份：device_id / install_id / 注册 cookie（node 侧负责注册与落盘）。"""
    now = time.time()
    with _lock:
        if not force and _IDENT["value"] and now - _IDENT["at"] < _IDENT_TTL:
            return _IDENT["value"]
    if not os.path.isfile(_IDENT_JS):
        raise MetaSecError("identity_missing", _IDENT_JS)
    node = os.environ.get("NODE_BIN") or "node"
    env = dict(os.environ)
    data = _data_dir()
    if data and "HG_DEVICE_FILE" not in env:
        env["HG_DEVICE_FILE"] = os.path.join(data, "device.json")
    args = [node, _IDENT_JS] + (["--force"] if force else [])
    try:
        proc = subprocess.run(args, capture_output=True, timeout=45, check=False, env=env, text=True)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise MetaSecError("identity_spawn", repr(exc)) from exc
    if proc.returncode != 0:
        raise MetaSecError("identity_failed", (proc.stderr or "").strip()[:200])
    try:
        data = json.loads(proc.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError) as exc:
        raise MetaSecError("identity_json", repr(exc)) from exc
    if not data.get("device_id") or not data.get("install_id"):
        raise MetaSecError("identity_empty", json.dumps(data)[:200])
    with _lock:
        _IDENT["value"], _IDENT["at"] = data, now
    return data


def _device_profile(ident):
    """signer 的匿名档案 + 注册身份 iid/device_id；cdid 固定，避免每请求换身份。"""
    state = _load_state()
    cdid = state.get("cdid") or ""
    seed = _call(op="anonymous", cdid=cdid)
    dev = seed.get("device") or {}
    if not cdid:
        state["cdid"] = seed.get("cdid") or ""
        _save_state(state)
    dev["iid"] = ident["install_id"]
    dev["device_id"] = ident["device_id"]
    return dev


# ------------------------------------------------------------------ token


def _sdi_exchange(device, token=None):
    signed = _call(op="sdi", device=device, token=token or "")
    status, body, _ = _post(signed["url"], base64.b64decode(signed["body"]), signed["headers"])
    if status != 200 or not body:
        raise MetaSecError("sdi_http", f"status {status} len {len(body)}")
    decoded = _call(op="sdi-decode", packet=base64.b64encode(body).decode())
    return decoded.get("status"), decoded.get("token") or ""


def token(device, force=False):
    state = _load_state()
    now = time.time()
    if not force:
        cached = state.get("token")
        if cached and now - float(state.get("token_at") or 0) < _TOKEN_TTL:
            return cached
    status, value = _sdi_exchange(device)
    if status == 202 and value:
        status, value = _sdi_exchange(device, value)
    if status != 200 or not value:
        raise MetaSecError("token_status", str(status))
    state["token"], state["token_at"] = value, now
    _save_state(state)
    return value


# ------------------------------------------------------------------- HTTP


def _post(url, body, headers, timeout=15):
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(), dict(exc.headers)


def _biz_param(device_level):
    return {
        "detail_page_version": 0,
        "device_level": device_level,
        "disable_digg_stat": False,
        "disable_video_relate_book": False,
        "need_all_video_definition": True,
        "need_mp4_align": False,
        "use_os_player": False,
        "use_server_dns": False,
        "video_platform": 1024,
    }


def _payload(vid, device_level):
    return {
        "biz_param": _biz_param(device_level),
        "mixed_video_id_map": {"1004": [str(vid)]},
        "dr_scene": "player",
    }


def _detail_payload(sid):
    """分集详情：站点详情页只给 v1_ 不透明 token，上游按 series_id 换每集数字 vid。"""
    return {"series_id": str(sid), "biz_param": _biz_param(_DEVICE_LEVEL)}


# 取流时的 device_level。上游按这个值决定回哪套编码：
#   level 1 -> bytevc1（H.265，iOS/AVPlayer 能直接解）
#   level 2/3 -> bytevc2（H.266/VVC，iOS 没有解码器）
# 2026-11 的新剧一上线就只有 bytevc2，客户端拿到后 needsTranscode 为真、
# 又找不到可播档位转码，直接报「加载失败」——所以固定要 level 1。
# 上游对老剧（只有 bytevc1 片源）三个 level 结果一致，改这里不损失档位。
_DEVICE_LEVEL = int(os.environ.get("HG_METASEC_DEVICE_LEVEL") or 1)


def default_device_level():
    """默认 device_level（配置项，默认 1 = bytevc1）。"""
    return _DEVICE_LEVEL


def _signed_json(path, payload_obj, cookie=None, timeout=15):
    """把 payload 交给 hg-signer 签名后 POST 到 origin+path，返回解析后的 JSON。"""
    if not available():
        raise MetaSecError("signer_missing", _BIN)
    _ensure_materials()
    ident = identity()
    dev = _device_profile(ident)
    body = json.dumps(payload_obj, separators=(",", ":")).encode()
    cookie_value = cookie if cookie is not None else ident.get("cookies", "")

    def send(token_value):
        signed = _call(
            op="sign",
            device=dev,
            origin=ORIGIN,
            path=path,
            body=base64.b64encode(body).decode(),
            token=token_value,
        )
        headers = dict(signed["headers"])
        headers["Cookie"] = cookie_value
        return _post(
            signed["url"], base64.b64decode(signed["body"]), headers, timeout=timeout
        )

    token_value = token(dev)
    status, raw, resp_headers = send(token_value)
    if status == 200 and not raw:
        # 静默拒绝：token 大概率过期/被判失效，强制换一次再试
        status, raw, resp_headers = send(token(dev, force=True))
    if status != 200:
        raise MetaSecError("http_status", f"{status} {(raw or b'')[:120]!r}")
    if not raw:
        raise MetaSecError("empty_body", resp_headers.get("X-Tt-Logid") or resp_headers.get("x-tt-logid") or "")
    try:
        payload = json.loads(raw.decode("utf-8", "replace"))
    except ValueError as exc:
        raise MetaSecError("bad_json", repr(exc)) from exc
    code = payload.get("code") if isinstance(payload, dict) else None
    if code not in (0, "0", None):
        raise MetaSecError("upstream_code", f"{code} {payload.get('message') or ''}"[:200])
    return payload


def video_model(vid, device_level=None, cookie=None, timeout=15):
    """取单集的 video_model（含全部档位）。返回上游 JSON。

    device_level 省略时用 `HG_METASEC_DEVICE_LEVEL`（默认 1），
    显式传值只用于排查对比。
    """
    if device_level is None:
        device_level = _DEVICE_LEVEL
    return _signed_json(PLAYER_PATH, _payload(vid, device_level),
                        cookie=cookie, timeout=timeout)


def series_detail(sid, cookie=None, timeout=15):
    """取整部剧的分集详情（`video_list[].vid` 是上游数字视频 id）。

    站点详情页的 `vid_list` 从 2026-11 起改成了 `v1_...` 不透明 token，
    上游 multi_video_model 对这种 token 只回 `code:0 + data:{}`（等于没有
    片源）；这个接口按 series_id 把每集的数字 vid 换回来。
    """
    return _signed_json(DETAIL_PATH, _detail_payload(sid), cookie=cookie, timeout=timeout)


def status():
    """诊断用：签名器/材料/身份/token 的当前状态。"""
    out = {
        "signer": os.path.isfile(_BIN),
        "materials": os.path.isfile(_CACHE),
        "identity_script": os.path.isfile(_IDENT_JS),
        "origin": ORIGIN,
        "device_level": _DEVICE_LEVEL,
    }
    state = _load_state()
    out["cdid"] = bool(state.get("cdid"))
    out["token"] = bool(state.get("token"))
    if state.get("token_at"):
        out["token_age"] = int(time.time() - float(state["token_at"]))
    return out