#!/usr/bin/env bash
# 下载并预置两个“壳 + 联网自装内核”的 LuCI 应用所需的内核与 webui。
# 目的：刷完机即用，不依赖设备侧访问 GitHub（国内多数环境不可达）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/packages/local/rax3000m-files/files"

# shellcheck disable=SC1091
source "$ROOT/locks/cores.lock"

log() { printf '==> %s\n' "$*"; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }

with_mirror() {
	if [ -n "${GITHUB_MIRROR:-}" ]; then printf '%s/%s' "${GITHUB_MIRROR%/}" "$1"; else printf '%s' "$1"; fi
}

fetch() { # fetch <url> <dest>
	local url dest
	url="$(with_mirror "$1")"
	dest="$2"
	curl -fSL --retry 3 --retry-delay 2 --connect-timeout 20 -m 600 -o "$dest" "$url" \
		|| die "下载失败: $url"
}

sha_ok() { # sha_ok <file> <expected>
	[ -z "$2" ] && return 0
	local got
	got="$(sha256sum "$1" | awk '{print $1}')"
	[ "$got" = "$2" ] || die "SHA256 不匹配: $1（期望 $2，实际 $got）"
}

mkdir -p "$DEST/usr/bin" "$DEST/usr/share/oxidns"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "oxidns ${OXIDNS_VERSION} (${OXIDNS_BUNDLE})"
OXI_URL="https://github.com/svenshi/oxidns/releases/download/v${OXIDNS_VERSION}/${OXIDNS_ASSET}"
fetch "$OXI_URL" "$TMP/oxidns.tgz"
sha_ok "$TMP/oxidns.tgz" "${OXIDNS_SHA256:-}"
tar -xzf "$TMP/oxidns.tgz" -C "$TMP"
[ -f "$TMP/oxidns" ] || die "压缩包内没有 oxidns 可执行文件"
install -m 0755 "$TMP/oxidns" "$DEST/usr/bin/oxidns"
rm -rf "$DEST/usr/share/oxidns/webui"
cp -a "$TMP/webui" "$DEST/usr/share/oxidns/webui"
[ -f "$TMP/LICENSE" ] && install -m 0644 "$TMP/LICENSE" "$DEST/usr/share/oxidns/LICENSE"

log "pcdn-detect ${PCDN_VERSION} (C 版)"
PCDN_URL="https://github.com/${PCDN_REPO}/releases/download/${PCDN_VERSION}/${PCDN_ASSET}"
fetch "$PCDN_URL" "$TMP/pcdn-detect"
sha_ok "$TMP/pcdn-detect" "${PCDN_SHA256:-}"
install -m 0755 "$TMP/pcdn-detect" "$DEST/usr/bin/pcdn-detect"

cat > "$DEST/.cores.env" <<EOF
OXIDNS_VERSION=${OXIDNS_VERSION}
OXIDNS_BUNDLE=${OXIDNS_BUNDLE}
OXIDNS_SHA256=$(sha256sum "$DEST/usr/bin/oxidns" | awk '{print $1}')
PCDN_VERSION=${PCDN_VERSION}
PCDN_SHA256=$(sha256sum "$DEST/usr/bin/pcdn-detect" | awk '{print $1}')
EOF

log "完成：$(du -sh "$DEST/usr/bin" | cut -f1) 二进制 / $(du -sh "$DEST/usr/share/oxidns/webui" | cut -f1) webui"
