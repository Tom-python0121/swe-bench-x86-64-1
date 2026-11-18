#!/usr/bin/env bash
# relaunch_server.sh —— x86-64 私有 AgentENV server 启动（可搬迁版）
# 改编自 165: relaunch_server_165.sh（结构 1:1 对应，全部机器值走 machine.env）
# 前提：$RUNTIME_HOME 已用种子实例（如 89:/data/cjn-aenv）拷贝就位；$DATA_ROOT 已建
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/machine.env"

MNT=$DATA_ROOT/service-data       # 大存储：bind-mount 四项
CGROUP=$CGROUP_DIR
OUT=$RUNTIME_HOME                 # server-ns.pid / server.log 写这里

# 停掉旧的本实例进程（防双 server；pkill 按 $RUNTIME_HOME 路径精确匹配，不会误杀机器上别人的实例）
pkill -f "$RUNTIME_HOME/bin/server" 2>/dev/null || true
pkill -f "uvm-ublk-daemon.*$RUNTIME_HOME" 2>/dev/null || true
sleep 3
pkill -9 -f "$RUNTIME_HOME/bin/server" 2>/dev/null || true

# ---- namespace 内部脚本（unshare --pid --net --fork --mount-proc 后运行）----
inner() {
  set -euo pipefail
  mount --make-rprivate /
  # 把大存储 bind 到 runtime home 上（与 165 相同的四项 + fc 可写层）
  for name in image-cache snapshot-store persisted-sandboxes; do
    [ -d "$MNT/$name" ] && mount --bind "$MNT/$name" "$RUNTIME_HOME/home/$name"
  done
  if [ -d "$MNT/fc-writable-layers" ]; then
    mkdir -p "$RUNTIME_HOME/fc"
    mount --bind "$MNT/fc-writable-layers" "$RUNTIME_HOME/fc"
  fi
  ip link set dev lo up
  export API_ADDR=127.0.0.1:$API_PORT
  export AENV_CONFIG_PATH=$RUNTIME_HOME/home/config/config.toml
  export AENV_HOME_PATH=$RUNTIME_HOME/home
  export AENV_RUNTIME_PATH=$RUNTIME_HOME/run
  export AENV_DEPS_PATH=$RUNTIME_HOME/home/deps
  export REGCTL_CONFIG=$RUNTIME_HOME/home/config/regctl.json
  export AENV_UBLK_DAEMON_BINARY_PATH=$RUNTIME_HOME/home/ublk/uvm-ublk-daemon
  export AENV_VIRTUALIZATION_MODE=kvm
  export TMPDIR=$RUNTIME_HOME/tmp
  export NO_PROXY="*"
  ulimit -n 65536
  echo "$$" > $OUT/server-ns.pid
  exec $RUNTIME_HOME/bin/server --config $RUNTIME_HOME/home/config/config.toml >> $OUT/server.log 2>&1
}

mkdir -p "$RUNTIME_HOME/run" "$RUNTIME_HOME/tmp" "$MNT"
# cgroup（v1）：把 server 放进限制组
mkdir -p "$CGROUP" 2>/dev/null || true
if [ "$CG_LIMIT_GIB" -gt 0 ] 2>/dev/null; then
  echo $((CG_LIMIT_GIB*1073741824)) > "$CGROUP/memory.limit_in_bytes" 2>/dev/null || true
  echo $((CG_LIMIT_GIB*2*1073741824)) > "$CGROUP/memory.memsw.limit_in_bytes" 2>/dev/null || true
fi
: > $OUT/server.log
unshare --pid --net --mount --fork --mount-proc bash -c \
  "$(declare -f inner); export RUNTIME_HOME=$RUNTIME_HOME MNT=$MNT OUT=$OUT API_PORT=$API_PORT CGROUP=$CGROUP; echo \$\$ > $CGROUP/cgroup.procs 2>/dev/null; inner"
echo "[relaunch] server pid-file: $OUT/server-ns.pid（wait: 健康检查用 health_check.sh）"
