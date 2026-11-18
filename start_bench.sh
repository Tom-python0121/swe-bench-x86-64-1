#!/usr/bin/env bash
# start_bench.sh —— x86-64 战役脚本（可搬迁版，合并原 start_bench_ratio{1,4,6,8}.sh 为单脚本）
# 用法: RATIO=4 ./start_bench.sh        （或 ./launch_in_ns.sh ./start_bench.sh 环境）
#       RATIO 缺省取 machine.env 的 RATIOS 第一个值
# 口径 = 165 reproduce 系列（base 384/interval 0.05/request-timeout 300/stop-on-failure），
#        BASE_N 已走 machine.env，新机器按规格填；改任何口径参数须在战役记录中标注
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/machine.env"

RATIO=${RATIO:-$(echo $RATIOS | awk '{print $1}')}
OUT=$RESULTS_ROOT/reproduce-${MACHINE_TAG}-ratio-$RATIO
mkdir -p "$OUT/bench"
LOG=$OUT/orchestrator.log

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

log "########## 战役开始 $MACHINE_TAG 1:$RATIO base=$BASE_N 内核=$(uname -r) arch=$(uname -m) ##########"
log "口径: interval=$LAUNCH_INTERVAL_SEC cmd-timeout=$COMMAND_TIMEOUT_SEC req-timeout=$REQUEST_TIMEOUT_SEC stop-on-failure=1 cgroup=$CG_LIMIT_GIB GiB"

# API key：machine.env 没填就从私有实例 api-key 文件取（兼容 e2b_ 风格与裸 key 风格）
KEY=$E2B_API_KEY
if [ -z "$KEY" ]; then
  AKF="$RUNTIME_HOME/home/api-key"
  if [ -f "$AKF" ]; then
    KEY=$(grep -o "e2b_[a-f0-9]*" "$AKF" 2>/dev/null | head -1 || true)
    [ -z "$KEY" ] && KEY=$(head -1 "$AKF" | tr -d '[:space:]')
  fi
  [ -z "$KEY" ] && { log "ERROR: E2B_API_KEY 未配置且 $AKF 不可读"; exit 1; }
fi

export PATH="$SUITE/.venv/bin:$PATH"
export PYTHONPATH="$SDK_OVERLAY"
export NO_PROXY="*"
export E2B_API_URL="http://127.0.0.1:$API_PORT"
export E2B_SANDBOX_URL="http://127.0.0.1:$API_PORT"
export AWBS_SANDBOX_GOPROXY="https://goproxy.cn"
export E2B_API_KEY="$KEY"
# 模板/快照基址：指向私有实例 home 下的 artifacts（relaunch 已 bind 到大存储）
export SNAP_BASE="$RUNTIME_HOME/home/persisted-sandboxes/artifacts"
export DISKS="$DISKS"
ulimit -n 262144

# 资源监控（每 5s 采一行，字段与 165 口径一致，agg 脚本可直接吃）
echo "ts,memavail_kb,anon_kb,commit_kb,fc_n,fc_rss_kb,ublk_n,cg_usage,pgmajfault,pgpgin,pgpgout,pswpin,pswpout,swap_used_kb,load1" > "$OUT/mem.csv"
touch "$OUT/.mon"
( while [ -f "$OUT/.mon" ]; do
    echo "$(date +%s),$(awk '/^MemAvailable:/{print $2}' /proc/meminfo),$(awk '/^AnonPages:/{print $2}' /proc/meminfo),$(awk '/^Committed_AS:/{print $2}' /proc/meminfo),$(ps -eo args | grep -c '[f]irecracker'),$(ps -eo rss,args | grep '[f]irecracker' | awk '{s+=$1}END{print s+0}'),$(ls /dev/ublkb* 2>/dev/null | wc -l),$(cat $CGROUP_DIR/memory.usage_in_bytes 2>/dev/null || echo 0),$(awk '/^pgmajfault/{print $2}' $CGROUP_DIR/memory.stat 2>/dev/null || echo 0),$(awk '/^pgpgin/{print $2}' $CGROUP_DIR/memory.stat 2>/dev/null || echo 0),$(awk '/^pgpgout/{print $2}' $CGROUP_DIR/memory.stat 2>/dev/null || echo 0),$(awk '/^pswpin/{print $2}' /proc/vmstat),$(awk '/^pswpout/{print $2}' /proc/vmstat),$(awk '/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{print t-f}' /proc/meminfo),$(cut -d' ' -f1 /proc/loadavg)" >> "$OUT/mem.csv"
    sleep 5
  done ) & MONPID=$!

cd "$SUITE"
SOF=""
[ "${STOP_ON_FAILURE:-1}" = "1" ] && SOF="--stop-on-failure"
log "runner 启动: python -m benchmark.agent_replay.runner bench --ratios $RATIO $SOF"
python -m benchmark.agent_replay.runner bench \
  --mode continuous --base-count $BASE_N \
  --trajectory-dir "$TRAJ_DIR" \
  --image-map "$IMAGE_MAP" \
  --ratios $RATIO --repeats 1 \
  --command-timeout-sec $COMMAND_TIMEOUT_SEC --command-timeout-continue \
  --request-timeout-sec $REQUEST_TIMEOUT_SEC --sandbox-timeout-sec $SANDBOX_TIMEOUT_SEC \
  --create-retries $CREATE_RETRIES --launch-interval-sec $LAUNCH_INTERVAL_SEC $SOF \
  --observability-interval-sec 1 \
  --output-dir "$OUT/bench" 2>&1 | tee -a "$OUT/runner.log" || log "WARN: runner 非零退出"

rm -f "$OUT/.mon"; sleep 6; kill -9 $MONPID 2>/dev/null || true
log "########## 战役结束 $MACHINE_TAG 1:$RATIO ##########"
log "结果: $OUT/bench/ratio-0$RATIO/repeat-01/"
