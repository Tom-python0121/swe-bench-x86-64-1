# x86-64 五档超分扫描操作手册（1:1 1:2 1:4 1:6 1:8 1:10）

> 生成：2026-11-17。适用：新 Zen5 实测机（规格待定）+ `脚本/x86-64/` 可搬迁包
> 口径默认 = reproduce 系列（base 384 / interval 0.05 / req-to 300 / stop-on-failure），与 165 的 -132 四档直接可比
> 机器未到位时本手册先存档；到位后按第五节 bring-up 后即可执行

> ---
> **⚠️ 2026-11-17 晚更新：实测机已定稿（EPYC 9755×2、512 线程、1321GiB 内存、BASE_N=330）——执行以《小白部署手册-Zen5.md（实机定稿版 v2）》为准**，配合新增的 `machine.env.example-zen5` 模板。本文档写于机器未定时期，分档示例（BASE_N=376 等）仅作方法学参考。

## 一、扫描计划（六场战役）

| 档 | 沙箱数 | BASE_N=376 时 | 预计时长 | 说明 |
|---|---|---|---|---|
| **1:1** | BASE_N | 376 | ~1.5h | **基线档，必须先跑**（配对劣化的分母） |
| 1:2 | ×2 | 752 | ~1h | 新增档（aarch64 -132 补测中） |
| 1:4 | ×4 | 1504 | ~1.5h | 与 -132 直接对数 |
| 1:6 | ×6 | 2256 | ~2h | 与 -132 直接对数 |
| 1:8 | ×8 | 3008 | ~2.5h | 与 -132 直接对数；165 上真瓶颈初现档 |
| 1:10 | ×10 | 3760 | ~3h+ | **找真上限**：名义 15TB vs 物理内存，盯 MemAvailable |

注：`machine.env` 的 `RATIOS="1 2 4 6 8 10"` 已含 1:1 基线——**别删它**，删了就没有配对劣化的分母。

## 二、开跑前 checklist（machine.env 逐项）

```
MACHINE_TAG   = zen5-xxx（结果目录标签）
RUNTIME_HOME  = 私有实例目录（bootstrap 已建）
DATA_ROOT     = 大存储盘
DISKS         = lsblk 确认的实际数据盘名
E2B_API_KEY   = 私有实例的 key（留空自动读 api-key 文件）
BASE_N        = min(逻辑核数, 可用内存GiB/4)   ← 按新机规格算！
RATIOS        = "1 2 4 6 8 10"
CG_LIMIT_GIB  = 0（reproduce 口径不限内存预算）
PROBE_TEMPLATE= 任一已就绪模板的 ID（强烈建议填）
STOP_ON_FAILURE=1（reproduce 口径）
```

## 三、执行

```bash
cd /path/to/脚本包
# 全档扫描（一条命令，自动按序跑完六场；中断重跑自动跳过已完成档）
nohup ./run_campaign.sh > campaign-console.log 2>&1 &
tail -f campaign-console.log
# 观察点：每 30s 一行 done=x/n (%) idle=..min fc=..  memavail（在 mem.csv 里）

# 只补单档（例如 1:10 崩了重跑）
RATIOS="10" ./run_campaign.sh
```

每档产出：`$RESULTS_ROOT/campaign-<TAG>-<日期>/ratio-N/`（baseline.json 记口径 + mem.csv 监控 + bench/ 逐任务数据 + DONE.txt）

## 四、1:10 风险与兜底（与 aarch64 补测同款）

1. **创建风暴**：3760~3840 沙箱 0.05s 间隔起，可能触发 stop-on-failure 早停。兜底：重跑一次；仍崩则改 machine.env 三项降参——`LAUNCH_INTERVAL_SEC=0.30 / REQUEST_TIMEOUT_SEC=1800 / CREATE_RETRIES=2`（dtlbi r10 同款保守参数）——**降参后口径不一致，分析必须标注**，且建议只对 1:10 单档降参（用 `RATIOS="10"` 单独跑）
2. **内存见底**：1:10 名义 15TB vs 物理内存。MemAvailable 若逼近 40GB 看门狗线，说明到了真上限——这正是实验目的，让战役自然结束（或硬上限 200min 兜底）
3. **共机**：新机最好是独占的；若共机，mem.csv 的 fc_n 列事后可区分敌我

## 五、新机 bring-up（未做过时先做这个）

```bash
# 1. 放好脚本包，改 machine.env（第二节 checklist）
# 2. 初始化私有实例（SEED=随包带的 x86 种子，或 89:/data/x86oversub-aenv 打包）
SEED=/path/to/seed ./bootstrap.sh
# 3. 起 server + 健康检查
./relaunch_server.sh && ./health_check.sh
# 4. 模板就位（384 个 swb-*__2u4g，x86 重建——见 VALIDATION-89.md 第四节）后链路验证
./launch_in_ns.sh python3 sdk_probe.py swb-<任一轨迹名>__2u4g
# 5. 回到第三节开扫
```

## 六、扫描完成后的分析流

1. 聚合：每档的 bench/ratio-XX/repeat-01/tasks/*/replay-result.json → 用 165 同款口径聚合（aggfinal.py/agg_dtlbi.py 模板，改路径）
2. 图表：三图模板（图1 TaskWallTime 分档位 / 图2 劣化与内存 / 图3 汇总表）——六点曲线，aarch64 -132 只有四点+补测两点，**x86 是最全的一侧**
3. 跨机对照：1:2/1:4/1:6/1:8 四点与 165 -132 直接对数（同 reproduce 口径）；1:1 各自做基线；产出 950 vs x86 对比结论

## 七、与 aarch64 侧的对称性

| | aarch64（165） | x86-64（新机） |
|---|---|---|
| 脚本 | rerun-165-20261109/ 原版 + 补测-132/ | 脚本/x86-64/ 可搬迁包 |
| 档位 | 1:1/1:4/1:6/1:8 已测 + 1:2/1:10 补测中 | 1:1~1:10 全扫 |
| 口径 | reproduce（base 384） | reproduce（BASE_N 按机器规格） |
| 内核 | -132（门禁强制） | 新机原厂内核（baseline.json 自动记录） |
