#!/usr/bin/env bash
# 下载构建期需要的全部预置资源，落在 packages/local/*/files/ 下，由本地包装进镜像：
#
#   oxidns standard 内核 + webui   → packages/local/rax3000m-files/
#   pcdn-detect（C 版）            → packages/local/rax3000m-files/
#   mihomo geo 数据                → packages/local/mihomo-geodata/
#
#   scripts/fetch-assets.sh          # 缺失才下载
#   scripts/fetch-assets.sh --force  # 强制重下（geo 数据会自动更新，其余一般不需要）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES="$ROOT/packages/local/rax3000m-files/files"
GEO="$ROOT/packages/local/mihomo-geodata/files/etc/nikki/run"
FORCE=0

# shellcheck disable=SC1091
source "$ROOT/locks/cores.lock"

log() { printf '==> %s\n' "$*"; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--force) FORCE=1; shift ;;
		-h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) die "未知参数: $1" ;;
	esac
done

mirror() { if [ -n "${GITHUB_MIRROR:-}" ]; then printf '%s/%s' "${GITHUB_MIRROR%/}" "$1"; else printf '%s' "$1"; fi; }

fetch() { # fetch <url> <dest>  —— 镜像失败自动回退直连
	local url="$1" dest="$2"
	if curl -fSL --retry 3 --retry-delay 2 --connect-timeout 20 -m 600 -o "$dest" "$(mirror "$url")"; then
		return 0
	fi
	[ -n "${GITHUB_MIRROR:-}" ] || die "下载失败: $url"
	echo "    镜像失败，回退直连"
	curl -fSL --retry 3 --retry-delay 2 --connect-timeout 20 -m 600 -o "$dest" "$url" \
		|| die "下载失败: $url"
}

sha_ok() { # sha_ok <file> <expected>
	[ -z "${2:-}" ] && return 0
	local got; got="$(sha256sum "$1" | awk '{print $1}')"
	[ "$got" = "$2" ] || die "SHA256 不匹配: $1（期望 $2，实际 $got）"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$FILES/usr/bin" "$FILES/usr/share/oxidns" "$GEO"

# ---------- oxidns ----------
log "oxidns ${OXIDNS_VERSION} (${OXIDNS_BUNDLE})"
fetch "https://github.com/svenshi/oxidns/releases/download/v${OXIDNS_VERSION}/${OXIDNS_ASSET}" "$TMP/oxidns.tgz"
sha_ok "$TMP/oxidns.tgz" "${OXIDNS_SHA256:-}"
tar -xzf "$TMP/oxidns.tgz" -C "$TMP"
[ -f "$TMP/oxidns" ] || die "压缩包内没有 oxidns 可执行文件"
install -m 0755 "$TMP/oxidns" "$FILES/usr/bin/oxidns"
rm -rf "$FILES/usr/share/oxidns/webui"
cp -a "$TMP/webui" "$FILES/usr/share/oxidns/webui"
[ -f "$TMP/LICENSE" ] && install -m 0644 "$TMP/LICENSE" "$FILES/usr/share/oxidns/LICENSE"

# ---------- pcdn-detect ----------
log "pcdn-detect ${PCDN_VERSION} (C 版)"
fetch "https://github.com/${PCDN_REPO}/releases/download/${PCDN_VERSION}/${PCDN_ASSET}" "$TMP/pcdn-detect"
sha_ok "$TMP/pcdn-detect" "${PCDN_SHA256:-}"
install -m 0755 "$TMP/pcdn-detect" "$FILES/usr/bin/pcdn-detect"

# ---------- mihomo geo 数据 ----------
log "mihomo geo 数据"
for pair in "$GEODATA_GEOIP_ASSET:geoip.metadb:${GEODATA_GEOIP_SHA256:-}" \
            "$GEODATA_GEOSITE_ASSET:geosite.dat:${GEODATA_GEOSITE_SHA256:-}"; do
	asset="${pair%%:*}"; rest="${pair#*:}"; out="${rest%%:*}"; want="${rest#*:}"
	if [ "$FORCE" -eq 0 ] && [ -s "$GEO/$out" ]; then
		printf '    %-14s 已存在，跳过\n' "$asset"
		continue
	fi
	fetch "$GEODATA_BASE/$asset" "$TMP/$asset"
	sha_ok "$TMP/$asset" "$want"
	mv -f "$TMP/$asset" "$GEO/$out"
	printf '    %-14s %6s\n' "$asset" "$(du -h "$GEO/$out" | cut -f1)"
done

cat > "$FILES/.assets.env" <<EOF
OXIDNS_VERSION=${OXIDNS_VERSION}
OXIDNS_BUNDLE=${OXIDNS_BUNDLE}
PCDN_VERSION=${PCDN_VERSION}
GEOIP_SHA256=$(sha256sum "$GEO/geoip.metadb" | awk '{print $1}')
GEOSITE_SHA256=$(sha256sum "$GEO/geosite.dat" | awk '{print $1}')
EOF

log "完成：$(du -sh "$FILES/usr/bin" | cut -f1) 内核 / $(du -sh "$GEO" | cut -f1) geo 数据"
