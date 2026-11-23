#!/usr/bin/env bash
# 针对上游的本地修正，在每次 checkout 基座之后执行（幂等，可重复运行）。
#
# 每条修正都必须满足：上游哪天自己修好了，这里的判断会自动变成空操作。
# 如果修正越来越多，说明该改用正式的 patch 流程，而不是继续堆 sed。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-$ROOT/openwrt}"

log() { printf '  %s\n' "$*"; }

# ---- 默认 LAN 地址：192.168.1.1 → 192.168.11.1 ----
# config_generate 在首次启动生成 /etc/config/network 时用这里的默认值；
# 不修改镜像里的静态配置，用户上手后自行改地址也不会被覆盖。
CG="$WORK/package/base-files/files/bin/config_generate"
if [ -f "$CG" ] && grep -q '192\.168\.1\.1' "$CG"; then
	log "config_generate: 默认 LAN 192.168.1.1 → 192.168.11.1"
	sed -i 's/192\.168\.1\.1/192.168.11.1/g' "$CG"
fi

exit 0
