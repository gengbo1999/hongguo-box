"""上游（红果/番茄）播放接口调用封装。

上游要求请求携带 X-Argus / X-Gorgon / X-Khronos / X-Soter 等 Metasec 签名，
签名算法在 libmetasec_ml.so 里跑, 只能由 unidbg-sign.jar 在本机进程内完成。
所以: 服务端起一个常驻 java 签名进程, 通过 HTTP 暴露 /sign, 本模块只负责
- 维护一个自洽的设备身份(device_id/iid/cdid/brand/model/res/os 与 UA 对齐)
- 拼 query(含 _rticket)、算 x-ss-stub
- 把 (url, headers) 交给签名进程, 拿到签名头后再发请求
"""

from __future__ import annotations

import hashlib
import json
import os
import random
import shutil
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import uuid

DEFAULT_HOST = os.environ.get("HG_API_HOST", "https://api5-normal-sinfonlineb.fqnovel.com")
DEFAULT_CHANNEL = os.environ.get("HG_CHANNEL", "update_64")
APP_VC = "72232"
TTOK = "3.12.13.20"

# ------------------------------------------------ 登录态（cookie / x-tt-token）
# 游客访问 video_model 家族会被上游直接返回 0 字节, 必须携带真实登录态。
# 目前只能靠环境变量 HG_COOKIE / HG_TT_TOKEN 预置; set_session() 是留给
# 以后 /api/session 路由的入口(暂未接)。未设置时行为与之前完全一致。
SESSION_LOCK = threading.Lock()
SESSION = {
    "cookie": os.environ.get("HG_COOKIE", "").strip(),
    "tt_token": os.environ.get("HG_TT_TOKEN", "").strip(),
}


def set_session(cookie=None, tt_token=None):
    """写入登录态。传 None 表示不动该字段, 传空串表示清除。"""
    with SESSION_LOCK:
        if cookie is not None:
            SESSION["cookie"] = (cookie or "").strip()
        if tt_token is not None:
            SESSION["tt_token"] = (tt_token or "").strip()
    return session_status()


def session_status():
    with SESSION_LOCK:
        cookie = SESSION["cookie"]
        token = SESSION["tt_token"]
    return {
        "cookie": bool(cookie),
        "cookie_len": len(cookie),
        "tt_token": bool(token),
        "tt_token_len": len(token),
    }


def _apply_session(headers):
    with SESSION_LOCK:
        cookie = SESSION["cookie"]
        token = SESSION["tt_token"]
    if cookie:
        headers["cookie"] = cookie
    if token:
        headers["x-tt-token"] = token
    return headers

PHONE_PROFILES = [
    {"brand": "Redmi", "model": "22041211AC", "build": "TKQ1.220807.001", "res": "1080*2400", "os": "13", "api": "33"},
    {"brand": "Redmi", "model": "23021RAA2Y", "build": "UKQ1.230804.001", "res": "1080*2400", "os": "14", "api": "34"},
    {"brand": "OPPO", "model": "PEHM00", "build": "TP1A.220905.001", "res": "1080*2412", "os": "13", "api": "33"},
    {"brand": "vivo", "model": "V2218A", "build": "TP1A.220624.014", "res": "1080*2400", "os": "13", "api": "33"},
    {"brand": "OnePlus", "model": "PHB110", "build": "UKQ1.230924.001", "res": "1240*2772", "os": "14", "api": "34"},
    {"brand": "HONOR", "model": "FNE-AN00", "build": "HONORFNE-AN00", "res": "1080*2412", "os": "13", "api": "33"},
]

QUALITY_ORDER = ["1080p", "720p", "540p", "480p", "360p"]

_lock = threading.Lock()
_device = None


class UpstreamError(RuntimeError):
    """上游返回了非预期内容。"""

    def __init__(self, code, detail=""):
        super().__init__(f"{code}: {detail}" if detail else str(code))
        self.code = code
        self.detail = detail


def _digits(n):
    return "".join(random.choice("0123456789") for _ in range(n))


