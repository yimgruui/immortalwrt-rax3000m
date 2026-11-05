#!/usr/bin/env bash
# 清理 Actions 历史，避免「All workflows」里堆着已删除工作流的旧 run。
#
#   tools/prune-runs.sh [保留次数]     # 默认 10
#
# 规则：
#   1. workflow 文件已经从 .github/workflows 删掉的 → 其历史 run 全部删除；
#   2. 现存 workflow → 每个只保留最近 N 次「已完成」的 run；
#   3. 正在运行/排队的 run 一律跳过，绝不打断构建。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP="${1:-10}"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

case "$KEEP" in
	''|*[!0-9]*) echo "保留次数必须是整数：$KEEP" >&2; exit 1 ;;
esac

EXISTING="$(basename -a "$ROOT"/.github/workflows/*.yml | sed 's/\.yml$//')"

is_existing() {
	printf '%s\n' "$EXISTING" | grep -qx "$1"
}

delete_run() {
	if gh api -X DELETE "repos/$REPO/actions/runs/$1" >/dev/null 2>&1; then
		echo "    已删除 #$1"
	else
		echo "    删除失败 #$1（可能已在别处删除）" >&2
	fi
}

echo "== 1) 清理已移除工作流的遗留 run"
while IFS=$'\t' read -r id name status; do
	[ -n "${id:-}" ] || continue
	[ "$status" = "completed" ] || continue
	if is_existing "$name"; then continue; fi
	echo "  $name #$id"
	delete_run "$id"
done < <(gh api --paginate "repos/$REPO/actions/runs?per_page=100" \
	--jq '.workflow_runs[] | "\(.id)\t\(.name)\t\(.status)"')

echo "== 2) 现存工作流各保留最近 $KEEP 次"
for wf in "$ROOT"/.github/workflows/*.yml; do
	file="$(basename "$wf")"
	if ! count="$(gh run list --workflow "$file" --limit 100 --json status \
		--jq '[.[] | select(.status == "completed")] | length' 2>/dev/null)"; then
		echo "  $file：远端尚无此工作流（未推送？），跳过"
		continue
	fi
	echo "  $file：已完成 $count 次"
	[ "$count" -gt "$KEEP" ] || continue
	gh run list --workflow "$file" --limit 100 --json databaseId,status \
		--jq '.[] | select(.status == "completed") | .databaseId' \
		| tail -n "+$((KEEP + 1))" \
		| while read -r id; do delete_run "$id"; done
done

echo "== 完成"
