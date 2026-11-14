#!/usr/bin/env bash
# 针对上游的本地修正，在每次 checkout 基座之后执行（幂等，可重复运行）。
#
# 每条修正都必须满足：上游哪天自己修好了，这里的判断会自动变成空操作。
# 如果修正越来越多（>3 条），说明该改用正式的 patch 流程，而不是继续堆 sed。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-$ROOT/openwrt}"

log() { printf '  %s\n' "$*"; }

# ---- 1) hnat-detect：ip-tiny 与 ip-full 互斥 ----
# 上游给 hnat-detect 声明了 +ip-tiny，而 nikki / mihomo-meta 依赖 ip-full，
# 两者都提供 `ip` 且互斥，apk 在 package/install 阶段报 "unable to select packages"。
# ip-full 是 ip-tiny 的超集，直接把依赖换成 ip-full。
HNAT_MK="$WORK/package/mtk/applications/hnat-detect/Makefile"
if [ -f "$HNAT_MK" ] && grep -q '+ip-tiny' "$HNAT_MK"; then
	log "hnat-detect: DEPENDS 中的 +ip-tiny → +ip-full"
	sed -i 's/+ip-tiny/+ip-full/' "$HNAT_MK"
fi

# ---- 2) 默认 LAN 地址：192.168.1.1 → 192.168.11.1 ----
# config_generate 在首次启动生成 /etc/config/network 时用这里的默认值；
# 不修改镜像里的静态配置，用户上手后自行改地址也不会被覆盖。
CG="$WORK/package/base-files/files/bin/config_generate"
if [ -f "$CG" ] && grep -q '192\.168\.1\.1' "$CG"; then
	log "config_generate: 默认 LAN 192.168.1.1 → 192.168.11.1"
	sed -i 's/192\.168\.1\.1/192.168.11.1/g' "$CG"
fi

exit 0
