#!/usr/bin/env bash
# 准备构建环境：基座源码 → feeds → 外部包（钉 commit） → 本地包 → 补丁。
# 基座默认跟随上游分支 HEAD；传 --commit 才按指定 SHA 取（用于复现历史构建）。
# 任何一步失败都立即中止，不留下“看起来成功但少东西”的中间状态。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/openwrt"
COMMIT=""
SKIP_FEEDS=0

usage() {
	cat <<'EOF'
用法: prepare.sh [--work <openwrt 目录>] [--commit <sha>] [--skip-feeds]

  --work         源码目录，默认 <repo>/openwrt
  --commit       指定基座 commit（留空 = 跟随 UPSTREAM_BRANCH 当前 HEAD）
  --skip-feeds   跳过 feeds update/install（仅本地反复调试时用）
EOF
}

log() { printf '\n==> %s\n' "$*"; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }

# 网络抖动时重试，避免整周构建因为一次 fetch 超时作废
retry() { # retry <次数> <命令...>
	local n="$1"; shift
	local i
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
		-h|--help) usage; exit 0 ;;
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

# 优先级：--commit 参数 > targets 里钉住的 UPSTREAM_COMMIT > 分支 HEAD（应急）
COMMIT="${COMMIT:-${UPSTREAM_COMMIT:-}}"

if [ -z "$COMMIT" ]; then
	log "targets 未钉 commit，退化为跟踪 ${UPSTREAM_BRANCH} 当前 HEAD"
	retry 3 git -C "$WORK" fetch -q --depth 1 origin "$UPSTREAM_BRANCH" \
		|| die "拉取分支失败：$UPSTREAM_REPO @ $UPSTREAM_BRANCH"
	COMMIT="$(git -C "$WORK" rev-parse FETCH_HEAD)"
else
	log "指定基座 commit ${COMMIT:0:12}"
	if ! retry 2 git -C "$WORK" fetch -q --depth 1 origin "$COMMIT"; then
		log "按 SHA 浅取失败，改为完整获取"
		retry 2 git -C "$WORK" fetch -q origin "$UPSTREAM_BRANCH" \
			|| die "拉取失败：$UPSTREAM_REPO"
	fi
	git -C "$WORK" cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
		|| die "commit $COMMIT 不可达（可能已被上游 rebase 丢弃）"
fi
git -C "$WORK" checkout -q -f "$COMMIT"

log "基座 $(git -C "$WORK" log -1 --format='%h %ci' "$COMMIT")"
mkdir -p "$ROOT/build-artifacts"
echo "$COMMIT" > "$ROOT/build-artifacts/base-commit.txt"

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

log "补丁（patches/series）"
applied=0
while IFS= read -r line; do
	case "$line" in ''|'#'*) continue ;; esac
	patch_path="$ROOT/patches/$line"
	[ -f "$patch_path" ] || die "补丁不存在: patches/$line"
	git -C "$WORK" apply --3way --whitespace=nowarn "$patch_path" \
		|| die "补丁应用失败: patches/$line"
	printf '    %s\n' "$line"
	applied=$((applied + 1))
done < "$ROOT/patches/series"
[ "$applied" -gt 0 ] || echo "    （无补丁）"

printf '\n==> 准备完成：%s\n' "$WORK"
