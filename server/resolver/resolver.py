#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
短剧盒子 · 取流签名网关（signing gateway）

为什么存在这个服务：
    红果的 `multi_video_model` 接口在 2026-10-21 之后对匿名请求静默拒绝
    （HTTP 200 + 空 body），真正能拿到 1080p 的是加签后的请求：
      X-Argus / X-Gorgon / X-Khronos / X-Soter / x-ss-stub
    签名逻辑在 Android 的 libhongguo_signer.so 里，只能跑 bionic 环境。
    把它放到服务端的好处：签名方案一旦打通，**只部署服务端即可生效**，
    不用重新给 iPhone 打包、不用重新侧载。

设计要点：
    1. 客户端把「本来要发的请求」整包交给本服务（host/path/query/body）。
    2. 本服务用插件（SIGNER_CMD）加签，然后转发。
    3. 没配签名插件时，退化成透传 —— 行为和客户端直连完全一致，
       所以客户端那边可以放心用「服务端优先、失败回退本地」。

只依赖 Python 标准库，方便在 k3s-master 上直接跑，不需要 pip install。

用法：
    python3 resolver.py                    # 监听 0.0.0.0:8787
    PORT=9000 python3 resolver.py
    SIGNER_CMD=/opt/signer/sign.py python3 resolver.py

接口：
    GET /healthz
        → {"ok": true, "signer": "none"|"cmd", "version": "..."}
    POST /resolve
        body: {"host": "...", "path": "...", "query": {...}, "body": {...}}
        → {"ok": true, "status": 200, "data": {...}}
          失败时 ok=false 并带 error，客户端据此回退到本地直连。
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock

SERVICE_VERSION = "1.0.16"
DEFAULT_PORT = 8787
UPSTREAM_TIMEOUT = 12  # 秒；客户端那边超时是 20 秒，这里要更快，好让客户端及时回退

# 默认 UA：与原生客户端一致（Cronet）
DEFAULT_UA = (
    "com.ss.android.ugc.aweme/73532 (Linux; U; Android 13; zh_CN; "
    "Pixel 6; Build/TQ3A.230805.001; Cronet/58.0.2991.0)"
)

# 允许转发的上游 host 白名单，避免这个服务被当成任意代理
ALLOWED_HOSTS = {
    "api5-normal-sinfonlineb.fqnovel.com",
    "api5-normal-sinfonlinea.fqnovel.com",
    "c.fqnovel.com",
    "hongguoduanju.com",
}

# 简单内存缓存：同样的请求 5 分钟内不重复打上游
_CACHE = {}
_CACHE_LOCK = Lock()
_CACHE_TTL = 300


def cache_get(key):
    with _CACHE_LOCK:
        item = _CACHE.get(key)
        if not item:
            return None
        ts, value = item
        if time.time() - ts > _CACHE_TTL:
            _CACHE.pop(key, None)
            return None
        return value


def cache_put(key, value):
    with _CACHE_LOCK:
        # 粗暴限容，避免长期运行把内存吃满
        if len(_CACHE) > 4096:
            _CACHE.clear()
        _CACHE[key] = (time.time(), value)


def sign_headers(url, method, body_bytes):
    """
    调用外部签名插件。

    插件契约（简单、语言无关）：
        stdin  : {"url": ..., "method": ..., "body": "<base64>"}
        stdout : {"headers": {"X-Argus": "...", ...}}
    插件返回非 0 或输出不合法时，本函数返回空 dict（退化为不加签）。
    """
    cmd = os.environ.get("SIGNER_CMD", "").strip()
    if not cmd:
        return {}
    import base64

    payload = json.dumps(
        {
            "url": url,
            "method": method,
            "body": base64.b64encode(body_bytes or b"").decode("ascii"),
        }
    ).encode("utf-8")
    try:
        proc = subprocess.run(
            cmd.split(),
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=8,
        )
    except Exception as exc:  # noqa: BLE001 - 插件挂了不能让服务挂
        print("signer failed: %r" % (exc,), file=sys.stderr, flush=True)
        return {}
    if proc.returncode != 0:
        print(
            "signer exit %d: %s" % (proc.returncode, proc.stderr[:400]),
            file=sys.stderr,
            flush=True,
        )
        return {}
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except Exception:  # noqa: BLE001
        return {}
    headers = out.get("headers") or {}
    if not isinstance(headers, dict):
        return {}
    # 只接受字符串值，防止插件返回奇怪东西污染请求头
    return {str(k): str(v) for k, v in headers.items() if isinstance(v, (str, int, float))}


