# GLM 执行任务书：把三件套与 harness 补丁部署到 Zen5 实测机

> 任务编号：SWE-X86-PROVISION-01　生成：2026-11-17　执行者：GLM 大模型（在 Zen5 机器上逐字执行）
> 机器：AMD EPYC 9755×2（512 线程）/ 1321GiB 内存 / openEuler / root 权限
> 目标：① 把 sdk-overlay-v4 和 inputs-v2 放到标准位置；② 确认机器上的 harness（agent-workload-benchmark-suite-main）补齐 7 个文件的实战补丁；③ 全部验证通过

## ⚠️ 开工前必读的三个红线

1. **禁止**把 Windows 上任何名为 `backup-main原版6文件-20261117` 的文件夹/文件传到服务器——那是补丁前的旧版备份，传上去会撤销补丁、毁掉与 aarch64 数据的可比性
2. **禁止**改动 `nvme5n1` 和 `nvme7n1` 两块盘（旧系统盘/现系统盘）——格式化任何盘之前必须用 `lsblk -d -o NAME,SIZE` 核对容量是 2.9T
3. **禁止**把 sdk-overlay-v4 或 inputs-v2 放进 harness 仓库文件夹里面——它们是三个平级目录（见下方布局图）

**标准布局（做完后必须长这样）**：

```
/data/awbs-data/                              ← NVMe 第一块（挂载点）
├── agent-workload-benchmark-suite-main/      ← harness（机器上已有，补丁后=165 实战版）
├── sdk-overlay-v4/                            ← e2b SDK 覆盖层（本轮上传）
└── inputs-v2/                                 ← 384 条轨迹（本轮上传）
/data/awbs-results/                            ← NVMe 第二块（结果盘，本轮只确认挂载）
```

---

## 阶段 A：人工传输（WinSCP 拖拽，GLM 无法替代，先做完再进阶段 B）

从 Windows 用 WinSCP 连上 Zen5 机器，把下列 5 样传到服务器 `/tmp/`（如果 /tmp 空间紧张传到 /data/awbs-results/ 也可以，但后面命令里的路径要对应改）：

| # | Windows 上的源（D 盘） | 目标 | 大小 |
|---|---|---|---|
| A1 | `D:\搜推\Agent负载\产品线SWE-BENCH\脚本\x86-64\补丁-harness\patch7-fixed-v4-20261117.tar.gz` | `/tmp/` | 35KB |
| A2 | `D:\搜推\Agent负载\产品线SWE-BENCH\脚本\x86-64\补丁-harness\verify-fixed4.sh` | `/tmp/` | 3KB |
| A3 | `D:\搜推\Agent负载\产品线SWE-BENCH\awbs165-三件套-20261117\sdk-overlay-v4`（整个文件夹） | `/tmp/` | 4.7M |
| A4 | `D:\搜推\Agent负载\产品线SWE-BENCH\awbs165-三件套-20261117\inputs-v2`（整个文件夹） | `/tmp/` | 31M |
| A5 | `D:\搜推\Agent负载\产品线SWE-BENCH\脚本\x86-64`（整个文件夹，改名成 `x86-64` 传） | `/tmp/` | 50KB |

---

## 阶段 B：机器端执行（GLM 从这里开始，逐步执行，每步核对输出）

### B0. 前置检查（30 秒）

```bash
whoami                      # 必须输出 root
ls -la /tmp/patch7-fixed-v4-20261117.tar.gz /tmp/verify-fixed4.sh /tmp/sdk-overlay-v4 /tmp/inputs-v2 /tmp/x86-64
# 五样都在 → 继续；缺哪样回到阶段 A
```

### B1. 数据盘挂载检查（第一次见机器必须做）

```bash
df -h /data/awbs-data /data/awbs-results 2>/dev/null | tail -2
```

- **两行都显示 2.9T** → 挂载正常，跳到 B2
- **报错/no such directory** → 数据盘没挂载，执行下面分盘块（⚠️ 先核对盘名，只许 2.9T 的盘）：

```bash
lsblk -d -o NAME,SIZE        # 从 2.9T 且无分区的盘里选两块（例如 nvme0n1、nvme1n1）
mkfs.xfs /dev/nvme0n1        # ⚠️ 执行前再次确认 SIZE 列 = 2.9T
mkfs.xfs /dev/nvme1n1
mkdir -p /data/awbs-data /data/awbs-results
mount /dev/nvme0n1 /data/awbs-data
mount /dev/nvme1n1 /data/awbs-results
blkid /dev/nvme0n1 | awk '{print "UUID="$2}'      # 记下 UUID
blkid /dev/nvme1n1 | awk '{print "UUID="$2}'
echo 'UUID=<上面第一串UUID> /data/awbs-data  xfs defaults 0 0' >> /etc/fstab
echo 'UUID=<上面第二串UUID> /data/awbs-results xfs defaults 0 0' >> /etc/fstab
mount -a && df -h /data/awbs-data /data/awbs-results   # 必须两行 2.9T；报错立即停止，原样上报
```

