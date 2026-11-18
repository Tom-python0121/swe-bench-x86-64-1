#!/usr/bin/env bash
# bootstrap.sh —— 新机器初始化（可搬迁）：搭私有实例 + 拷 harness + 拷轨迹
# 用法: SEED=/data/cjn-aenv ./bootstrap.sh     （SEED = 种子 AgentENV 部署目录）
# 在 89 上验证时 SEED=/data/cjn-aenv；新 Zen5 机上 SEED=随包带过去的 x86 种子目录
# 布局说明：适配 cjn-aenv 布局（bin/ + home/{config,deps,ublk,api-key}），
#           大存储（image-cache/snapshot-store/persisted-sandboxes）走 $DATA_ROOT 由 relaunch bind
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/machine.env"

SEED=${SEED:?"用法: SEED=<种子aenv部署目录> ./bootstrap.sh   例: SEED=/data/cjn-aenv"}

echo "[bootstrap] 1/5 校验种子（x86_64 二进制 + 关键目录）"
file "$SEED/bin/server" | grep -q x86-64 || { echo "种子 server 不是 x86_64"; exit 1; }
for d in home/config home/deps home/ublk; do
  [ -d "$SEED/$d" ] || { echo "种子缺 $d（布局不符，检查 SEED）"; exit 1; }
done

echo "[bootstrap] 2/5 拷贝种子 → $RUNTIME_HOME"
mkdir -p "$RUNTIME_HOME"
cp -a "$SEED/bin"                     "$RUNTIME_HOME/bin"
mkdir -p "$RUNTIME_HOME/home"
cp -a "$SEED/home/config"             "$RUNTIME_HOME/home/config"
cp -a "$SEED/home/deps"               "$RUNTIME_HOME/home/deps"
cp -a "$SEED/home/ublk"               "$RUNTIME_HOME/home/ublk"       2>/dev/null || true
[ -f "$SEED/home/api-key" ]  && cp -a "$SEED/home/api-key"  "$RUNTIME_HOME/home/api-key"
[ -d "$SEED/home/secrets" ]  && cp -a "$SEED/home/secrets"  "$RUNTIME_HOME/home/secrets"
# 私有实例独立于种子的运行时目录
mkdir -p "$RUNTIME_HOME/run" "$RUNTIME_HOME/tmp"
# home 下的存储目录建空壳（relaunch 时 bind 大存储覆盖）
mkdir -p "$RUNTIME_HOME/home"/{image-cache,snapshot-store,persisted-sandboxes,firecracker-work,overlaybd,logs,snapshot-local-cache}

echo "[bootstrap] 3/5 建大存储目录（$DATA_ROOT）"
mkdir -p "$DATA_ROOT"/{service-data/{image-cache,snapshot-store,persisted-sandboxes,fc-writable-layers},results}
# 模板 artifacts 归位（persisted-sandboxes 的标准子结构）
# 注意：records.db 是 RocksDB 目录，由 server 首次启动自建——绝不要预创建文件！
mkdir -p "$DATA_ROOT/service-data/persisted-sandboxes"/{artifacts,repository}

echo "[bootstrap] 4/5 harness + 轨迹（若已就位则跳过）"
# harness（纯 Python）与 384 条轨迹（arch 无关）来源二选一：
#   a) 从 165 拷: /home/wuyihao/awbs165-suite-384-20261105/{agent-workload-benchmark-suite-fixed-v4,sdk-overlay-v4,inputs-v2}
#   b) 从本地包: agent-workload-benchmark-suite 仓库 + replays 目录
[ -d "$SUITE" ]    || echo "  !! $SUITE 不存在——请先放入 runner suite（来源见本文件注释）"
[ -d "$TRAJ_DIR" ] || echo "  !! $TRAJ_DIR 不存在——请先放入 384 条 replays + image-map.json"

echo "[bootstrap] 5/5 Python venv（suite 依赖）"
if [ -d "$SUITE" ] && [ ! -x "$SUITE/.venv/bin/python" ]; then
  python3 -m venv "$SUITE/.venv"
  ( "$SUITE/.venv/bin/pip" install -r "$SUITE/benchmark/agent_replay/requirements.txt" 2>/dev/null || \
    "$SUITE/.venv/bin/pip" install -r "$SUITE/requirements.txt" 2>/dev/null || \
    echo "  !! 自动装依赖失败，请手工安装" )
fi

echo "[bootstrap] 完成。下一步：./relaunch_server.sh && ./health_check.sh"
echo "             然后挑一个已建模板: ./launch_in_ns.sh python3 sdk_probe.py <模板名>"
