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

FROM python:3.12-alpine

# iproute2 提供 ss, 用来发现 unidbg 的临时监听端口
# 换阿里云源: dl-cdn.alpinelinux.org 在 GitHub runner 上多次 TLS 失败, 一失败整个构建就挂
RUN sed -i 's|https://dl-cdn.alpinelinux.org/alpine|https://mirrors.aliyun.com/alpine|g' /etc/apk/repositories \
    && apk add --no-cache openjdk17-jre-headless iproute2 tzdata ca-certificates \
    && cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone

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