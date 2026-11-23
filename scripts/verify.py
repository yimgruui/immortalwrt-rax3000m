#!/usr/bin/env python3
"""构建前后的一致性校验。

check-config：确认「片段里声明的必需包」真的进了 .config（make defconfig 对缺失包是静默丢弃的），
             并确认显式关闭的包（如 uhttpd）没有被别的依赖悄悄拉回来。
check-image ：确认产物存在、体积合理、manifest 里包含全部必需包且不含禁用包，
             并生成发布用的 manifest 与说明。

用法：
  python3 scripts/verify.py check-config --config openwrt/.config \\
      --expected build-artifacts/expected-packages.txt \\
      --forbidden build-artifacts/forbidden-packages.txt \\
      --device devices/rax3000m-nand
  python3 scripts/verify.py check-image --device devices/rax3000m-nand \\
      --expected build-artifacts/expected-packages.txt --dist dist
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import sys


def die(msg: str) -> "None":
    # GitHub Actions 会把 ::error:: 渲染成注解，方便直接在 run 页面看到
    print(f"::error::{msg}", file=sys.stderr)
    print(f"verify: 错误：{msg}", file=sys.stderr)
    sys.exit(1)


def read_kv(path: str) -> dict:
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


def read_list(path: str) -> list[str]:
    if not path or not os.path.isfile(path):
        return []
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
    expected = read_list(args.expected)
    forbidden = read_list(getattr(args, "forbidden", ""))

    missing = [p for p in expected if cfg.get(f"CONFIG_PACKAGE_{p}") != "y"]
    if missing:
        print("以下必需包没有进入 .config（通常是包不存在 / 外部包未 clone 成功）：", file=sys.stderr)
        for p in missing:
            print(f"  - {p}", file=sys.stderr)
        die(f"{len(missing)} 个必需包缺失")

    leaked = [p for p in forbidden if cfg.get(f"CONFIG_PACKAGE_{p}") == "y"]
    if leaked:
        for p in leaked:
            print(f"  - {p}（片段里要求不装，但被别的依赖拉回来了）", file=sys.stderr)
        die(f"{len(leaked)} 个禁用包被启用")

    if args.device:
        dev = read_kv(os.path.join(args.device, "device.conf"))
        for key in ("DEVICE_TARGET", "DEVICE_SUBTARGET", "DEVICE_PROFILE"):
            knob = dev.get(key, "")
            if not knob:
                die(f"{args.device}/device.conf 缺少 {key}")
            if cfg.get(knob) != "y":
                die(f"{knob} 未启用（设备三元组与基座不匹配？）")

    print(f"check-config: 通过（必需包 {len(expected)} 个，禁用包 {len(forbidden)} 个）")
    return 0


# OpenWrt 给库包加了 ABI 版本后缀：libnl-core → libnl-core200、libatomic1、libfido2-1…
# 期望清单来自 Kconfig 名（无后缀），manifest 里是实际包名，所以这里允许“无后缀名 + ABI 后缀”匹配。
ABI_SUFFIX = re.compile(r"^[-_]?[0-9]+$")


def package_present(expected: str, installed: set[str]) -> bool:
    if expected in installed:
        return True
    for name in installed:
        if name.startswith(expected) and ABI_SUFFIX.match(name[len(expected):]):
            return True
    return False


def cmd_check_coverage(args: argparse.Namespace) -> int:
    """本地包（packages/local/*）必须都被某个特性片段启用。

    期望包清单是“你声明了什么就查什么”，所以“写了包但忘了启用”这类疏漏它查不出来——
    这个检查专门补这个盲区：目录存在 = 打算用，那就必须在 .config 里 =y。
    """
    cfg = read_config(args.config)
    checked, missing = 0, []
    for name in sorted(os.listdir(args.dirs)):
        pkg_dir = os.path.join(args.dirs, name)
        if not os.path.isdir(pkg_dir) or not os.path.isfile(os.path.join(pkg_dir, "Makefile")):
            continue
        checked += 1
        if cfg.get(f"CONFIG_PACKAGE_{name}") != "y":
            missing.append(name)
    if missing:
        for name in missing:
            print(f"  - {name}（目录存在但未在 features/*.configfrag 里启用）", file=sys.stderr)
        die(f"{len(missing)} 个本地包未被启用，它们不会进镜像")
    print(f"check-coverage: 通过（本地包 {checked} 个均已启用）")
    return 0


def cmd_check_image(args: argparse.Namespace) -> int:
    dev = read_kv(os.path.join(args.device, "device.conf"))
    bin_dir = os.path.join(args.bin_root, "bin/targets", dev.get("BIN_DIR", ""))
    size_max = args.size_max_mb or float(dev.get("SIZE_MAX_MB", "120"))

    itbs = sorted(glob.glob(os.path.join(bin_dir, dev.get("IMAGE_GLOB", "*sysupgrade.itb"))))
    if len(itbs) != 1:
        die(f"{bin_dir} 下应有且仅有 1 个 sysupgrade 镜像，实际 {len(itbs)} 个")
    image = itbs[0]
    size_mb = os.path.getsize(image) / (1024 * 1024)
    if size_mb > size_max:
        die(f"镜像 {size_mb:.1f}MB 超过上限 {size_max}MB（NAND 余量不足）")

    manifests = sorted(glob.glob(os.path.join(bin_dir, "*.manifest")))
    if len(manifests) != 1:
        die(f"{bin_dir} 下应有且仅有 1 个 .manifest，实际 {len(manifests)} 个")
    installed: set[str] = set()
    with open(manifests[0], encoding="utf-8") as fh:
        for line in fh:
            name = line.split(" - ")[0].strip()
            if name:
                installed.add(name)

    expected = read_list(args.expected)
    missing = [p for p in expected if not package_present(p, installed)]
    abi_matched = [p for p in expected
                   if p not in installed and package_present(p, installed)]
    if abi_matched:
        print(f"  （{len(abi_matched)} 个包按 ABI 后缀匹配：{', '.join(abi_matched)}）")
    if missing:
        # 库包在 OpenWrt 里常见两种情况：ABI 后缀（已匹配）、或纯虚拟包（如 libnl，
        # 由 libnl-core200 PROVIDES，根本没有独立 ipk）。这类缺失只告警，不判失败；
        # 应用/内核模块/固件包缺失则是硬错误。
        hard = [p for p in missing if not p.startswith("lib")]
        soft = [p for p in missing if p.startswith("lib")]
        if soft:
            print(f"  warning: {len(soft)} 个库包未在 manifest 中（可能为虚拟包）：{', '.join(soft)}")
        if hard:
            for p in hard:
                print(f"  - {p}", file=sys.stderr)
            die(f"{len(hard)} 个必需包不在镜像 manifest 中")

    forbidden = read_list(getattr(args, "forbidden", ""))
    leaked = [p for p in forbidden if package_present(p, installed)]
    if leaked:
        die(f"镜像里仍然装着明确要求移除的包：{', '.join(leaked)}")

    os.makedirs(args.dist, exist_ok=True)
    recovery = sorted(glob.glob(os.path.join(bin_dir, dev.get("RECOVERY_GLOB", "*recovery.itb"))))

    artifacts = [image, *recovery]
    for src in artifacts:
        shutil.copy2(src, os.path.join(args.dist, os.path.basename(src)))

    digest = sha256_of(image)
    with open(os.path.join(args.dist, "sha256sums"), "w", encoding="utf-8") as fh:
        for src in artifacts:
            fh.write(f"{sha256_of(src)}  {os.path.basename(src)}\n")

    manifest = {
        "device": dev.get("DEVICE_ID", args.device),
        "target": dev.get("TARGET_NAME", ""),
        "arch": dev.get("DEVICE_ARCH", ""),
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
        "forbidden_packages": forbidden,
    }
    with open(os.path.join(args.dist, "build-manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)

    run_line = (f"构建日志：https://github.com/{args.repo}/actions/runs/{args.run_id}"
                if args.repo and args.run_id else "")

    notes = [
        f"# {dev.get('DEVICE_NAME', dev.get('DEVICE_ID', '固件'))} 固件",
        "",
        f"`{os.path.basename(image)}` · {size_mb:.1f} MB · {len(installed)} 个软件包",
        "",
        f"基座 `{args.upstream_repo.rsplit('/', 1)[-1]}` @ `{args.commit[:12]}`"
        f" · 设备 `{dev.get('DEVICE_ID', args.device)}`",
        "",
        "## 刷机",
        "",
        f"1. 仅适用于 **{dev.get('DEVICE_NAME', dev.get('DEVICE_ID'))}**，刷错硬件版本会变砖。",
        f"2. 刷完浏览器打开 `http://{dev.get('LAN_IP', '192.168.11.1')}`，80 端口直接是 LuCI（HTTP，不跳 https）。",
        "3. 系统 → 备份/升级 → 刷写 `*-squashfs-sysupgrade.itb`；要保留现有配置就不要勾「不保留配置」。",
        "4. 系统起不来时，用 `*-initramfs-recovery.itb` 从 U-Boot 恢复。",
        "",
        "## 内容",
        "",
        "| 组件 | 说明 |",
        "| --- | --- |",
        "| Web | nginx（无 uhttpd）：80 直连 LuCI，443 自签备用 |",
        "| 反向代理 | `luci-app-nginx-proxy`：只写 `conf.d/proxy.d`，失败自动回滚 |",
        "| 自愈 | `nginx-guard` 开机探测 80，配置坏了自动清理反代配置 |",
        "| DNS / 去广告 | nikki（mihomo）默认 fake-ip + `category-ads-all` / `adblock` REJECT |",
        "| SSH | 无预置公钥；`luci-app-device-key` 现场生成每台设备专属密钥 |",
        f"| pcdn-detect | {manifest['cores'].get('pcdn', '?')}（C 版，默认启用） |",
        "| 主题 | argon，登录背景已替换 |",
        "",
        "无线走 MT7981 私有驱动（`mt_wifi`），带 HNAT / WARP 硬件加速。",
        "",
        "## 校验",
        "",
        "| 项 | 值 |",
        "| --- | --- |",
        f"| 文件 | `{os.path.basename(image)}` |",
        f"| 大小 | {size_mb:.1f} MB |",
        f"| 软件包 | {len(installed)} |",
        f"| SHA256 | `{digest}` |",
        "",
        "## 首次开机",
        "",
        "- 管理地址 `192.168.11.1`，用户名 `root`，密码为空（首次登录请立刻设置）；",
        "- dropbear 在 2222 端口；到「系统 → 管理权 → 设备 SSH 密钥」生成并领取专属私钥；",
        "- 需要 IPv6 域名解析时，按 README 的说明打开 nikki 的 IPv6 假地址段；",
        "- 反代规则在「服务 → Nginx Reverse Proxy」里加，保存即生效。",
    ]
    if run_line:
        notes += ["", f"> {run_line}"]
    with open(os.path.join(args.dist, "release-notes.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(notes) + "\n")

    print(f"check-image: 通过（{size_mb:.1f}MB，manifest 含 {len(installed)} 个包）")
    return 0


def parse_cores(path: str) -> dict:
    cores: dict[str, str] = {}
    wanted = {"PCDN_VERSION": "pcdn"}
    if path and os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                if key in wanted:
                    cores[wanted[key]] = val
    return cores


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("check-config")
    p1.add_argument("--config", required=True)
    p1.add_argument("--expected", required=True)
    p1.add_argument("--forbidden", default="")
    p1.add_argument("--device", default="", help="devices/<id>，用于校验设备三元组")

    p3 = sub.add_parser("check-coverage")
    p3.add_argument("--dirs", default="packages/local")
    p3.add_argument("--config", required=True)

    p2 = sub.add_parser("check-image")
    p2.add_argument("--device", required=True)
    p2.add_argument("--bin-root", default="openwrt")
    p2.add_argument("--expected", required=True)
    p2.add_argument("--forbidden", default="")
    p2.add_argument("--dist", required=True)
    p2.add_argument("--run-id", default="")
    p2.add_argument("--repo", default="")
    p2.add_argument("--commit", default="")
    p2.add_argument("--upstream-repo", default="")
    p2.add_argument("--upstream-branch", default="")
    p2.add_argument("--features", default="")
    p2.add_argument("--cores-file", default="locks/cores.lock")
    p2.add_argument("--size-max-mb", type=float, default=0.0)

    args = ap.parse_args()
    if args.cmd == "check-config":
        return cmd_check_config(args)
    if args.cmd == "check-coverage":
        return cmd_check_coverage(args)
    args.cores = parse_cores(args.cores_file)
    return cmd_check_image(args)


if __name__ == "__main__":
    sys.exit(main())
