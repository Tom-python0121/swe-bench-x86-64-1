#!/usr/bin/env bash
# verify-fixed4.sh —— 验证 harness 与 165 实战版(fixed-v4)字节级等价（29 个权威 md5）
# 用法：cd <agent-workload-benchmark-suite-main 仓库根目录> && bash verify-fixed4.sh
set -u
PASS=0; FAIL=0
check(){ local want=$1 path=$2 got; got=$(md5sum "$path" 2>/dev/null | awk "{print \$1}"); if [ "$got" = "$want" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL $path  期望=$want 实得=${got:-文件缺失}"; fi; }
check 0bfe7f9672eb19a97809e2fe6750e7dc benchmark/agent_replay/runner/replay/trajectory.py
check 118a67773be5c0581aea2a49df72bcd0 benchmark/agent_replay/runner/replay/continuous.py
check 2c8ce2e661ea29a7f0829cd67a48f524 benchmark/agent_replay/runner/prepare.py
check 3393a9aec527b12238675491818f8f24 benchmark/agent_replay/runner/replay/sandbox.py
check 3867be0b6479d1d3f88a0aeaf5196914 benchmark/agent_replay/observability/__init__.py
check 3a7af0b9c2d88b6e1527b7a273baef84 benchmark/agent_replay/runner/__main__.py
check 3b38092c76c9fed78d63a677a05fb74f benchmark/agent_replay/runner/running_scheduler.py
check 420928f0b1ed4589fba883c2b3422b6b benchmark/agent_replay/runner/cli.py
check 434eb4a4af4a93444e39af785548500a benchmark/agent_replay/observability/make_obs_xlsx.py
check 4916f4c01d456b593ec55b53a19b8c45 benchmark/agent_replay/report/results.py
check 49fff31bef7452d2db77c34137ff7746 benchmark/agent_replay/observability/make_obs_report.py
check 63cf3d6ccc41f91828cdfe1a2ef093c9 benchmark/agent_replay/report/summary.py
check 6cb97e4b52fc979a304bcb8db21d3629 benchmark/agent_replay/runner/batch.py
check 75f777bca3c11c669f75a8ea8f9218f5 benchmark/agent_replay/report/generate.py
check 85ea0878e610bc2d4a56cb711132457a benchmark/agent_replay/observability/probe_snapshot_generations.py
check 8fbff73e13c0eba4cd2a9d28aa2797cb benchmark/agent_replay/observability/analyze_pause_resume.py
check 9ac708590879e3afdbddeb3bb56a940a benchmark/agent_replay/report/export_timings.py
check ab0085cf3afe716fe6368259865f4c8e benchmark/agent_replay/runner/models.py
check c415b39dc205038025755e9d1676e6aa benchmark/agent_replay/runner/replay/pause_resume.py
check d2e916e18ac7fc58f6262bf7ca41fe03 benchmark/agent_replay/observability/spotbox_monitor.py
check d41d8cd98f00b204e9800998ecf8427e benchmark/agent_replay/__init__.py
check d41d8cd98f00b204e9800998ecf8427e benchmark/agent_replay/report/__init__.py
check d41d8cd98f00b204e9800998ecf8427e benchmark/agent_replay/runner/__init__.py
check d9d4462599f7ae32dece559fc3f02dd6 benchmark/agent_replay/runner/replay/__init__.py
check e2ce78b58124e6993015baa9d7402c00 benchmark/agent_replay/runner/replay/timeout_cleanup.py
check e530d587fa47eac9722adedbc8a83dc5 benchmark/agent_replay/runner/experiment.py
check f16dcfcbf3dc7ad711562217fccbda39 benchmark/agent_replay/observability/monitor.py
check f54331ff0ca7afc8c74570794fcc7091 benchmark/agent_replay/report/plot_trajectory_completion_time.py
check f6b56f4537306116f9ac2e6aecd2cae1 benchmark/agent_replay/tests/test_export_timings.py
echo
echo "结果: PASS=$PASS FAIL=$FAIL （应为 29/29）"
if [ "$FAIL" -eq 0 ] && [ "$PASS" -eq 29 ]; then
  echo "✅ 与 165 fixed-v4 字节级等价——harness 可用于正式战役"
  exit 0
else
  echo "❌ 存在差异——先在仓库根执行: tar xzf /tmp/patch7-fixed-v4-20261117.tar.gz 再重跑本脚本"
  exit 1
fi
