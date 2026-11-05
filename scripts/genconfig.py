#!/usr/bin/env python3
"""按 features/series 合成 OpenWrt .config，并导出“期望包清单”。

设计要点：
  * 仓库里不存 .config，只存分层片段（features/*.configfrag）；
  * 同一 CONFIG 键按 series 顺序后覆盖前；
  * 期望包清单来自片段里的 CONFIG_PACKAGE_xxx=y，构建结束后拿去和 *.manifest 对账。

用法：
  python3 scripts/genconfig.py --target targets/rax3000m-nand.conf \
      --series features/series --features-dir features \
      --out openwrt/.config --expected build-artifacts/expected-packages.txt
"""

from __future__ import annotations

import argparse
import os
import re
import sys

RE_NOT_SET = re.compile(r"^#\s+(CONFIG_[A-Za-z0-9_\-]+)\s+is not set$")
RE_ASSIGN = re.compile(r"^(CONFIG_[A-Za-z0-9_\-]+)=(.*)$")


def die(msg: str) -> "None":
    print(f"genconfig: 错误：{msg}", file=sys.stderr)
    sys.exit(1)


def require_file(path: str, what: str) -> None:
    if not os.path.isfile(path):
        die(f"{what} 不存在：{path}")


def parse_kv(path: str) -> dict:
    """解析 KEY=VALUE 形式的 conf（支持行内注释与引号）。"""
    require_file(path, "target 配置")
    out: dict[str, str] = {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            val = val.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            out[key.strip()] = val
    return out


def parse_series(path: str) -> list[str]:
    require_file(path, "series 文件")
    names = []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            names.append(line)
    if not names:
        die(f"{path} 为空")
    return names


def parse_fragment(path: str) -> list[tuple[str, str]]:
    """返回 [(key, value)]；value 为 'n' 表示显式关闭。"""
    entries: list[tuple[str, str]] = []
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n").rstrip()
            if not line or line.lstrip().startswith("# ") and not RE_NOT_SET.match(line):
                continue
            if not line or line == "#":
                continue
            m = RE_NOT_SET.match(line)
            if m:
                entries.append((m.group(1), "n"))
                continue
            m = RE_ASSIGN.match(line)
            if m:
                entries.append((m.group(1), m.group(2)))
                continue
            if line.lstrip().startswith("#"):
                continue
            die(f"{path}:{lineno} 无法解析：{line}")
    return entries


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True, help="targets/*.conf")
    ap.add_argument("--series", required=True, help="features/series")
    ap.add_argument("--features-dir", default="features")
    ap.add_argument("--out", required=True, help="输出的 .config 路径")
    ap.add_argument("--expected", required=True, help="输出的期望包清单")
    args = ap.parse_args()

    target = parse_kv(args.target)
    for key in ("DEVICE_TARGET", "DEVICE_SUBTARGET", "DEVICE_PROFILE"):
        if key not in target:
            die(f"{args.target} 缺少 {key}")

    names = parse_series(args.series)

    merged: dict[str, str] = {}      # 保持首次插入顺序，后写覆盖前写
    origin: dict[str, str] = {}
    for name in names:
        path = os.path.join(args.features_dir, f"{name}.configfrag")
        if not os.path.isfile(path):
            die(f"series 里的 {name} 找不到对应文件：{path}")
        for key, val in parse_fragment(path):
            merged[key] = val
            origin[key] = name

    target_keys = {target["DEVICE_TARGET"], target["DEVICE_SUBTARGET"], target["DEVICE_PROFILE"]}
    for key in target_keys:
        merged.pop(key, None)        # 设备三元组统一放文件头部，避免片段里重复

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("# 由 scripts/genconfig.py 自动生成，请勿手改。\n")
        fh.write(f"# target={target.get('TARGET_NAME', '?')} series={','.join(names)}\n\n")
        for key in (target["DEVICE_TARGET"], target["DEVICE_SUBTARGET"], target["DEVICE_PROFILE"]):
            fh.write(f"{key}=y\n")
        for key, val in merged.items():
            if val == "n":
                fh.write(f"# {key} is not set\n")
            else:
                fh.write(f"{key}={val}\n")

    expected = sorted(k[len("CONFIG_PACKAGE_"):] for k, v in merged.items()
                      if k.startswith("CONFIG_PACKAGE_") and v == "y")
    os.makedirs(os.path.dirname(os.path.abspath(args.expected)), exist_ok=True)
    with open(args.expected, "w", encoding="utf-8") as fh:
        fh.write("\n".join(expected) + "\n")

    print(f"genconfig: {len(merged)} 个配置项 / {len(expected)} 个必需包 → {args.out}")
    if not expected:
        die("期望包清单为空，检查 features/*.configfrag")
    return 0


if __name__ == "__main__":
    sys.exit(main())
