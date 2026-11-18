# Zen5 实测机部署手册（小白版 · 实机定稿版 v2）

> 更新：2026-11-17 晚，按实机定稿信息全面改写（替代早先按"64G 桌面机"假设的初版）
> **机器档案（七张截图已核实）**：AMD EPYC 9755 ×2 = 256核/512线程，2.7GHz｜内存 1321GiB（24 根 64GB DDR5-5600 全槽插满，与 24×64G 有约 2 根缺口待供应商解释）｜8×2.9T NVMe（7 块自由盘：nvme0/1/2/3/4/6/8；nvme5=旧系统盘、nvme7=现系统盘[70G 根分区 92% 满] 都别碰）｜openEuler｜机上有 nomad/docker 业务占 331GiB 内存 + 1.17T 盘
> **你需要的**：机器 IP + root 密码（供应商还欠着）；你的 Windows 电脑——**D 盘已经是完整弹药库**
> 约定：可复制的命令都在代码块里；每步有"✅ 检查点"；卡住就把输出原样发给 Claude

---

## 0. 先搞懂我们在干什么（3 分钟）

目标：在这台 x86 服务器上跑一套和 165（鲲鹏）**一模一样**的沙箱超分压测，产出两边直接可比的容量数据——回答"单机各能承载多少 Agent 沙箱"。

概念速览（大白话）：
- **沙箱**：超轻量小虚拟机（2 核 4G），里面回放一条 SWE-bench 任务，测它被"邻居"挤得多慢
- **超分 1:R**：名义内存只够装下 base 个沙箱，故意开 R 倍
- **BASE_N=330**：这台机器的基准数 = min(512线程, 1321G÷4) = 330。1:1 时名义内存 330×4G=1320G ≈ 物理内存——跟 165 的"1:1 刚好装满"惯例同义
- **模板**：沙箱的母版。165 的母版是 ARM 的，这台 x86 必须重建（工作量最大的一步，可叫我接手）

流程九步：**验机 → 分盘 → 传文件 → 配置 → 起服务 → 造模板 → 冒烟 → 五档扫描 → 收数据**。

---

## 1. 验机（拿到 IP 后，10 分钟）

SSH 登录（Windows PowerShell：`ssh root@<IP>`），逐段执行：

```bash
# ① 核对已知信息（应看到：512 线程 / 1321GiB / 8×2.9T）
lscpu | grep -E "Model name|^CPU\(s\)|Thread|Socket"
free -g | head -2
lsblk -d -o NAME,SIZE,TYPE

# ② KVM + cgroup 版本（脚本按 cgroup v1 写的）
ls -la /dev/kvm
ls /sys/fs/cgroup/ | head -8     # 看到 blkio/cpu 等平铺目录=v1 ✓；看到 cgroup.controllers=v2 → 停下叫我

# ③ 三项设置
swapoff -a && sed -i '/swap/s/^/#/' /etc/fstab       # 关 swap（否则高压时数据全毁）
cpupower frequency-set -g performance 2>/dev/null || echo "报错发我"
cat /sys/kernel/mm/transparent_hugepage/enabled     # 应为 [always]，不是就发我
```

**这台机特有的三件事（找供应商/机器管理员）：**
1. **内存缺口**：24 根插满应 1536G，free 只有 1321G——差约 2 根。让他们查是坏条还是开了"内存备援"模式（备援=留 1~2 根当热备，跑压测建议关掉）
2. **系统盘只剩 5.4G**（nvme7 的 70G 根分区 92% 满）：让他们清理，或我们把大件全放 NVMe 数据盘绕开
3. **nomad/docker 业务**（占 331G 内存 + 1.17T 硬盘）：问清是谁的、**约一个独占窗口**——压测期间这些业务会污染数据

**✅ 检查点**：把 lscpu 和 lsblk 输出发我，我核对 BASE_N=330 和盘名。

---

## 2. 分盘（15 分钟，⚠️ 唯一危险步骤）

用 7 块自由 NVMe 中的两块（**用你 lsblk 看到的实际名**，nvme5/nvme7 千万别碰）：

| 盘 | 挂载到 | 用途 |
|---|---|---|
| nvme0n1 | `/data/awbs-data` | 模板库+快照+fc 层（全 384 模板约 1.6T，单盘装下）|
| nvme1n1 | `/data/awbs-results` | 战役结果 |
| 其余 5 块 | 暂不动 | 备用/镜像 |

```bash
mkfs.xfs /dev/nvme0n1          # ⚠️ 再次核对：2.9T 的盘才许格式化！
mkfs.xfs /dev/nvme1n1
mkdir -p /data/awbs-data /data/awbs-results
mount /dev/nvme0n1 /data/awbs-data
mount /dev/nvme1n1 /data/awbs-results
blkid /dev/nvme0n1; blkid /dev/nvme1n1     # 各自复制 UUID
echo 'UUID=第一块UUID /data/awbs-data  xfs defaults 0 0' >> /etc/fstab
echo 'UUID=第二块UUID /data/awbs-results xfs defaults 0 0' >> /etc/fstab
mount -a                                    # 报错就发我，别重启！
```

