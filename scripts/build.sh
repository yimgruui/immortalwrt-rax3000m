#!/usr/bin/env bash
# 本地一键构建（与 CI 走完全相同的步骤，避免两套逻辑漂移）。
# 默认跟随上游分支 HEAD；传 --commit 可复现某次构建。
#
#   scripts/build.sh                  # 完整构建
#   scripts/build.sh --skip-download  # 依赖已下过，省时间
#   scripts/build.sh --commit <sha>   # 复现历史构建
#   scripts/build.sh --jobs 8
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/openwrt"
JOBS="$(nproc 2>/dev/null || echo 4)"
COMMIT=""
SKIP_DOWNLOAD=0

usage() {
	cat <<'EOF'
用法: build.sh [--work <dir>] [--commit <sha>] [--jobs N] [--skip-download]
EOF
}

log() { printf '\n==> %s\n' "$*"; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--work) WORK="$2"; shift 2 ;;
		--commit) COMMIT="$2"; shift 2 ;;
		--jobs) JOBS="$2"; shift 2 ;;
		--skip-download) SKIP_DOWNLOAD=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "未知参数: $1" ;;
	esac
done

for cmd in git make python3 rsync curl; do
	command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
done

# shellcheck disable=SC1091
source "$ROOT/targets/rax3000m-nand.conf"

if [ -z "$COMMIT" ]; then
	for i in 1 2 3; do
		COMMIT="$(git ls-remote "$UPSTREAM_REPO" "refs/heads/$UPSTREAM_BRANCH" | awk '{print $1}' || true)"
		[ -n "$COMMIT" ] && break
		echo "第 $i 次获取 HEAD 失败，5s 后重试" >&2
		sleep 5
	done
	[ -n "$COMMIT" ] || die "拿不到 $UPSTREAM_REPO 的 $UPSTREAM_BRANCH HEAD"
fi

log "下载预置内核"
bash "$ROOT/scripts/fetch-cores.sh"

log "下载 geo 数据"
bash "$ROOT/scripts/fetch-geodata.sh"

log "准备源码"
bash "$ROOT/scripts/prepare.sh" --work "$WORK" --commit "$COMMIT"

log "生成 .config"
mkdir -p "$ROOT/build-artifacts"
python3 "$ROOT/scripts/genconfig.py" \
	--target "$ROOT/targets/rax3000m-nand.conf" \
	--series "$ROOT/features/series" \
	--features-dir "$ROOT/features" \
	--out "$WORK/.config" \
	--expected "$ROOT/build-artifacts/expected-packages.txt"

log "make defconfig + 一致性校验"
(cd "$WORK" && make defconfig)
python3 "$ROOT/scripts/verify.py" check-config \
	--config "$WORK/.config" \
	--expected "$ROOT/build-artifacts/expected-packages.txt"

if [ "$SKIP_DOWNLOAD" -eq 0 ]; then
	log "make download -j$JOBS"
	(cd "$WORK" && make download -j"$JOBS")
fi

log "make -j$JOBS（首次编译约 2~4 小时）"
(cd "$WORK" && make -j"$JOBS")

log "校验产物"
python3 "$ROOT/scripts/verify.py" check-image \
	--bin "$WORK/bin/targets/mediatek/filogic" \
	--expected "$ROOT/build-artifacts/expected-packages.txt" \
	--dist "$ROOT/dist" \
	--variant full \
	--commit "$COMMIT" \
	--upstream-repo "$UPSTREAM_REPO" \
	--upstream-branch "$UPSTREAM_BRANCH" \
	--features "$(grep -v '^#' "$ROOT/features/series" | grep -v '^$' | paste -sd, -)"

log "完成：$ROOT/dist"
