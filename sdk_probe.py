#!/usr/bin/env python3
"""sdk_probe.py —— 链路探针（可搬迁版）：创建沙箱 → uname -m → 执行命令 → 删除。
用法: python3 sdk_probe.py [模板名]
环境: E2B_API_URL/E2B_API_KEY 已由 start 脚本设置，或本脚本从参数文件读。
"""
import os, sys, time, asyncio, re

HERE = os.path.dirname(os.path.abspath(__file__))

# 从 machine.env 取 key（若环境变量未设置）
if not os.environ.get("E2B_API_KEY"):
    env = open(os.path.join(HERE, "machine.env"), encoding="utf-8").read()
    m = re.search(r'^E2B_API_KEY="([^"]*)"', env, re.M)
    key = m.group(1) if m else ""
    if not key:
        key_m = re.search(r'^RUNTIME_HOME="([^"]*)"', env, re.M)
        if key_m:
            p = os.path.join(key_m.group(1), "home", "api-key")
            if os.path.isfile(p):
                txt = open(p).read().strip()
                mm = re.search(r"e2b_[a-f0-9]+", txt)   # 165 风格 key
                key = mm.group(0) if mm else txt.splitlines()[0].strip()  # 或裸 key（89 风格）
    os.environ["E2B_API_KEY"] = key

m = re.search(r'^API_PORT=(\d+)', open(os.path.join(HERE, "machine.env"), encoding="utf-8").read(), re.M)
port = m.group(1) if m else "18100"
os.environ.setdefault("E2B_API_URL", f"http://127.0.0.1:{port}")
os.environ.setdefault("E2B_SANDBOX_URL", f"http://127.0.0.1:{port}")
os.environ.setdefault("NO_PROXY", "*")

# SDK 覆盖层路径（可搬迁：从 machine.env 读）
env_txt = open(os.path.join(HERE, "machine.env"), encoding="utf-8").read()
overlay = re.search(r'^SDK_OVERLAY="([^"]*)"', env_txt, re.M)
if overlay:
    sys.path.insert(0, overlay.group(1))

from e2b import AsyncSandbox

TEMPLATE = sys.argv[1] if len(sys.argv) > 1 else "probe-template"


async def main():
    t0 = time.time()
    sbx = await AsyncSandbox.create(template=TEMPLATE, timeout=300)
    t1 = time.time()
    print(f"created in {t1-t0:.2f}s, id={sbx.sandbox_id}")
    r = await sbx.commands.run("echo probe-OK && uname -m && nproc")
    t2 = time.time()
    print(f"command took {t2-t1:.2f}s, stdout={r.stdout!r} exit={r.exit_code}")
    await sbx.kill()
    print("killed OK, total", round(time.time() - t0, 2), "s")
    assert "x86_64" in r.stdout, "!! 沙箱不是 x86_64 —— 模板架构不对"

asyncio.run(main())