**✅ 检查点**：`df -h /data/awbs-data /data/awbs-results` 两行都是 2.9T。

---

## 3. 传文件（全部从你的 D 盘来 + 89 一个小包，不用碰 165）

**D 盘 → 新机**（WinSCP 拖拽或 scp，四样）：

| D 盘路径 | 传到服务器哪 | 说明 |
|---|---|---|
| `脚本\x86-64`（整个文件夹） | `/root/x86-64` | 脚本包+手册 |
| `agent-workload-benchmark-suite-main (1)\agent-workload-benchmark-suite-main` | `/data/awbs-data/agent-workload-benchmark-suite-main` | **已打补丁=165 实战版**（仓库根有 PATCHED 说明；文件夹名保持不变）|
| `awbs165-三件套-20261117\sdk-overlay-v4` | `/data/awbs-data/sdk-overlay-v4` | e2b SDK 覆盖层 |
| `awbs165-三件套-20261117\inputs-v2` | `/data/awbs-data/inputs-v2` | 384 条轨迹+image-map |

**89 → 新机**（AgentENV x86 runtime 种子，约 150M，二选一）：
- **方式 A（推荐）**：跟我说一声，我走隧道把它拉到你 D 盘，变成纯 D 盘搬运
- **方式 B（自助）**：WinSCP 连 89（root@192.168.90.89），先在 89 上打包再拖：

```bash
# 在 89 上执行（PowerShell 远程或直接登）：
cd /data && tar czf /tmp/x86-aenv-seed.tar.gz --exclude='*.log' --exclude='run' --exclude='tmp' x86oversub-aenv/bin x86oversub-aenv/home/config x86oversub-aenv/home/deps x86oversub-aenv/home/ublk x86oversub-aenv/home/api-key
# 然后 WinSCP 把 /tmp/x86-aenv-seed.tar.gz 拖到新机 /tmp/
```

**新机上解包**：

```bash
tar xzf /tmp/x86-aenv-seed.tar.gz -C /data/    # → /data/x86oversub-aenv
ls /data/x86oversub-aenv/bin/server /data/awbs-data/inputs-v2/image-map.json   # 两个都在=✓
```

---

## 4. 配置（10 分钟）

```bash
cd /root/x86-64
cp machine.env.example-zen5 machine.env     # 实机模板（BASE_N=330 已算好）
vi machine.env                               # 唯一可能要改：DISKS 的实际盘名

# Python 环境（一次就好；openEuler 24.03 自带 python3.11 满足要求）
dnf install -y python3 python3-pip
cd /data/awbs-data/agent-workload-benchmark-suite-main
python3 -m venv .venv
.venv/bin/pip install -r benchmark/agent_replay/requirements.txt   # 自动装 x86_64 版依赖
```

**✅ 检查点**：

```bash
cd /root/x86-64 && ./preflight.sh            # 应 FAIL=0（路径"缺"项此时应全变 PASS）
```

---

## 5. 起私有服务（10 分钟）

```bash
cd /root/x86-64
./relaunch_server.sh       # 起 server（自动停旧实例，重复执行安全）
./health_check.sh          # 等 OK（最多 2 分钟）
```

**❌ 不 OK** → `tail -30 /data/x86oversub-aenv/server.log` 发我。

---

## 6. 造模板（1~2 天，最大工作量——**机器能 SSH 就叫我接手**）

这台机盘大（2.9T 单盘），**直接全建 384 个**（约 1.6T，装得下，不用挑子集）。原理三步：每条轨迹造环境镜像 → `aenv pull '镜像:tag' --name swb-题名__2u4g --cpu 2 --memory 4096`（把镜像"录"成母版）→ 入库到 DATA_ROOT。批量 384 个需要把 wuyihao 的 swegym 流水线适配到 swb 清单——**这步我来做**，你保证机器空闲和磁盘够即可。

**✅ 检查点**（造出第一个后）：

```bash
curl -s -H "X-API-Key: $(head -1 /data/x86oversub-aenv/home/api-key)" http://127.0.0.1:18100/templates | grep -o '"names":\["[^"]*"' | head
# 看到 swb- 开头 → 把它的 templateID 回填到 machine.env 的 PROBE_TEMPLATE
```

---

## 7. 冒烟：跑最小的一场（预计 1~1.5 小时）

