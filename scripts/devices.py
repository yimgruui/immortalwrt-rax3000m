#!/usr/bin/env python3
"""枚举 devices/ 下的设备模板，给 GitHub Actions 生成 matrix。

用法：
  python3 scripts/devices.py --matrix        # {"include":[{"device":"rax3000m-nand"}]}
  python3 scripts/devices.py --list          # 每行一个设备 id
  python3 scripts/devices.py --show <id>     # 打印该设备的 device.conf 摘要
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys


def devices(root: str) -> list[str]:
    out = []
    for path in sorted(glob.glob(os.path.join(root, "devices", "*", "device.conf"))):
        out.append(os.path.basename(os.path.dirname(path)))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--matrix", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--show", default="")
    args = ap.parse_args()

    found = devices(args.root)
    if not found:
        print("devices.py: 错误：devices/*/device.conf 为空", file=sys.stderr)
        return 1

    if args.show:
        conf = os.path.join(args.root, "devices", args.show, "device.conf")
        if not os.path.isfile(conf):
            print(f"devices.py: 错误：找不到 {conf}", file=sys.stderr)
            return 1
        with open(conf, encoding="utf-8") as fh:
            print(fh.read())
        return 0

    if args.matrix:
        print(json.dumps({"include": [{"device": d} for d in found]}, ensure_ascii=False))
        return 0

    print("\n".join(found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