def new_device():
    """生成一套自洽的游客设备身份（上游不校验 device_id 是否注册）。"""
    p = random.choice(PHONE_PROFILES)
    return {
        "query": {
            "device_id": _digits(16),
            "iid": _digits(16),
            "cdid": str(uuid.uuid4()),
            "device_brand": p["brand"],
            "device_type": p["model"],
            "resolution": p["res"],
            "os_version": p["os"],
            "os_api": p["api"],
            "rom_version": f"{p['build']} release-keys",
        },
        "user_agent": (
            f"com.phoenix.read/{APP_VC} (Linux; U; Android {p['os']}; zh_CN; "
            f"{p['model']}; Build/{p['build']};tt-ok/{TTOK})"
        ),
    }


def current_device():
    global _device
    with _lock:
        if _device is None:
            _device = new_device()
        return _device


def rotate_device():
    global _device
    with _lock:
        _device = new_device()
        return _device


def base_query():
    return {
        "aid": "8662",
        "app_name": "novelread",
        "version_code": APP_VC,
        "version_name": "7.2.2.32",
        "channel": DEFAULT_CHANNEL,
        "device_platform": "android",
        "update_version_code": APP_VC,
    }


def build_query(extra=None):
    q = base_query()
    q.update(current_device()["query"])
    if extra:
        q.update({k: v for k, v in extra.items() if v not in (None, "")})
    return q


def build_url(host, path, extra=None):
    q = build_query(extra)
    q["_rticket"] = str(int(time.time() * 1000))
    qs = "&".join(
        f"{k}={urllib.parse.quote(str(v), safe='')}" for k, v in q.items()
    )
    return f"{host}{path}?{qs}"


def _signer_url():
    url = os.environ.get("SIGNER_URL", "").strip()
    if url:
        return url.rstrip("/")
    for part in os.environ.get("SIGN_SERVERS", "").split(","):
        part = part.strip()
        if part:
            return part.rstrip("/")
    return ""


def signer_available():
    return bool(_signer_url())


