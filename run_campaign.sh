#!/usr/bin/env bash
# run_campaign.sh —— x86-64 超分战役编排（可搬迁版，多档位自动扫描）
# 对应 aarch64 参考-overcommit风格/run_*.sh 的完整编排能力：
#   每档位：残留沙箱清理 → server 健康 + create 探测 → baseline.json →
#   mem.csv 监控 → runner 启动（server netns 内）→ 停止条件（97% / 停滞 / 硬上限）→
#   DONE.txt 断点续跑 → 沙箱清理 → 下一档 → .all_done
# 用法: ./run_campaign.sh                     # 跑 machine.env 的 RATIOS（默认 1 2 4 6 8 10）
#       RATIOS="4 6" ./run_campaign.sh        # 只跑指定档（环境变量覆盖）
#       nohup ./run_campaign.sh &             # 长战役后台跑，tail -f orchestrator.log 观察
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
USER_RATIOS=${RATIOS:-}
source "$HERE/machine.env"
[ -n "$USER_RATIOS" ] && RATIOS=$USER_RATIOS

CAMPAIGN_ROOT=$RESULTS_ROOT/campaign-${MACHINE_TAG}-$(date +%Y%m%d)
mkdir -p "$CAMPAIGN_ROOT"
LOG=$CAMPAIGN_ROOT/orchestrator.log

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
cgstat(){ awk -v k="$1" '$1==k{print $2}' "$CGROUP_DIR/memory.stat" 2>/dev/null || echo 0; }

# ---- API key（e2b_ 前缀与裸 key 两种格式兼容）----
KEY=$E2B_API_KEY
if [ -z "$KEY" ]; then
  AKF="$RUNTIME_HOME/home/api-key"
  [ -f "$AKF" ] && { KEY=$(grep -o "e2b_[a-f0-9]*" "$AKF" 2>/dev/null | head -1 || true); \
                     [ -z "$KEY" ] && KEY=$(head -1 "$AKF" | tr -d '[:space:]'); }
fi
[ -z "$KEY" ] && { log "ERROR: API key 未配置（machine.env E2B_API_KEY 或 $RUNTIME_HOME/home/api-key）"; exit 1; }

# ---- 清理残留沙箱（走本实例 API，绝不 pkill firecracker——共机安全）----
cleanup_sandboxes(){
  local S ids id n=0
  S=$(pgrep -f "$RUNTIME_HOME/bin/server" | head -1 || true)
  [ -z "$S" ] && return 0
  ids=$(nsenter -t "$S" -n -- curl -s -m 15 "http://127.0.0.1:$API_PORT/sandboxes" \
        -H "X-API-Key: $KEY" 2>/dev/null | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    for s in (d if isinstance(d,list) else d.get("sandboxes",[])):
        print(s.get("sandboxID") or s.get("sandboxId") or "")
except Exception: pass' 2>/dev/null || true)
  for id in $ids; do
    [ -n "$id" ] && nsenter -t "$S" -n -- curl -s -o /dev/null -m 30 \
      -X DELETE "http://127.0.0.1:$API_PORT/sandboxes/$id" -H "X-API-Key: $KEY" 2>/dev/null || true
    n=$((n+1))
  done
  [ "$n" -gt 0 ] && log "  cleanup: 删除 $n 个残留沙箱"
  sleep 10
}

# ---- server 保障：健康检查 + 真实 create 探测（health 通过不代表创建就绪）----
ensure_server(){
  local S i
  S=$(pgrep -f "$RUNTIME_HOME/bin/server" | head -1 || true)
  if [ -z "$S" ] || ! nsenter -t "$S" -n -- curl -s -o /dev/null -m 3 "http://127.0.0.1:$API_PORT/health" 2>/dev/null; then
    log "  server 不在/不健康 → relaunch"
    "$HERE/relaunch_server.sh" || return 1
    S=$(pgrep -f "$RUNTIME_HOME/bin/server" | head -1)
    for i in $(seq 1 40); do
      sleep 3
      nsenter -t "$S" -n -- curl -s -o /dev/null -m 3 "http://127.0.0.1:$API_PORT/health" 2>/dev/null && break
    done
  fi
  log "  server health ok pid=$S"
  if [ -n "${PROBE_TEMPLATE:-}" ]; then
    local resp sid attempt
    for attempt in $(seq 1 20); do
      resp=$(nsenter -t "$S" -n -- curl -s -m 40 -X POST "http://127.0.0.1:$API_PORT/sandboxes" \
             -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
             -d "{\"templateID\":\"$PROBE_TEMPLATE\",\"timeout\":600}" 2>/dev/null || true)
      sid=$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("sandboxID") or json.load(sys.stdin).get("sandboxId") or "")
except Exception: print("")' 2>/dev/null || true)
      if [ -n "$sid" ]; then
        log "  create 探测成功 attempt=$attempt sid=$sid"
        nsenter -t "$S" -n -- curl -s -o /dev/null -m 60 -X DELETE \
          "http://127.0.0.1:$API_PORT/sandboxes/$sid" -H "X-API-Key: $KEY" 2>/dev/null || true
        sleep 8; return 0
      fi
      log "  create 探测失败 attempt=$attempt resp=${resp:0:80}"; sleep 5
    done
    log "  ERROR: server 创建功能未就绪（模板缺失或 runtime 问题）"; return 1
  else
    log "  （PROBE_TEMPLATE 未配置，跳过 create 探测——建议配置，health≠创建就绪）"
  fi
}