def build_request(spec):
    host = str(spec.get("host") or "").strip()
    path = str(spec.get("path") or "").strip()
    if not host or not path:
        raise ValueError("host 和 path 必填")
    if host not in ALLOWED_HOSTS:
        raise ValueError("host 不在白名单：%s" % host)
    if not path.startswith("/"):
        raise ValueError("path 必须以 / 开头")

    query = spec.get("query") or {}
    if not isinstance(query, dict):
        raise ValueError("query 必须是对象")
    qs = urllib.parse.urlencode({str(k): str(v) for k, v in query.items()})
    url = "https://%s%s" % (host, path)
    if qs:
        url += "?" + qs
    return url, qs


def fetch(spec):
    url, _ = build_request(spec)

    method = str(spec.get("method") or "POST").upper()
    body = spec.get("body")
    if body is None:
        body_bytes = b""
    elif isinstance(body, str):
        body_bytes = body.encode("utf-8")
    else:
        body_bytes = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode(
            "utf-8"
        )

    cache_key = "%s|%s|%s" % (method, url, body_bytes)
    if method == "POST":
        cached = cache_get(cache_key)
        if cached is not None:
            return cached

    headers = {
        "User-Agent": str(spec.get("ua") or DEFAULT_UA),
        "Accept": "application/json",
        "Content-Type": "application/json",
    }
    extra = spec.get("headers")
    if isinstance(extra, dict):
        for k, v in extra.items():
            if isinstance(v, (str, int, float)):
                headers[str(k)] = str(v)
    # 签名头优先级最高，覆盖掉客户端带来的同名头
    headers.update(sign_headers(url, method, body_bytes))

    req = urllib.request.Request(url, data=body_bytes or None, method=method)
    for k, v in headers.items():
        req.add_header(k, v)

    try:
        with urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT) as resp:
            raw = resp.read()
            status = resp.status
    except urllib.error.HTTPError as exc:
        raw = exc.read() or b""
        status = exc.code
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": "upstream: %s" % (exc,)}

    text = raw.decode("utf-8", "replace")
    try:
        data = json.loads(text) if text else None
    except Exception:  # noqa: BLE001
        data = None

    # 关键判断：HTTP 200 但 body 为空 = 被静默拒绝。
    # 明确告诉客户端「这次没成」，它就会回退到本地直连，不会卡住。
    if status == 200 and not text.strip():
        return {
            "ok": False,
            "status": status,
            "error": "empty_body",
            "hint": "上游静默拒绝，签名未生效",
        }

    result = {"ok": True, "status": status, "bytes": len(raw), "data": data}
    if data is None:
        result["text"] = text[:2000]
    if method == "POST":
        cache_put(cache_key, result)
    return result


class Handler(BaseHTTPRequestHandler):
    server_version = "ShortDramaBoxResolver/" + SERVICE_VERSION

    def _json(self, code, obj):
        payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler 约定
        if self.path.split("?")[0] in ("/healthz", "/health"):
            self._json(
                200,
                {
                    "ok": True,
                    "service": "shortdrama-resolver",
                    "version": SERVICE_VERSION,
                    "signer": "cmd" if os.environ.get("SIGNER_CMD") else "none",
                },
            )
            return
        self._json(404, {"ok": False, "error": "not found"})

    def do_POST(self):  # noqa: N802
        if self.path.split("?")[0] != "/resolve":
            self._json(404, {"ok": False, "error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > 1 << 20:
            self._json(400, {"ok": False, "error": "bad content length"})
            return
        try:
            spec = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:  # noqa: BLE001
            self._json(400, {"ok": False, "error": "invalid json"})
            return
        if not isinstance(spec, dict):
            self._json(400, {"ok": False, "error": "body must be object"})
            return
        try:
            self._json(200, fetch(spec))
        except ValueError as exc:
            self._json(400, {"ok": False, "error": str(exc)})
        except Exception as exc:  # noqa: BLE001
            self._json(500, {"ok": False, "error": "internal: %s" % (exc,)})

    def log_message(self, fmt, *args):  # 打干净点，方便 kubectl logs 看
        sys.stderr.write(
            "%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), fmt % args)
        )


def main():
    port = int(os.environ.get("PORT", DEFAULT_PORT))
    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(
        "resolver listening on 0.0.0.0:%d (signer=%s)"
        % (port, "cmd" if os.environ.get("SIGNER_CMD") else "none"),
        flush=True,
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()