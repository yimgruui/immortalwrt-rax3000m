#!/usr/bin/env python3
"""构建前后的一致性校验。

check-config：确认「片段里声明的必需包」真的进了 .config（make defconfig 对缺失包是静默丢弃的）。
check-image ：确认产物存在、体积合理、manifest 里包含全部必需包，并生成发布用的 manifest 与说明。

用法：
  python3 scripts/verify.py check-config --config openwrt/.config --expected build-artifacts/expected-packages.txt
  python3 scripts/verify.py check-image --bin openwrt/bin/targets/mediatek/filogic \
      --expected build-artifacts/expected-packages.txt --dist dist --size-max-mb 120
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import shutil
import sys


def die(msg: str) -> "None":
    # GitHub Actions 会把 ::error:: 渲染成注解，方便直接在 run 页面看到
    print(f"::error::{msg}", file=sys.stderr)
    print(f"verify: 错误：{msg}", file=sys.stderr)
    sys.exit(1)


def read_config(path: str) -> dict:
    out: dict[str, str] = {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("# ") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            out[key] = val
    return out


def read_expected(path: str) -> list[str]:
    with open(path, encoding="utf-8") as fh:
        return [line.strip() for line in fh if line.strip()]


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_check_config(args: argparse.Namespace) -> int:
    cfg = read_config(args.config)
    expected = read_expected(args.expected)
    missing = [p for p in expected if cfg.get(f"CONFIG_PACKAGE_{p}") != "y"]
    if missing:
        print("以下必需包没有进入 .config（通常是包不存在 / 外部包未 clone 成功）：", file=sys.stderr)
        for p in missing:
            print(f"  - {p}", file=sys.stderr)
        die(f"{len(missing)} 个必需包缺失")
    for key in ("CONFIG_TARGET_mediatek", "CONFIG_TARGET_mediatek_filogic"):
        if cfg.get(key) != "y":
            die(f"{key} 未启用")
    print(f"check-config: 通过（必需包 {len(expected)} 个）")
    return 0


def cmd_check_image(args: argparse.Namespace) -> int:
    itbs = sorted(glob.glob(os.path.join(args.bin, "*sysupgrade.itb")))
    if len(itbs) != 1:
        die(f"{args.bin} 下应有且仅有 1 个 sysupgrade.itb，实际 {len(itbs)} 个")
    image = itbs[0]
    size_mb = os.path.getsize(image) / (1024 * 1024)
    if size_mb > args.size_max_mb:
        die(f"镜像 {size_mb:.1f}MB 超过上限 {args.size_max_mb}MB（NAND 余量不足）")

    manifests = sorted(glob.glob(os.path.join(args.bin, "*.manifest")))
    if len(manifests) != 1:
        die(f"{args.bin} 下应有且仅有 1 个 .manifest，实际 {len(manifests)} 个")
    installed = set()
    with open(manifests[0], encoding="utf-8") as fh:
        for line in fh:
            name = line.split(" - ")[0].strip()
            if name:
                installed.add(name)

    expected = read_expected(args.expected)
    missing = [p for p in expected if p not in installed]
    if missing:
        for p in missing:
            print(f"  - {p}", file=sys.stderr)
        die(f"{len(missing)} 个必需包不在镜像 manifest 中")

    os.makedirs(args.dist, exist_ok=True)
    recovery = sorted(glob.glob(os.path.join(args.bin, "*recovery.itb")))

    artifacts = [image, *recovery]
    for src in artifacts:
        shutil.copy2(src, os.path.join(args.dist, os.path.basename(src)))

    digest = sha256_of(image)
    with open(os.path.join(args.dist, "sha256sums"), "w", encoding="utf-8") as fh:
        for src in artifacts:
            fh.write(f"{sha256_of(src)}  {os.path.basename(src)}\n")

    manifest = {
        "target": args.target,
        "variant": args.variant,
        "upstream": {"repo": args.upstream_repo, "branch": args.upstream_branch, "commit": args.commit},
        "features": args.features.split(",") if args.features else [],
        "cores": args.cores,
        "image": {
            "file": os.path.basename(image),
            "size_bytes": os.path.getsize(image),
            "sha256": digest,
        },
        "packages": sorted(installed),
        "required_packages": expected,
    }
    with open(os.path.join(args.dist, "build-manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)

    notes = [
        f"# {args.target} 固件",
        "",
        "| 项 | 值 |",
        "| --- | --- |",
        f"| 变体 | `{args.variant}` |",
        f"| 上游 | `{args.upstream_repo}` @ `{args.commit[:12]}` |",
        f"| 内核版本 | oxidns `{manifest['cores'].get('oxidns', '?')}` / pcdn-detect `{manifest['cores'].get('pcdn', '?')}` |",
        f"| 镜像 | `{os.path.basename(image)}`（{size_mb:.1f}MB） |",
        f"| SHA256 | `{digest}` |",
        "",
        "默认地址 `192.168.11.1`，无默认密码。oxidns 与 pcdn-detect 已预置内核，刷入后无需联网安装。",
    ]
    with open(os.path.join(args.dist, "release-notes.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(notes) + "\n")

    print(f"check-image: 通过（{size_mb:.1f}MB，manifest 含 {len(installed)} 个包）")
    return 0


def parse_cores(path: str) -> dict:
    cores: dict[str, str] = {}
    if path and os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                if key in ("OXIDNS_VERSION", "PCDN_VERSION"):
                    cores["oxidns" if key.startswith("OXIDNS") else "pcdn"] = val
    return cores


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("check-config")
    p1.add_argument("--config", required=True)
    p1.add_argument("--expected", required=True)

    p2 = sub.add_parser("check-image")
    p2.add_argument("--bin", required=True)
    p2.add_argument("--expected", required=True)
    p2.add_argument("--dist", required=True)
    p2.add_argument("--variant", default="full")
    p2.add_argument("--target", default="rax3000m-nand")
    p2.add_argument("--commit", default="")
    p2.add_argument("--upstream-repo", default="")
    p2.add_argument("--upstream-branch", default="")
    p2.add_argument("--features", default="")
    p2.add_argument("--cores-file", default="packages/cores.lock")
    p2.add_argument("--size-max-mb", type=float, default=120.0)

    args = ap.parse_args()
    if args.cmd == "check-config":
        return cmd_check_config(args)
    args.cores = parse_cores(args.cores_file)
    return cmd_check_image(args)


if __name__ == "__main__":
    sys.exit(main())