# ---- 单档位战役 ----
run_phase(){
  local ratio="$1"
  local out="$CAMPAIGN_ROOT/ratio-$ratio"
  local n=$((BASE_N * ratio))
  local jl t0 last_done last_change el_min pct idle_min done_n fin srv_pid
  if [ -f "$out/DONE.txt" ]; then log "跳过 1:$ratio（DONE.txt 存在，断点续跑）"; return 0; fi
  rm -rf "$out"; mkdir -p "$out/bench"
  log "===== 1:$ratio 开始: base=$BASE_N n=$n cgroup=${CG_LIMIT_GIB}GiB interval=$LAUNCH_INTERVAL_SEC ====="

  cleanup_sandboxes
  ensure_server || { log "ERROR: server 未就绪，1:$ratio 中止"; return 1; }

  cat > "$out/baseline.json" <<EOF
{"ts": $(date +%s), "kernel": "$(uname -r)", "arch": "$(uname -m)", "machine": "$MACHINE_TAG",
 "ratio": $ratio, "base_n": $BASE_N, "cgroup_limit_gib": $CG_LIMIT_GIB,
 "caliber": {"launch_interval": $LAUNCH_INTERVAL_SEC, "cmd_timeout": $COMMAND_TIMEOUT_SEC,
             "req_timeout": $REQUEST_TIMEOUT_SEC, "stop_on_failure": $STOP_ON_FAILURE},
 "pgmajfault": $(cgstat pgmajfault)}
EOF

  # 资源监控（与 165 口径同字段，agg 脚本直接可用）
  echo "ts,memavail_kb,anon_kb,commit_kb,fc_n,fc_rss_kb,ublk_n,cg_usage,pgmajfault,pgpgin,pgpgout,pswpin,pswpout,swap_used_kb,load1" > "$out/mem.csv"
  touch "$out/.mon"
  ( while [ -f "$out/.mon" ]; do
      echo "$(date +%s),$(awk '/^MemAvailable:/{print $2}' /proc/meminfo),$(awk '/^AnonPages:/{print $2}' /proc/meminfo),$(awk '/^Committed_AS:/{print $2}' /proc/meminfo),$(ps -eo args | grep -c '[f]irecracker'),$(ps -eo rss,args | grep '[f]irecracker' | awk '{s+=$1}END{print s+0}'),$(ls /dev/ublkb* 2>/dev/null | wc -l),$(cat $CGROUP_DIR/memory.usage_in_bytes 2>/dev/null || echo 0),$(awk '/^pgmajfault/{print $2}' /proc/vmstat),$(awk '/^pgpgin/{print $2}' /proc/vmstat),$(awk '/^pgpgout/{print $2}' /proc/vmstat),$(awk '/^pswpin/{print $2}' /proc/vmstat),$(awk '/^pswpout/{print $2}' /proc/vmstat),$(awk '/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{print t-f}' /proc/meminfo),$(cut -d' ' -f1 /proc/loadavg)" >> "$out/mem.csv"
      sleep 5
    done ) & MONPID=$!

  # 生成 runner 启动脚本并在 server netns 内执行（与 165 相同模式）
  local SOF=""
  [ "$STOP_ON_FAILURE" = "1" ] && SOF="--stop-on-failure"
  cat > "$out/launch.sh" <<LAUNCH
#!/bin/bash
export PATH="$SUITE/.venv/bin:\$PATH"
export PYTHONPATH="$SDK_OVERLAY"
export NO_PROXY="*"
export E2B_API_URL="http://127.0.0.1:$API_PORT"
export E2B_SANDBOX_URL="http://127.0.0.1:$API_PORT"
export AWBS_SANDBOX_GOPROXY="https://goproxy.cn"
export E2B_API_KEY="$KEY"
export SNAP_BASE="$RUNTIME_HOME/home/persisted-sandboxes/artifacts"
export DISKS="$DISKS"
ulimit -n 262144 2>/dev/null
cd "$SUITE"
exec python -m benchmark.agent_replay.runner bench --mode continuous --base-count $BASE_N --trajectory-dir "$TRAJ_DIR" --image-map "$IMAGE_MAP" --ratios $ratio --repeats 1 --command-timeout-sec $COMMAND_TIMEOUT_SEC --command-timeout-continue --request-timeout-sec $REQUEST_TIMEOUT_SEC --sandbox-timeout-sec $SANDBOX_TIMEOUT_SEC --create-retries $CREATE_RETRIES --launch-interval-sec $LAUNCH_INTERVAL_SEC $SOF --observability-interval-sec 1 --output-dir "$out/bench"
LAUNCH
  chmod +x "$out/launch.sh"

  srv_pid=$(pgrep -f "$RUNTIME_HOME/bin/server" | head -1)
  nsenter -t "$srv_pid" -n -p -m -- bash "$out/launch.sh" > "$out/runner.log" 2>&1 &
  RUNPID=$!
  sleep 8
  if kill -0 $RUNPID 2>/dev/null; then
    log "  runner pid=$RUNPID 启动成功"
  else
    log "  ERROR: runner 立即退出"; tail -5 "$out/runner.log" 2>/dev/null | while read -r l; do log "    | $l"; done
    rm -f "$out/.mon"; kill -9 $MONPID 2>/dev/null || true
    return 1
  fi

  # 停止条件看护：97% 完成 / 停滞15min@≥92% / 硬上限
  # 注意目录零填充格式：ratio 1~9 → ratio-01..09，ratio 10 → ratio-10（%02d，与 165 实测一致）
  jl="$out/bench/ratio-$(printf '%02d' "$ratio")/repeat-01/job.log"
  t0=$(date +%s); last_done=-1; last_change=$t0
  while kill -0 $RUNPID 2>/dev/null; do
    sleep 30
    el_min=$(( ($(date +%s) - t0) / 60 ))
    done_n=$(grep -c "Replay job completed" "$jl" 2>/dev/null || true); done_n=${done_n:-0}
    pct=$(( done_n * 100 / n ))
    if [ "$done_n" != "$last_done" ]; then last_done=$done_n; last_change=$(date +%s); fi
    idle_min=$(( ($(date +%s) - last_change) / 60 ))
    log "  ${el_min}min done=$done_n/$n (${pct}%) idle=${idle_min}min fc=$(ps -eo args | grep -c '[f]irecracker')"
    if [ "$pct" -ge "$STOP_PCT" ]; then log "  达到 ${STOP_PCT}%，停止"; break; fi
    if [ "$idle_min" -ge "$IDLE_MIN" ] && [ "$pct" -ge "$IDLE_FLOOR_PCT" ]; then log "  停滞 ${idle_min}min@${pct}%，停止"; break; fi
    if [ "$el_min" -ge "$HARD_MAX_MIN" ]; then log "  硬上限 ${HARD_MAX_MIN}min，停止"; break; fi
  done

  kill -TERM $RUNPID 2>/dev/null || true; sleep 4
  kill -9 $RUNPID 2>/dev/null || true
  # 只杀本战役的 runner（按 output-dir 精确匹配，不误杀共机进程）
  pkill -9 -f "agent_replay.runner.*ratio-$ratio" 2>/dev/null || true
  sleep 2
  rm -f "$out/.mon"; sleep 6; kill -9 $MONPID 2>/dev/null || true

  fin=$(grep -c "Replay job completed" "$jl" 2>/dev/null || true); fin=${fin:-0}
  log "===== 1:$ratio 结束: $fin/$n ====="
  printf "ratio=1:%s base=%s cgroup=%sGiB\n完成 %d/%d\n" "$ratio" "$BASE_N" "$CG_LIMIT_GIB" "$fin" "$n" > "$out/DONE.txt"

  cleanup_sandboxes
  return 0
}

# ===== 主流程 =====
log "########## 超分战役开始 $MACHINE_TAG arch=$(uname -m) 内核=$(uname -r) base=$BASE_N 档位: $RATIOS ##########"
log "口径: interval=$LAUNCH_INTERVAL_SEC cmd-to=$COMMAND_TIMEOUT_SEC req-to=$REQUEST_TIMEOUT_SEC stop-on-failure=$STOP_ON_FAILURE cgroup=$CG_LIMIT_GIB GiB"
log "停止条件: ${STOP_PCT}% / 停滞${IDLE_MIN}min@≥${IDLE_FLOOR_PCT}% / 硬上限${HARD_MAX_MIN}min"
for ratio in $RATIOS; do
  run_phase "$ratio" || log "WARN: 1:$ratio 失败，继续下一档"
  sleep 20
done
log "########## 全部完成 ##########"
echo ALL_DONE > "$CAMPAIGN_ROOT/.all_done"
