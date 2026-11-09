#!/usr/bin/env bash
# 准备构建环境：基座源码 → feeds → 外部包 → 本地包，最后算出工具链签名供缓存分桶。
# 基座默认用 targets 里钉住的 commit；传 --commit 才按指定 SHA 取（复现历史构建）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/openwrt"
COMMIT=""
SKIP_FEEDS=0

log() { printf '\n==> %s\n' "$*"; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }

# 网络抖动时重试，避免整次构建因为一次 fetch 超时作废
retry() { # retry <次数> <命令...>
	local n="$1" i; shift
	for i in $(seq 1 "$n"); do
		if "$@"; then return 0; fi
		[ "$i" -lt "$n" ] && { echo "    第 $i 次失败，5s 后重试" >&2; sleep 5; }
	done
	return 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		--work) WORK="$2"; shift 2 ;;
		--commit) COMMIT="$2"; shift 2 ;;
		--skip-feeds) SKIP_FEEDS=1; shift ;;
		-h|--help) sed -n '2,6p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) die "未知参数: $1" ;;
	esac
done

# shellcheck disable=SC1091
source "$ROOT/targets/rax3000m-nand.conf"
# shellcheck disable=SC1091
source "$ROOT/locks/external.lock"

mkdir -p "$WORK"
if [ ! -d "$WORK/.git" ]; then
	git -C "$WORK" init -q
	git -C "$WORK" remote add origin "$UPSTREAM_REPO"
fi
git -C "$WORK" remote set-url origin "$UPSTREAM_REPO"

# 优先级：--commit 参数 > targets 钉值 > 分支 HEAD（应急）
COMMIT="${COMMIT:-${UPSTREAM_COMMIT:-}}"

if [ -z "$COMMIT" ]; then
	log "targets 未钉 commit，退化为跟踪 ${UPSTREAM_BRANCH} 当前 HEAD"
	retry 3 git -C "$WORK" fetch -q --depth 1 origin "$UPSTREAM_BRANCH" \
		|| die "拉取分支失败：$UPSTREAM_REPO @ $UPSTREAM_BRANCH"
	COMMIT="$(git -C "$WORK" rev-parse FETCH_HEAD)"
else
	log "基座 commit ${COMMIT:0:12}"
	if ! retry 2 git -C "$WORK" fetch -q --depth 1 origin "$COMMIT"; then
		log "按 SHA 浅取失败，改为完整获取"
		retry 2 git -C "$WORK" fetch -q origin "$UPSTREAM_BRANCH" || die "拉取失败：$UPSTREAM_REPO"
	fi
	git -C "$WORK" cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
		|| die "commit $COMMIT 不可达（可能已被上游 rebase 丢弃）"
fi
git -C "$WORK" checkout -q -f "$COMMIT"
log "基座 $(git -C "$WORK" log -1 --format='%h %ci' "$COMMIT")"

log "上游修正（scripts/fixups.sh）"
bash "$ROOT/scripts/fixups.sh" "$WORK"

if [ "$SKIP_FEEDS" -eq 0 ]; then
	log "feeds update / install"
	(cd "$WORK" && ./scripts/feeds update -a && ./scripts/feeds install -a)
fi

log "外部包（locks/external.lock，钉 commit）"
for i in $(seq 1 "$COUNT"); do
	name="$(eval echo "\$PKG_${i}_NAME")"
	repo="$(eval echo "\$PKG_${i}_REPO")"
	sha="$(eval echo "\$PKG_${i}_COMMIT")"
	dest="$(eval echo "\$PKG_${i}_DEST")"
	[ -n "$name" ] || die "external.lock 第 $i 项缺少 NAME"
	target="$WORK/$dest"
	rm -rf "$target"
	printf '    %-28s %s\n' "$name" "${sha:0:12}"
	retry 3 git clone -q --filter=blob:none --no-checkout "$repo" "$target" \
		|| die "clone 失败: $repo"
	git -C "$target" checkout -q "$sha" \
		|| die "checkout 失败: $name @ $sha（commit 不存在或已被删除）"
done

log "本地包 packages/local"
rm -rf "$WORK/package/local"
mkdir -p "$WORK/package/local"
cp -a "$ROOT/packages/local/." "$WORK/package/local/"

# 工具链签名：只有 toolchain 源码变化才需要重编工具链，缓存据此分桶。
# 用基座 commit 当 key 是不行的——rebase 分支每周都会改写 commit。
# 注意：这里用 if 而不是 `[ -f x ] && echo x`。后者在文件不存在时返回 1，
# 配合 set -o pipefail 会让整条管道失败，脚本直接退出。
sig="$(cd "$WORK" && {
	find toolchain -type f
	if [ -f rules.mk ]; then echo rules.mk; fi
	if [ -f include/toolchain.mk ]; then echo include/toolchain.mk; fi
} | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)"
printf '\n==> 工具链签名: %s\n' "${sig:0:16}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "sig=${sig:0:16}" >> "$GITHUB_OUTPUT"
fi
mkdir -p "$ROOT/build-artifacts"
echo "$sig" > "$ROOT/build-artifacts/toolchain-sig.txt"
echo "$COMMIT" > "$ROOT/build-artifacts/base-commit.txt"
