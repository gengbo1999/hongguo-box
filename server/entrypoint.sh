#!/bin/sh
# 同一个容器里先拉起 unidbg 签名进程, 发现它的监听端口, 再起 web 服务。
# 签名进程必须常驻: 每次请求都冷启动 JVM 太慢, 而且 unidbg 初始化要几秒。
set -eu

JAR=/app/sign/unidbg-sign.jar
LOG=/tmp/signer.log
PORT=""

if [ -f "$JAR" ]; then
  ( cd /app/sign && exec java \
      -Djava.net.preferIPv4Stack=true \
      --add-opens java.base/java.lang=ALL-UNNAMED \
      -Xmx512m -XX:+ExitOnOutOfMemoryError \
      -cp unidbg-sign.jar com.hongguo.sign.FqTrace serve "${SIGNER_PORT:-0}" ) \
      > "$LOG" 2>&1 &
  JPID=$!
  echo "[entry] signer pid=$JPID, 等待监听端口"

  # 日志护栏: 签名进程一旦进入异常自旋会疯狂刷日志(实测见过 26GB), 定期截断
  (
    while :; do
      sleep 30
      sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
      if [ "${sz:-0}" -gt 5000000 ]; then : > "$LOG"; fi
    done
  ) &
  GUARD=$!

  i=0
  while [ "$i" -lt 120 ]; do
    PORT=$(ss -ltnp 2>/dev/null | awk -v p="$JPID" 'index($0, "pid=" p ",") {print $4}' \
           | sed 's/.*://' | head -1)
    [ -n "${PORT:-}" ] && break
    if ! kill -0 "$JPID" 2>/dev/null; then
      echo "[entry] signer 已退出, 末尾日志:"
      tail -20 "$LOG" || true
      PORT=""
      break
    fi
    i=$((i + 1))
    sleep 1
  done

  if [ -n "${PORT:-}" ] && [ "$PORT" != "0" ]; then
    export SIGNER_URL="http://127.0.0.1:$PORT"
    echo "[entry] signer 就绪 $SIGNER_URL"
  else
    echo "[entry] 未拿到签名端口, /resolve 将无签名直连"
  fi
  grep -E '启动|init|就绪' "$LOG" 2>/dev/null | tail -5 || true
else
  echo "[entry] 没打包 $JAR, /resolve 走无签名直连(索引与站点接口不受影响)"
fi

exec python /app/app.py