def sign(url, headers, timeout=40):
    """调用常驻签名进程。没有配置签名服务时返回 None（上游也可能照样放行）。"""
    base = _signer_url()
    if not base:
        return None
    data = json.dumps({"url": url, "headers": headers}, ensure_ascii=False).encode()
    req = urllib.request.Request(
        base + "/sign",
        data=data,
        headers={"content-type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            payload = json.loads(r.read().decode() or "{}")
    except Exception as e:  # noqa: BLE001
        raise UpstreamError("signer_unavailable", repr(e)) from e
    if not isinstance(payload, dict):
        raise UpstreamError("signer_bad_reply", str(payload)[:200])
    if payload.get("error"):
        raise UpstreamError("signer_error", str(payload["error"])[:200])
    return {str(k): str(v) for k, v in payload.items() if v is not None}


def _request_json(url, body, headers, timeout=30):
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            status = r.status
    except urllib.error.HTTPError as e:  # noqa: F821
        raw = e.read()
        status = e.code
    if not raw:
        raise UpstreamError("upstream_empty", f"HTTP {status} 0 bytes")
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except ValueError as e:
        raise UpstreamError("upstream_bad_json", raw[:120].decode("utf-8", "replace")) from e


def post(path, body, extra_query=None, signed=True, host=None, timeout=30, retries=2):
    """POST 一个上游接口，并对「空响应」做有限重试。

    游客态下 video_model 家族偶尔会回 HTTP 200 + 0 字节（上游桌面端 1.0.16
    就是为此加了「最多两次延迟重试」）。这不是签名失效，重试通常就有数据。

    重试时整段头重建、重新签名：X-Khronos 是时间戳，复用旧签名反而会被拒。
    """
    host = (host or DEFAULT_HOST).rstrip("/")
    url = build_url(host, path, extra_query)
    dev = current_device()
    raw = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    stub = hashlib.md5(raw).hexdigest().upper()

    last = None
    for attempt in range(retries + 1):
        headers = {
            "user-agent": dev["user_agent"],
            "content-type": "application/json; charset=utf-8",
            "accept": "application/json",
            "sdk-version": "2",
            "x-ss-stub": stub,
        }
        _apply_session(headers)
        if signed:
            got = sign(url, headers)
            if got:
                headers.update(got)
        headers.pop("accept-encoding", None)
        try:
            return _request_json(url, raw, headers, timeout=timeout)
        except UpstreamError as e:
            if e.code != "upstream_empty" or attempt >= retries:
                raise
            last = e
        time.sleep(0.6 + attempt * 0.8)
    raise last  # pragma: no cover - 循环内已经 raise，这里只为满足静态检查


def video_model(vid, signed=True, host=None):
    return post(
        "/novel/player/video_model/v1/",
        {"video_id": vid, "content_type": 1,
         "biz_param": {"need_all_video_definition": True, "video_platform": 3}},
        signed=signed, host=host,
    )


def multi_video_model(vid, platform=1024, signed=True, host=None):
    """批量取流。platform=1024 是实测能拿到 1080p 的那条路径。

    请求体必须是「一次多档」形态：`mixed_video_id_map` 把同一个 vid 归到
    一个分组里，上游才会把 1080p/720p/480p 一次性全部下发。早先这里发的是
    单条 `video_id`，上游只回低档位甚至回空，外部表现就是「只有 360p」。

    分组键 `"1"` 只是序号；返回的 `mixed_video_id_map` 会按同一个键回带，
    所以取哪个键都能对回来（见 app.py 的 `_wanted_vids`）。
    """
    return post(
        "/novel/player/multi_video_model/v1/",
        {"biz_param": {"video_platform": platform,
                       "need_all_video_definition": True},
         "mixed_video_id_map": {"1": [str(vid)]}},
        signed=signed, host=host,
    )


def _decoded_url(v):
    v = (v or "").strip()
    if not v:
        return ""
    if v.startswith("http://") or v.startswith("https://"):
        return v
    try:
        import base64
        out = base64.b64decode(v, validate=False).decode("utf-8", "replace")
        if out.startswith("http"):
            return out
    except Exception:  # noqa: BLE001
        pass
    return v


def parse_tracks(payload):
    """把上游 JSON 解析成档位列表。"""
    data = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(data, dict):
        data = payload if isinstance(payload, dict) else {}
    lists = []
    vm = data.get("video_model")
    if isinstance(vm, dict) and isinstance(vm.get("video_list"), list):
        lists.append(vm["video_list"])
    if isinstance(data.get("video_list"), list):
        lists.append(data["video_list"])
    # 纯 JS 取流返回的是 {data: {<vid>: {video_model: "<json>"}}}，需要再挖一层
    for entry in data.values():
        if not isinstance(entry, dict):
            continue
        ev = entry.get("video_model")
        if isinstance(ev, str) and ev.lstrip().startswith("{"):
            try:
                ev = json.loads(ev)
            except ValueError:
                continue
        if isinstance(ev, dict) and isinstance(ev.get("video_list"), list):
            lists.append(ev["video_list"])

    tracks = []
    for vlist in lists:
        for item in vlist:
            if not isinstance(item, dict):
                continue
            meta = item.get("video_meta") if isinstance(item.get("video_meta"), dict) else {}
            enc = item.get("encrypt_info") if isinstance(item.get("encrypt_info"), dict) else {}
            url = _decoded_url(item.get("main_url") or item.get("backup_url") or item.get("url"))
            if not url:
                continue
            tracks.append({
                "definition": str(meta.get("definition") or item.get("definition") or ""),
                "width": int(meta.get("vwidth") or 0),
                "height": int(meta.get("vheight") or 0),
                "size": int(meta.get("size") or 0),
                "codec": str(meta.get("codec_type") or ""),
                "url": url,
                "spadeA": str(enc.get("spade_a") or ""),
                # 红果对 VIP 集用 cenc-aes-ctr 加密（stsd=encv），AVPlayer 解不了
                "encrypted": bool(enc.get("encrypt")),
            })
    return tracks


def pick_best(tracks):
    """按 1080p→360p 顺序取最高可用档位。"""
    by_def = {}
    for t in tracks:
        d = t["definition"].lower()
        if d and d not in by_def:
            by_def[d] = t
    for q in QUALITY_ORDER:
        if q in by_def:
            return by_def[q]
    hi = [t for t in tracks if t["height"] >= 1080]
    if hi:
        return max(hi, key=lambda t: t["size"])
    return max(tracks, key=lambda t: t["size"]) if tracks else None


_JS_SCRIPT = os.environ.get("HG_JS_VIDEO", "/app/sign/js/video_model.cjs")
_JS_CACHE = {}
_JS_TTL = 300

# 落盘缓存钩子（由 app.py 注册到 SQLite）。进程内缓存只活 5 分钟、
# 且随 pod 重启清空；而冷启动一次 js_video_model 要 6-7 秒，
# 客户端 /resolve 超时只有 8 秒，正好卡在边缘 —— 必须把结果落盘，
# 让重启后第一次取流也是毫秒级，否则用户会间歇性「播不了」。
_CACHE_HOOKS = {"get": None, "put": None}


def set_cache_hooks(get, put):
    _CACHE_HOOKS["get"], _CACHE_HOOKS["put"] = get, put
_JS_CACHE_MAX = 256


def _node_bin():
    return os.environ.get("NODE_BIN") or shutil.which("node") or "/usr/local/bin/node"


def js_video_model(vid, timeout=25):
    """用纯 JS 签名客户端取 video_model。

    unidbg 的签名能被上游接收，但 multi_video_model 会判 110001；这套 JS
    实现配已注册设备可以稳定拿到 5 档（含 1080p）。脚本不存在时直接抛
    UpstreamError，让调用方回退旧路径。
    """
    now = time.time()
    hit = _JS_CACHE.get(str(vid))
    if hit and now - hit[0] < _JS_TTL:
        return hit[1]
    # 进程内未命中, 看落盘缓存(跨 pod 重启仍有效)
    getter = _CACHE_HOOKS["get"]
    if getter:
        try:
            cached = getter(str(vid))
        except Exception:  # noqa: BLE001 缓存坏了就当没有
            cached = None
        if cached is not None:
            with _lock:
                _JS_CACHE[str(vid)] = (now, cached)
            return cached
    script = _JS_SCRIPT
    if not os.path.isfile(script):
        raise UpstreamError("js_missing", script)
    node = _node_bin()
    try:
        p = subprocess.run(
            [node, script, str(vid)],
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as e:
        raise UpstreamError("js_timeout", f"{timeout}s") from e
    except OSError as e:
        raise UpstreamError("js_node_missing", repr(e)) from e
    if p.returncode != 0:
        detail = (p.stderr or b"").decode("utf-8", "replace").strip()[:300]
        raise UpstreamError("js_failed", detail or f"exit {p.returncode}")
    try:
        payload = json.loads((p.stdout or b"").decode("utf-8", "replace"))
    except ValueError as e:
        raise UpstreamError("js_bad_json", repr(e)) from e
    code = payload.get("code", payload.get("Code")) if isinstance(payload, dict) else None
    if code not in (0, "0", None):
        msg = payload.get("message") or payload.get("Message") or code
        raise UpstreamError("js_upstream", str(msg)[:200])
    with _lock:
        if len(_JS_CACHE) >= _JS_CACHE_MAX:
            _JS_CACHE.clear()
        _JS_CACHE[str(vid)] = (now, payload)
    putter = _CACHE_HOOKS["put"]
    if putter:
        try:
            putter(str(vid), payload)
        except Exception:  # noqa: BLE001 写缓存失败不影响返回
            pass
    return payload


def resolve_tracks(vid, host=None):
    """依次尝试 JS 取流与三条 unidbg 路径，返回 (tracks, 诊断信息)。"""
    notes = []
    try:
        tracks = parse_tracks(js_video_model(vid))
        if tracks:
            return tracks, {"path": "js", "notes": notes}
        notes.append("js: no_tracks")
    except UpstreamError as e:
        notes.append(f"js: {e.code}")
    attempts = [
        ("multi1024", lambda: multi_video_model(vid, 1024, host=host)),
        ("multi3", lambda: multi_video_model(vid, 3, host=host)),
        ("single3", lambda: video_model(vid, host=host)),
    ]
    for name, fn in attempts:
        try:
            payload = fn()
        except UpstreamError as e:
            notes.append(f"{name}: {e.code}")
            continue
        tracks = parse_tracks(payload)
        if tracks:
            return tracks, {"path": name, "notes": notes}
        notes.append(f"{name}: no_tracks")
    return [], {"path": None, "notes": notes}