### B2. 三件套落位

```bash
mv /tmp/sdk-overlay-v4 /data/awbs-data/
mv /tmp/inputs-v2 /data/awbs-data/
mv /tmp/x86-64 /root/x86-64
```

### B3. harness 归位（机器上已有仓库，先找到它在哪）

```bash
find / -maxdepth 4 -name "agent-workload-benchmark-suite-main" -type d 2>/dev/null | grep -v awbs-data
```

- 找到且**不在** /data/awbs-data/ 下 → 移过去：`mv <找到的路径> /data/awbs-data/`
- 已经在 /data/awbs-data/ 下 → 什么都不做
- **完全没找到** → 说明尚未上传，从 Windows 上传 `D:\...\agent-workload-benchmark-suite-main (1)\agent-workload-benchmark-suite-main` 整个文件夹到 /data/awbs-data/（该 D 盘版本已含补丁），然后继续
- 核对：`ls /data/awbs-data/agent-workload-benchmark-suite-main` 应看到 `artifacts benchmark builder docs LICENSE pyproject.toml README.md simulation uv.lock`

### B4. 打补丁（幂等：已打过也无害，重复执行安全）

```bash
cd /data/awbs-data/agent-workload-benchmark-suite-main
tar xzf /tmp/patch7-fixed-v4-20261117.tar.gz
ls -la benchmark/agent_replay/runner/replay/timeout_cleanup.py   # 这个文件必须存在（补丁新增）
```

### B5. 验证（核心关卡，必须 29/29）

```bash
cd /data/awbs-data/agent-workload-benchmark-suite-main
cp /tmp/verify-fixed4.sh .
bash verify-fixed4.sh
```

- **输出 `PASS=29 FAIL=0` + ✅** → 通过，继续 B6
- **有 FAIL** → 检查 FAIL 列出的文件：若是 7 个补丁文件之一，回到 B4 重做；若报"文件缺失"超过 10 个，说明 harness 上传不完整，上报
- **绝对不要**为了通过验证去修改 verify-fixed4.sh 本身——脚本是权威，改脚本=作弊

### B6. 输入完整性抽查

```bash
ls /data/awbs-data/inputs-v2/replays | wc -l        # 必须恰好 384
ls /data/awbs-data/inputs-v2/image-map.json          # 必须存在
head -c 120 /data/awbs-data/inputs-v2/image-map.json # 应是 {"1password__typeshare-131.replay.json": "swb-...
ls /data/awbs-data/sdk-overlay-v4/e2b/__init__.py    # 必须存在
ls /root/x86-64/machine.env.example-zen5             # 必须存在（脚本包就位）
```

### B7. 收尾报告（GLM 把以下输出整理成一段回报）

```bash
echo "=== 部署验收快照 $(date '+%F %T') ==="
df -h /data/awbs-data /data/awbs-results | tail -2
cd /data/awbs-data/agent-workload-benchmark-suite-main && bash verify-fixed4.sh | tail -2
echo "replays: $(ls /data/awbs-data/inputs-v2/replays | wc -l) 条"
uname -r && free -g | head -2
```

**验收标准（全部满足才算完成）**：
1. verify-fixed4.sh → PASS=29 FAIL=0
2. replays = 384
3. /data/awbs-data/ 下三个目录平级（harness + sdk-overlay-v4 + inputs-v2）
4. /root/x86-64/ 脚本包就位

---

## 完成后的下一步（不在本任务书内，由人决策）

- 还缺：89 机的 runtime 种子（AgentENV 二进制，~150M）→ 见《小白部署手册-Zen5.md》第 3 步
- 之后按手册第 4 步继续（machine.env 配置 → preflight → 起服务 → 造模板）

## 常见错误对照（GLM 遇到问题时自查）

| 现象 | 原因 | 处置 |
|---|---|---|
| B5 报 timeout_cleanup.py 缺失 | B4 没做或 tar 路径不对 | 重做 B4，必须在仓库根目录执行 tar |
| B5 某文件 FAIL 且实得 md5=c7d46436… 等旧值 | 机器上传的是未打补丁的 main | 重做 B4；若 tar 后仍 FAIL，把 FAIL 的 md5 原样上报 |
| B1 mount -a 报错 | fstab UUID 抄错 | **不要重启**，把 blkid 输出和报错原样上报 |
| mv /tmp/x86-64 提示已存在 | 重复执行 | 用 rsync -a /tmp/x86-64/ /root/x86-64/ 合并即可 |
| verify 里改了文件仍 FAIL | 改错方向了 | 恢复原样重跑 B4，不要手改任何 .py |
