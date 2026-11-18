#!/usr/bin/env bash
# 1:10 战役（reproduce 口径）——对应 aarch64: start_bench_ratio10.sh
# 用法与 aarch64 完全一致：./launch_in_ns.sh bash start_bench_ratio10.sh
# 差别：参数不硬编码在本脚本，全部读同目录 machine.env（换机器只改那一个文件）
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
RATIO=10 exec bash "$HERE/start_bench.sh" "$@"
