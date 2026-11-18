#!/usr/bin/env bash
# health_check.sh —— 私有 server 起来后的健康检查（netns 内 curl /health）
# 用法: ./health_check.sh [超时秒数，默认 120]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/machine.env"

TMO=${1:-120}
S=$(pgrep -f "bin/server$" | head -1)
[ -z "$S" ] && { echo "[health] 私有 server 未运行（先 ./relaunch_server.sh）"; exit 1; }
echo "[health] server pid=$S netns=$(readlink /proc/$S/ns/net)"

t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt "$TMO" ]; do
  if nsenter -t "$S" -n -- curl -s -o /dev/null -m 3 "http://127.0.0.1:$API_PORT/health" 2>/dev/null; then
    echo "[health] OK: 127.0.0.1:$API_PORT/health 可达（netns 内）"
    echo "[health] 验证命令: ./launch_in_ns.sh python3 sdk_probe.py <模板名>"
    exit 0
  fi
  sleep 3
done
echo "[health] 超时：$API_PORT/health 不可达。排查: tail -50 $RUNTIME_HOME/server.log"
exit 1
