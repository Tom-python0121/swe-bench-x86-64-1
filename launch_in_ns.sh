#!/usr/bin/env bash
# launch_in_ns.sh —— 在 aenv server 的 net namespace 内启动任意命令（通用，无需改动）
# 用法: ./launch_in_ns.sh <cmd...>   （如 ./launch_in_ns.sh ./start_bench_ratio4.sh）
set -euo pipefail
S=$(pgrep -f "bin/server$" | head -1)
if [ -z "${S:-}" ]; then echo "找不到 aenv server 进程" >&2; exit 1; fi
echo "[launch_in_ns] server pid=$S netns=$(readlink /proc/$S/ns/net)"
exec nsenter -t "$S" -n -p -m -- "$@"
