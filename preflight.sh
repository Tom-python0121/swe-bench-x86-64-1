#!/usr/bin/env bash
# preflight.sh —— x86-64 脚本包自检（只读，不启 server、不建沙箱、不产生数据）
# 检查四层：① bash 语法 ② python 语法 ③ machine.env 完整性 ④ 关键路径存在性
# 用法: ./preflight.sh        （新机搬包后、开战役前各跑一次）
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL  $1${2:+ — $2}"; FAIL=$((FAIL+1)); }
note(){ echo "  ----  $1"; }

echo "== 1/4 bash 语法检查（bash -n） =="
for f in machine.env machine.env.example-zen5 bootstrap.sh relaunch_server.sh launch_in_ns.sh health_check.sh \
         start_bench.sh start_bench_ratio1.sh start_bench_ratio2.sh start_bench_ratio4.sh \
         start_bench_ratio6.sh start_bench_ratio8.sh start_bench_ratio10.sh run_campaign.sh \
         补丁-harness/verify-fixed4.sh; do
  if [ ! -f "$f" ]; then bad "$f" "文件不存在"; continue; fi
  if bash -n "$f" 2>/tmp/pf.err; then ok "bash -n $f"; else bad "bash -n $f" "$(head -1 /tmp/pf.err)"; fi
done

echo "== 2/4 python 语法检查（ast.parse，无副作用） =="
if [ -f sdk_probe.py ]; then
  if python3 -c "import ast,sys; ast.parse(open('sdk_probe.py',encoding='utf-8').read())" 2>/tmp/pf.err; then
    ok "ast.parse sdk_probe.py"
  else
    bad "ast.parse sdk_probe.py" "$(head -1 /tmp/pf.err)"
  fi
else
  bad "sdk_probe.py" "文件不存在"
fi

echo "== 3/4 machine.env 完整性（能否 source + 必填变量非空） =="
if ! source ./machine.env 2>/tmp/pf.err; then
  bad "source machine.env" "$(head -1 /tmp/pf.err)"
else
  for v in MACHINE_TAG RUNTIME_HOME API_PORT DATA_ROOT DISKS SUITE SDK_OVERLAY TRAJ_DIR IMAGE_MAP \
           BASE_N RATIOS LAUNCH_INTERVAL_SEC COMMAND_TIMEOUT_SEC REQUEST_TIMEOUT_SEC SANDBOX_TIMEOUT_SEC \
           CREATE_RETRIES STOP_ON_FAILURE STOP_PCT IDLE_MIN IDLE_FLOOR_PCT HARD_MAX_MIN \
           CG_LIMIT_GIB CGROUP_DIR RESULTS_ROOT; do
    val=${!v:-}
    if [ -n "$val" ]; then ok "$v=${val}"; else bad "$v 未设置"; fi
  done
  # E2B_API_KEY 允许为空（运行时从 api-key 文件读）
  if [ -n "${E2B_API_KEY:-}" ]; then ok "E2B_API_KEY=***（已直接设置）"
  elif [ -f "$RUNTIME_HOME/home/api-key" ]; then ok "E2B_API_KEY 空，但 $RUNTIME_HOME/home/api-key 存在（可自动读）"
  else note "E2B_API_KEY 空，且 $RUNTIME_HOME/home/api-key 不存在——跑战役前需二选一补上"; fi
  # 数值合理性
  [ "$BASE_N" -gt 0 ] 2>/dev/null && ok "BASE_N=$BASE_N 为正整数" || bad "BASE_N=$BASE_N 不是正整数"
  [ "$API_PORT" -gt 0 ] 2>/dev/null && ok "API_PORT=$API_PORT" || bad "API_PORT=$API_PORT 非法"
  # RATIOS 应包含 1:1 基线档
  case " $RATIOS " in *" 1 "*) ok "RATIOS 含 1:1 基线档（配对劣化分母）";; *) bad "RATIOS='$RATIOS' 缺 1:1 基线档——配对劣化将无分母";; esac
fi

echo "== 4/4 关键路径存在性（缺项=bring-up 待办，不算 FAIL） =="
for p in "SUITE:$SUITE" "TRAJ_DIR:$TRAJ_DIR" "IMAGE_MAP:$IMAGE_MAP" "SDK_OVERLAY:$SDK_OVERLAY" \
         "server二进制:$RUNTIME_HOME/bin/server" "api-key:$RUNTIME_HOME/home/api-key" \
         "DATA_ROOT:$DATA_ROOT" "venv:$SUITE/.venv/bin/python"; do
  name=${p%%:*}; path=${p#*:}
  if [ -e "$path" ]; then ok "存在  $name → $path"; else note "缺    $name（$path）——新机 bring-up 时补齐"; fi
done

echo
echo "===== 自检结果: PASS=$PASS  FAIL=$FAIL ====="
if [ "$FAIL" -eq 0 ]; then
  echo "语法与配置层全部可用 ✓（路径缺项见上，属 bring-up 待办不影响语法可用性）"
else
  echo "存在 FAIL 项（语法/配置错误），逐条修复后再上机！"
fi
exit "$FAIL"
