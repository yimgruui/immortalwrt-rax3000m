#!/usr/bin/env bash
# 把 packages/external.lock 里的钉值更新到各仓库“默认分支的最新 commit”。
#
#   tools/bump-external.sh --dry-run   # 只看有什么新版本，不改文件
#   tools/bump-external.sh             # 改 lock，并生成 build-artifacts/bump-report.md
#
# 设计取舍：不直接把 prepare.sh 改成“永远拉分支 HEAD”，因为那样每周产物不可复现；
# 这里只负责把“最新”变成一个新的、可 review 的钉值。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/packages/external.lock"
REPORT="$ROOT/build-artifacts/bump-report.md"
DRY_RUN=0

usage() {
	cat <<'EOF'
用法: bump-external.sh [--dry-run]

  --dry-run   只检查并打印，不修改 lock 文件
EOF
}

die() { printf '::error::%s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "未知参数: $1" ;;
	esac
done

command -v gh >/dev/null 2>&1 || die "需要 gh CLI（或改用 GitHub API + curl）"

# shellcheck disable=SC1090
source "$LOCK"

mkdir -p "$(dirname "$REPORT")"
{
	echo "## 外部包升级"
	echo
	echo "| 包 | 旧 | 新 | 上游提交时间 |"
	echo "| --- | --- | --- | --- |"
} > "$REPORT"

changed=0
for i in $(seq 1 "$COUNT"); do
	name="$(eval echo "\$PKG_${i}_NAME")"
	repo="$(eval echo "\$PKG_${i}_REPO")"
	cur="$(eval echo "\$PKG_${i}_COMMIT")"
	slug="${repo#https://github.com/}"
	slug="${slug%.git}"

	branch="$(gh api "repos/$slug" --jq .default_branch)"
	read -r latest date < <(gh api "repos/$slug/commits/$branch" --jq '.sha + " " + .commit.committer.date')

	if [ "$latest" = "$cur" ]; then
		printf '  %-28s 已最新 %s\n' "$name" "${cur:0:8}"
		continue
	fi

	printf '  %-28s %s → %s (%s)\n' "$name" "${cur:0:8}" "${latest:0:8}" "$date"
	echo "| $name | \`${cur:0:8}\` | \`${latest:0:8}\` | $date |" >> "$REPORT"
	changed=1

	if [ "$DRY_RUN" -eq 0 ]; then
		sed -i "s|^PKG_${i}_COMMIT=.*|PKG_${i}_COMMIT=$latest|" "$LOCK"
	fi
done

if [ "$changed" -eq 0 ]; then
	echo "全部已是最新，无需改动。" | tee -a "$REPORT"
else
	{
		echo
		echo "验证方式："
		echo
		echo '```bash'
		echo "gh workflow run build.yml --ref chore/bump-external"
		echo '```'
	} >> "$REPORT"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "changed=$changed" >> "$GITHUB_OUTPUT"
fi

[ "$DRY_RUN" -eq 1 ] && echo "（dry-run：lock 未修改）"
exit 0
