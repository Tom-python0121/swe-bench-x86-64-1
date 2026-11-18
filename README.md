# SWE-bench 超分压测 · x86-64 可搬迁脚本包

> 更新：2026-11-17（拆分为与 aarch64 同构的结构，方便两边对照操作）
> 适用：x86（EPYC 9755 / Zen5）服务器上复刻 165（鲲鹏）超分压测口径
> 一句话：所有机器相关配置收在 `machine.env` 一个文件里——换机器只改这一个文件，其余脚本零硬编码。

## 快速上手

1. 按 **《小白部署手册-Zen5.md》**（实机定稿版 v2）九步执行——唯一权威文档
2. 每阶段自检：`./preflight.sh`（14 个脚本语法 + 配置完整性 + 路径）
3. harness 补丁与验证：见 **补丁-harness/GLM执行-三件套与补丁上机.md**，配合 `patch7-fixed-v4-20261117.tar.gz`（7 文件实战补丁）+ `verify-fixed4.sh`（29 个权威 md5，必须 29/29 PASS）

## 目录结构（与 aarch64 同构）

```
x86-64/
├── README.md / 小白部署手册-Zen5.md      ← 两份入口文档
├── machine.env                           ← 本机实配（.gitignore 挡住，不入库）
├── machine.env.example-zen5              ← Zen5 实测机配置模板（cp 即用，只核 DISKS）
├── start_bench_ratio{1,2,4,6,8,10}.sh    ← 六个薄壳：一档一脚本，与 aarch64 同名同用法
├── start_bench.sh                        ← 单场战役引擎（薄壳都调它，参数全读 machine.env）
├── run_campaign.sh                       ← 超分战役编排（多档扫描/97%停止/停滞检测/DONE断点续跑/API级清理）
├── relaunch_server.sh / health_check.sh  ← 私有 AgentENV server 启动 / 健康检查
├── launch_in_ns.sh / sdk_probe.py        ← nsenter 进 netns 通用封装 / 链路探针
├── bootstrap.sh / preflight.sh           ← 新机初始化 / 包自检
├── 补丁-harness/                          ← patch7 补丁包 + verify-fixed4.sh + GLM 执行任务书
└── 参考-规划与记录/                       ← 89 适配规划、两机分工、扫描操作说明、89 验证记录
```

## 脚本映射：aarch64（165 原版） ↔ x86-64（本包）

| 用途 | aarch64（165 实战） | x86-64（本包） | 差异说明 |
|---|---|---|---|
| 单场战役 | `start_bench_ratio{1,4,6,8,8b}.sh` | `start_bench_ratio{1,2,4,6,8,10}.sh` → `start_bench.sh` | 名字/用法一致；aarch64 参数硬编码在每份里，x86 收进 machine.env，薄壳只剩 RATIO |
| 起服务 | `relaunch_server_165.sh` | `relaunch_server.sh` | 同功能；盘名/路径/netns 全走变量，且自带停旧实例 |
| 进命名空间 | `launch_in_ns.sh` | `launch_in_ns.sh` | 原样 |
| 链路探针 | `sdk_probe.py` | `sdk_probe.py` | 原样 + api-key 两种格式兼容（e2b_ 前缀 / 裸 key） |
| 多档编排 | 参考-overcommit风格/（一档一编排）+ 补测-132/run_fillin.sh | `run_campaign.sh` 一个编排 | 165 时代一档一脚本；x86 合一：RATIOS 指定档位 + 97%/停滞/硬上限自动停 + DONE 断点续跑 |
| 健康检查 / 自检 / 初始化 | （无，手工） | `health_check.sh` / `preflight.sh` / `bootstrap.sh` | x86 新增 |
| 配置 | 散在各脚本里 | `machine.env`（唯一）+ `.example-zen5` 模板 | 换机器只改一个文件 |

## 命令对照（逐字一致的部分是特意做的）

| 场景 | 165（aarch64） | Zen5 实测机（x86-64） |
|---|---|---|
| 起服务 | `./relaunch_server_165.sh` | `./relaunch_server.sh && ./health_check.sh` |
| 单场 1:4 | `./launch_in_ns.sh bash start_bench_ratio4.sh` | **逐字一致**：`./launch_in_ns.sh bash start_bench_ratio4.sh` |
| 链路探针 | `./launch_in_ns.sh python3 sdk_probe.py <模板>` | 同左（python 用 SUITE 里 .venv 的） |
| 五档扫描 | （逐个手工跑） | `RATIOS="1 2 4 6 8" nohup ./run_campaign.sh > campaign.log 2>&1 &` |
| 只跑某档 | `nohup run_fillin.sh`（-132 补测） | `RATIOS="10" nohup ./run_campaign.sh > ratio10.log 2>&1 &` |

## 口径映射：aarch64 硬编码 ↔ x86 machine.env

| 参数 | aarch64（165 写死） | x86（machine.env 变量） | 备注 |
|---|---|---|---|
| 基准数 | `--base-count 384`（线程锚定） | `BASE_N=330` = min(512线程, 1321G÷4)，内存锚定 | 两边语义一致：1:1 名义内存 ≈ 物理内存 |
| 启动间隔 | 0.05s | `LAUNCH_INTERVAL_SEC=0.05` | reproduce 口径 |
| 请求/命令超时 | 300s / 1800s | `REQUEST_TIMEOUT_SEC=300` / `COMMAND_TIMEOUT_SEC=1800` | |
| 失败即停 | `--stop-on-failure` | `STOP_ON_FAILURE=1` | |
| cgroup | 无 | `CG_LIMIT_GIB=0`（仅 1:10 单档临时改 1200 当保险丝） | x86 多一道 1:10 保护 |
| 结果目录 | results-reproduce-<日期>/continuous-ratio-N | `RESULTS_ROOT` 下 campaign-<时间戳>/ratio-XX/ | 档位目录同为零填充命名（ratio-10 不是 ratio-010） |

## 口径与四锁（与 aarch64 数据可比的前提）

reproduce 系列：launch-interval 0.05s / cmd-timeout 1800s / req-timeout 300s / stop-on-failure。
四锁：①代码锁（harness 补丁到 165 fixed-v4 实战版）②输入锁（384 轨迹 + image-map 模板名不变）③口径锁（machine.env + baseline.json 自动留档）④环境锁（swapoff、THP=always、governor=performance、不绑核、独占窗口）。详见项目文档《实验设计-跨机变量控制-20261117.md》。

## 注意

- `machine.env` 是每台机器各自的实际配置，**不入库**（模板用 example 文件，`.gitignore` 已挡）
- 本仓库含内网部署路径信息，建议 **Private 私有仓库**；`脚本\aarch64` 里的 start_bench_ratio1.sh 含明文 API key——**不要**把 aarch64 目录原样上传
- 华为内网机器大概率访问不了 GitHub——机器部署仍走 WinSCP 从本地 D 盘传，仓库用于备份/版本管理/分享
- 新机拿到包后第一件事：`./preflight.sh`（本包已在 89 机[同款 EPYC 9755]上全量验证过语法与自检）
