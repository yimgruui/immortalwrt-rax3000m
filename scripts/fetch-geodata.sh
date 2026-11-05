#!/usr/bin/env bash
# 下载 mihomo 的 geo 规则数据（geoip.metadb / geosite.dat）到本地包目录。
#
#   scripts/fetch-geodata.sh             # 缺失才下载（默认）
#   scripts/fetch-geodata.sh --force     # 强制重新下载
#
# 数据约 12MB，构建期一次，随镜像交付；设备端不需要再访问 GitHub。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/packages/local/mihomo-geodata/files/etc/nikki/run"
FORCE=0

# shellcheck disable=SC1091
source "$ROOT/locks/geodata.lock"

log() { printf '==> %s\n' "$*"; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--force) FORCE=1; shift ;;
		-h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) die "未知参数: $1" ;;
	esac
done

with_mirror() {
	if [ -n "${GITHUB_MIRROR:-}" ]; then printf '%s/%s' "${GITHUB_MIRROR%/}" "$1"; else printf '%s' "$1"; fi
}

fetch_one() { # fetch_one <asset> <expected_sha> <dest>
	local asset="$1" want="$2" dest="$3" url tmp got
	url="$(with_mirror "$GEODATA_BASE/$asset")"

	if [ "$FORCE" -eq 0 ] && [ -s "$dest" ]; then
		echo "    $asset 已存在，跳过（--force 可重下）"
		return 0
	fi

	mkdir -p "$(dirname "$dest")"
	tmp="$(mktemp)"
	if ! curl -fSL --retry 3 --retry-delay 2 --connect-timeout 20 -m 600 -o "$tmp" "$url"; then
		# 部分加速镜像对 release 大文件会返回 403，回退直连再试一次
		if [ -n "${GITHUB_MIRROR:-}" ]; then
			echo "    镜像失败，回退直连"
			curl -fSL --retry 3 --retry-delay 2 --connect-timeout 20 -m 600 -o "$tmp" "$GEODATA_BASE/$asset" \
				|| { rm -f "$tmp"; die "下载失败: $GEODATA_BASE/$asset"; }
		else
			rm -f "$tmp"; die "下载失败: $url"
		fi
	fi
	got="$(sha256sum "$tmp" | awk '{print $1}')"
	if [ -n "$want" ] && [ "$got" != "$want" ]; then
		rm -f "$tmp"
		die "$asset SHA256 不匹配（期望 $want，实际 $got）"
	fi
	mv -f "$tmp" "$dest"
	printf '    %-16s %6s  %s\n' "$asset" "$(du -h "$dest" | cut -f1)" "${got:0:12}…"
}

log "mihomo geo 数据"
fetch_one "$GEODATA_GEOIP_ASSET" "${GEODATA_GEOIP_SHA256:-}" "$DEST/geoip.metadb"
fetch_one "$GEODATA_GEOSITE_ASSET" "${GEODATA_GEOSITE_SHA256:-}" "$DEST/geosite.dat"

cat > "$DEST/.geodata.env" <<EOF
GEOIP_SHA256=$(sha256sum "$DEST/geoip.metadb" | awk '{print $1}')
GEOSITE_SHA256=$(sha256sum "$DEST/geosite.dat" | awk '{print $1}')
EOF

log "完成：$(du -sh "$DEST" | cut -f1)"
