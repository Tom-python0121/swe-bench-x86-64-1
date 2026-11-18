# x86-64 可搬迁脚本包 · 89 机适配验证记录

> 验证时间：2026-11-17 17:00~17:30（89 机 /data/x86oversub/）
> 结论：**脚手架层全部验证通过**；模板迁移与完整战役链路待新实测机到位后做全链路验证（见"待验证项"）

## 一、已验证 ✓

| # | 验证项 | 结果 | 证据 |
|---|---|---|---|
| 1 | bootstrap.sh 种子初始化 | ✓ | x86_64 二进制校验过；/data/x86oversub-aenv 布局建成（bin/home/{config,deps,ublk,api-key}/run/tmp） |
| 2 | relaunch_server.sh 私有实例 | ✓ | unshare PID/net/mnt 三命名空间 + bind-mount 跑通；**API server listening addr=127.0.0.1:18100**（server.log 09:06:14） |
| 3 | health_check.sh | ✓ | nsenter netns 内 curl /health 返回 OK |
| 4 | cgroup v1 限制组 | ✓ | /sys/fs/cgroup/memory/x86oversub 创建成功，server 进程入组 |
| 5 | e2b SDK → API → firecracker → x86 沙箱全链路 | ✓ | sdk_probe.py（借 cjn 8180 + swegym 模板）：创建 0.23s，沙箱内 `uname -m` = **x86_64**，nproc=4，删除 0.49s 全程 |
| 6 | AgentENV API 协议兼容 | ✓ | 89 的 cjn server（8180）与 165（18100）API 同构：/health /templates /sandboxes + X-API-Key |

## 二、修复记录（适配过程中发现并已修）

| 问题 | 原因 | 修复 |
|---|---|---|
| server 起不来：`open RocksDB records.db: File exists` | bootstrap 误把 records.db 建成**文件**（RocksDB 需要它是自己创建的**目录**） | bootstrap.sh 移除 `touch records.db`；89 上删除该文件后 relaunch 成功 |
| relaunch 内 `$RUNTIME/home` 路径错 | 165 布局（runtime/home）与 cjn 布局（home/ 顶层）不同 | 统一为 `$RUNTIME_HOME/home/...`；AENV_DEPS_PATH=home/deps、UBLK daemon=home/ublk/uvm-ublk-daemon |
| api-key 两种格式 | 165 用 e2b_ 前缀 key，89/cjn 用裸 key | sdk_probe/start_bench 的 key 读取兼容两种（先 grep e2b_，fallback 首行裸 key） |
| inner() 丢 `ip link set dev lo up` | 编辑事故 | 已补回（netns 内 lo 必须显式拉起，否则 127.0.0.1 不可达） |

## 三、89 验证环境遗留状态

- 私有实例**仍在运行**（pid 文件 /data/x86oversub-aenv/server-ns.pid，health OK），占磁盘 ~100M + DATA_ROOT 目录，**未跑任何沙箱**——留着可继续验证，不需要可执行：`pkill -f x86oversub-aenv/bin/server && rm -rf /data/x86oversub*`
- cjn 8180 的 swegym 模板未动（spawnCount=0，探测沙箱已删）
- 89 的 /data 仍剩 ~20G

## 四、待验证项（新实测机到位后）

1. **模板+快照迁移**（最大件）：从 165 拷 swb-*__2u4g 全套。迁移目标结构（对应 relaunch 的 bind-mount）：
   - `DATA_ROOT/service-data/snapshot-store/` ← 165 `/home/wuyihao/mo950-165-20261104-r02/runtime/home/snapshot-store/`（模板 build 快照）
   - `DATA_ROOT/service-data/persisted-sandboxes/` ← 165 同名目录（**artifacts/ + repository/ + records.db/**，注意 records.db 是 RocksDB **目录**）
   - `DATA_ROOT/service-data/image-cache/` ← 165 同名目录
   - 迁移后 `relaunch_server.sh` 重启私有实例 → `/templates` 应列出 384 个 swb 模板 → `launch_in_ns.sh python3 sdk_probe.py swb-<一条轨迹>__2u4g`
   - 注意：**aarch64 快照不能在 x86 用**——迁移验证仅验证"机制"，真实 swb 模板必须在 x86 上重建（见下）
2. **x86 模板重建**：swegym 流水线（89:/data/cjn-aenv/swegym/build_images_x86.py，SkyRL-293 子集）扩展到 384 条 swb 轨迹 → 产出与 image-map.json 同名模板 → snapshot 到 persisted-sandboxes
3. **runner harness 落地**：从 165 拷 agent-workload-benchmark-suite-fixed-v4 + sdk-overlay-v4 + inputs-v2（replays 384 条 + image-map.json）→ `pip install -r requirements` 建 venv → start_bench.sh 冒烟（BASE_N 小值）
4. **完整战役链路**：RATIO=1 冒烟 → 对照 165 1:1（mean 1641s）量级

## 五、复现本次验证的命令序列（新机器上）

```bash
# 0. 放好脚本包（本目录），按机器实况改 machine.env
# 1. 初始化私有实例（SEED=本机已有的 aenv 部署；新机可从 89 的 /data/x86oversub-aenv 打包拷贝）
SEED=<种子目录> ./bootstrap.sh
# 2. 起私有 server + 健康检查
./relaunch_server.sh && ./health_check.sh
# 3. 模板就位后链路验证
./launch_in_ns.sh python3 sdk_probe.py <模板名>
# 4. 战役（BASE_N/RATIOS 在 machine.env；单场用 RATIO=4 ./start_bench.sh）
./launch_in_ns.sh ./start_bench.sh
```
