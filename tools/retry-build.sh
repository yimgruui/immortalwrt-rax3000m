#!/usr/bin/env bash
# 构建失败后的兜底重试：bump 每天跑一次，如果最近一次 build 失败了，就再派发一次。
#
#   tools/retry-build.sh [--max 2] [--min-age 2] [--dry-run]
#
# 规则（不需要额外状态文件，全部从 Actions 历史推断）：
#   1. 有 build 正在运行/排队 → 什么都不做（避免叠加）；
#   2. 最近一次 build 不是失败 → 什么都不做；
#   3. 连续失败已达 --max 次 → 停止重试，等人处理（避免每天白跑 1.5 小时）；
#   4. 距离上次失败不足 --min-age 小时 → 跳过（手动触发 bump 时防止连点）；
#   5. 否则 dispatch 一次 build。
set -euo pipefail

MAX_FAIL=2
MIN_AGE_H=2
DRY_RUN=0

usage() {
	cat <<'EOF'
用法: retry-build.sh [--max N] [--min-age H] [--dry-run]

  --max N      连续失败达到 N 次就停止重试（默认 2：失败一次 → 重试一次 → 再失败就等人）
  --min-age H  距上次 build 至少 H 小时才重试（默认 2）
  --dry-run    只打印判断结果，不派发
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--max) MAX_FAIL="$2"; shift 2 ;;
		--min-age) MIN_AGE_H="$2"; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "未知参数: $1" >&2; exit 1 ;;
	esac
done

skip() { echo "retry: $*"; exit 0; }

# 1) 有在跑的就不动
in_flight="$(gh run list --workflow build.yml --limit 10 \
	--json status --jq '[.[] | select(.status != "completed")] | length')"
[ "$in_flight" -eq 0 ] || skip "有 $in_flight 个构建正在运行/排队，跳过"

# 2/3) 最近一次结果 + 连续失败次数
mapfile -t conclusions < <(gh run list --workflow build.yml --limit 5 \
	--json conclusion --jq '.[].conclusion')
[ "${#conclusions[@]}" -gt 0 ] || skip "还没有任何构建记录"

latest="${conclusions[0]}"
[ "$latest" = "failure" ] || skip "最近一次构建结论是 ${latest:-未知}，无需重试"

streak=0
for c in "${conclusions[@]}"; do
	[ "$c" = "failure" ] || break
	streak=$((streak + 1))
done
[ "$streak" -lt "$MAX_FAIL" ] || skip "已连续失败 $streak 次（上限 $MAX_FAIL），停止重试，等待人工处理"

# 4) 冷却时间
last_at="$(gh run list --workflow build.yml --limit 1 --json createdAt --jq '.[0].createdAt')"
last_epoch="$(date -d "$last_at" +%s)"
now_epoch="$(date -u +%s)"
age_h=$(( (now_epoch - last_epoch) / 3600 ))
[ "$age_h" -ge "$MIN_AGE_H" ] || skip "距上次构建仅 ${age_h}h（< ${MIN_AGE_H}h），跳过"

# 5) 派发
if [ "$DRY_RUN" -eq 1 ]; then
	echo "retry: [dry-run] 会派发 build（连续失败 $streak 次，距上次 ${age_h}h）"
	exit 0
fi
echo "retry: 派发 build（连续失败 $streak 次，距上次 ${age_h}h）"
gh workflow run build.yml --ref main
