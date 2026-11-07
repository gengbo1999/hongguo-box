# 短剧盒子服务端镜像
#
# 构建上下文是仓库根目录:
#   docker build -f server/Dockerfile -t hongguo .
#
# 三个可选目录, 有就打包, 没有也能跑:
#   server/sign/       unidbg-sign.jar          -> 上游签名, 缺了就无签名直连
#   server/capture/    fq_oversea/{so,bin}      -> 签名进程依赖的 so 与证书
#   server/seed/       index.bin.z              -> 老客户端索引, 首次启动导入 SQLite
#
# 打包签名材料的姿势:
#   cp -r <app>/Contents/Resources/backend/sign      server/sign
#   cp -r <app>/Contents/Resources/backend/capture   server/capture
#   cp ShortDramaBox/Sources/Resources/index.bin.z   server/seed/index.bin.z

# 基础镜像必须是 glibc 系 (debian slim), 不能用 alpine.
# unidbg 的 JNI 库 natives/linux_64/libunicorn_java.so 是 glibc 编译的,
# 在 musl 上 System.loadLibrary 直接 UnsatisfiedLinkError: no unicorn_java,
# 签名进程虽然端口起来了但线程当场死掉, 表现就是 /sign 连不上.
FROM python:3.12-slim

# iproute2 提供 ss, 用来发现 unidbg 的临时监听端口
# nodejs 用于纯 JS 签名客户端 (server/sign/js/video_model.cjs)
# 换阿里云源: deb.debian.org 在构建机上多次 TLS 失败, 一失败整个构建就挂
RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
      sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources; \
    else \
      sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      openjdk-21-jre-headless iproute2 tzdata ca-certificates nodejs; \
    rm -rf /var/lib/apt/lists/*; \
    cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime; \
    echo "Asia/Shanghai" > /etc/timezone

WORKDIR /app

# 只 COPY 一个一定存在的目录, 其余用 shell 判断, 保证缺材料时镜像仍能构建
COPY server/ /app/src/

RUN set -eux; \
    mkdir -p /app/data; \
    cp -r /app/src/hg/. /app/; \
    cp /app/src/entrypoint.sh /app/entrypoint.sh; \
    chmod +x /app/entrypoint.sh; \
    if [ -d /app/src/sign ]; then cp -r /app/src/sign /app/sign; \
      echo "打包了签名 jar"; else echo "没有 server/sign, 跳过签名"; fi; \
    if [ -f /app/sign/js/video_model.cjs ]; then \
      echo "打包了 JS 取流脚本"; else echo "缺少 JS 取流脚本"; fi; \
    if [ -d /app/src/capture ]; then cp -r /app/src/capture /app/capture; \
      echo "打包了 capture"; else echo "没有 server/capture, 跳过"; fi; \
    if [ -f /app/src/seed/index.bin.z ]; then \
      mkdir -p /app/seed-index; \
      cp /app/src/seed/index.bin.z /app/seed-index/index.bin.z; \
      cp /app/src/seed/index.bin.z /app/data/index.bin.z; echo "打包了种子索引"; fi; \
    rm -rf /app/src

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TZ=Asia/Shanghai \
    PORT=8787 \
    HG_DB=/app/data/hongguo.db \
    HG_SEED_INDEX=/app/data/index.bin.z \
    HG_REFRESH_SEC=0

VOLUME ["/app/data"]
EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD python -c "import urllib.request,sys; \
sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8787/healthz',timeout=4).status==200 else 1)"

ENTRYPOINT ["/app/entrypoint.sh"]