```bash
cd /root/x86-64
# ① 链路探针（开一个沙箱→uname -m→删）
./launch_in_ns.sh /data/awbs-data/agent-workload-benchmark-suite-main/.venv/bin/python sdk_probe.py <模板名>
# 期望 stdout 里有 x86_64

# ② 1:1 小战役（330 沙箱）
RATIOS="1" nohup ./run_campaign.sh > smoke.log 2>&1 &
tail -f smoke.log
```

日志每 30 秒一行：`done=完成任务数/总数 (%) idle=停滞分钟 fc=活沙箱数 memavail=剩余内存`。
自动停：97% 完成 / 停滞 15min / 硬上限 200min，停了写 DONE.txt。

**✅ 检查点**：`ls /data/awbs-results/campaign-*/ratio-1/` 有 DONE.txt + bench/ → 全链路通了！

---

## 8. 五档扫描（半天~一天）

```bash
RATIOS="1 2 4 6 8" nohup ./run_campaign.sh > campaign.log 2>&1 &
tail -f campaign.log
# 中断了直接重跑同一条命令——DONE 的档自动跳过

# 单档也可用与 aarch64 完全一致的写法（六档各有一个同名薄壳脚本）：
# ./launch_in_ns.sh bash start_bench_ratio4.sh    ← 换数字即可：1/2/4/6/8/10
```

**这台机的分档账**（BASE_N=330）：

| 档 | 沙箱 | 名义内存 | 实际占用估 | 判断 |
|---|---|---|---|---|
| 1:1 | 330 | 1320G≈物理 | ~145G（11%） | 基线 |
| 1:2 | 660 | 2× | ~290G（22%） | 轻松 |
| 1:4 | 1320 | 4× | ~580G（44%） | 正常 |
| 1:6 | 1980 | 6× | ~870G（66%） | 正常 |
| 1:8 | 2640 | 8× | ~1160G（**87%**） | 与 165 的 1:8（84%）几乎镜像——核心对照点 |
| 1:10 | 3300 | 10× | ~1450G（**110%**） | 超物理，需保险丝 |

**1:10 保险丝**（必须先装再跑）：

```bash
vi machine.env        # CG_LIMIT_GIB=0 → 1200；HARD_MAX_MIN=200 → 300
./relaunch_server.sh && ./health_check.sh      # 重启生效（自动停旧实例）
RATIOS="10" nohup ./run_campaign.sh > ratio10.log 2>&1 &
# 跑完把 machine.env 改回 CG_LIMIT_GIB=0 / HARD_MAX_MIN=200
```

口径脚注（分析时我处理，你只需知道）：内存轴与 165 同义（1:1 名义=物理），CPU 轴比 165 松（1.29R× vs 165 的 2R×，因 512 线程 > 330 base）——165 的 1:10 补测也在做，两边对称。

---

## 9. 收数据

```bash
ls /data/awbs-results/campaign-*/     # ratio-1 2 4 6 8 [10]
```

四样东西发我（或给我 SSH 我自己上去拿）：各档 DONE.txt + mem.csv + machine.env + bench/ratio-XX/repeat-01/ 原始数据。我用 165 同款脚本出三图 + 950 vs x86 对比结论。战役期间**别在机器上跑别的**。

---

## 10. 出问题对号入座

| 症状 | 先看哪 | 原因 |
|---|---|---|
| health 超时 | server.log 尾 30 行 | 盘没挂上 / cgroup v2 / key 缺 |
| runner 秒退 | runner.log 尾 30 行 | SUITE/TRAJ 路径错 / venv 没装 |
| 沙箱里不是 x86_64 | — | 模板是 ARM 的（来源错了），必须 x86 重建 |
| 1:10 卡 0% 不动 | campaign.log + free -g | 创建风暴→重跑一次，再不行叫我降参数（口径会标注）|
| 内存不升反降异常 | mem.csv | nomad/docker 业务开跑了——停掉它们 |
| fstab 写错开不了机 | （第 2 步 mount -a 会先报错）| UUID 抄错，报错发我别重启 |

---

## 附：术语词典

沙箱=轻量虚拟机（2核4G）｜Firecracker=沙箱底层引擎（fc=进程数）｜模板/母版=沙箱复印底稿（**分架构**，ARM 的 x86 用不了）｜超分=开超过名义内存的沙箱数｜BASE_N=1:1 基准沙箱数（本机 330）｜口径=参数约定（base/超时/停止条件），两边一致才可比｜reproduce 口径=与 165 -132 数据一致的那套参数（machine.env 已锁）｜netns=机器内部隔离小网络（18100 只有 launch_in_ns.sh 进得去）｜cgroup=内核资源围栏（1:10 的"保险丝"）｜swap=拿磁盘冒充内存（测试必须关）｜内存备援=服务器留热备内存的模式（跑压测建议关）｜DONE.txt=完成章（断点续跑）｜mem.csv=每 5 秒一行的内存监控流水｜创建风暴=几百沙箱挤爆创建通道（1:10 常见死法）
