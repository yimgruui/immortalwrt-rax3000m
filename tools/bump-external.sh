#!/usr/bin/env bash
# 把「钉住的外部依赖」更新到上游最新：
#   1. locks/external.lock —— 三个 LuCI 包的 commit（取各仓库默认分支 HEAD）
#   2. locks/cores.lock    —— 两个预置内核的 release 版本（并重算 SHA256）
#
#   tools/bump-external.sh --dry-run   # 只看有什么新版本，不改文件
#   tools/bump-external.sh             # 改 lock，并生成 build-artifacts/bump-report.md
#
# 设计取舍：不把 prepare.sh / fetch-assets.sh 改成“永远拉最新”，因为那样产物不可复现；
# 这里只负责把“最新”变成一个可 review 的钉值。内核的 SHA256 会在版本变化时重算并写回，
# 这样上游替换同名资源会立刻让构建失败，而不是悄悄打进一个不同的二进制。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTERNAL="$ROOT/locks/external.lock"
CORES="$ROOT/locks/cores.lock"
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

command -v gh >/dev/null 2>&1 || die "需要 gh CLI"

# shellcheck disable=SC1090
source "$EXTERNAL"
# shellcheck disable=SC1090
source "$CORES"

# 优先取“最新正式版”，没有正式版才退回最新（含预发布），避免把 beta 当稳定版推上去
latest_tag() {
	local slug="$1" tag=""
	tag="$(gh api "repos/$slug/releases?per_page=20" \
		--jq '[.[] | select(.draft == false and .prerelease == false)][0].tag_name // empty' 2>/dev/null || true)"
	[ -n "$tag" ] || tag="$(gh api "repos/$slug/releases?per_page=1" \
		--jq '.[0].tag_name // empty' 2>/dev/null || true)"
	printf '%s' "$tag"
}

sha_of_url() {
	local url="$1" tmp sha=""
	[ -n "${GITHUB_MIRROR:-}" ] && url="${GITHUB_MIRROR%/}/$url"
	tmp="$(mktemp)"
	if curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 15 -m 300 -o "$tmp" "$url"; then
		sha="$(sha256sum "$tmp" | awk '{print $1}')"
	else
		echo "    警告：下载失败，SHA256 留空：$url" >&2
	fi
	rm -f "$tmp"
	printf '%s' "$sha"
}

mkdir -p "$(dirname "$REPORT")"
cat > "$REPORT" <<'EOF'
## 外部依赖升级

| 组件 | 类型 | 旧 | 新 | 上游时间 |
| --- | --- | --- | --- | --- |
EOF

changed=0
deps_changed=0

echo "== 1) LuCI 包（钉 commit）"
for i in $(seq 1 "$COUNT"); do
	name="$(eval echo "\$PKG_${i}_NAME")"
	repo="$(eval echo "\$PKG_${i}_REPO")"
	cur="$(eval echo "\$PKG_${i}_COMMIT")"
	slug="${repo#https://github.com/}"
	slug="${slug%.git}"

	branch="$(gh api "repos/$slug" --jq .default_branch)"
	read -r latest date < <(gh api "repos/$slug/commits/$branch" --jq '.sha + " " + .commit.committer.date')

	if [ "$latest" = "$cur" ]; then
		printf '  %-24s 已最新 %s\n' "$name" "${cur:0:8}"
		continue
	fi

	printf '  %-24s %s → %s\n' "$name" "${cur:0:8}" "${latest:0:8}"
	echo "| $name | commit | \`${cur:0:8}\` | \`${latest:0:8}\` | $date |" >> "$REPORT"
	changed=1
	deps_changed=1
	[ "$DRY_RUN" -eq 1 ] || sed -i "s|^PKG_${i}_COMMIT=.*|PKG_${i}_COMMIT=$latest|" "$EXTERNAL"
done

echo "== 2) 预置内核（钉 release 版本 + SHA256）"

# --- oxidns：lock 里存不带 v 的版本号，下载 URL 需要补 v ---
oxi_tag="$(latest_tag svenshi/oxidns)"
if [ -z "$oxi_tag" ]; then
	echo "  oxidns 取不到 release，跳过" >&2
else
	oxi_new="${oxi_tag#v}"
	if [ "$oxi_new" = "$OXIDNS_VERSION" ] && [ -z "${OXIDNS_SHA256:-}" ]; then
		printf '  %-24s 版本未变，补齐 SHA256\n' oxidns
		sha="$(sha_of_url "https://github.com/svenshi/oxidns/releases/download/$oxi_tag/$OXIDNS_ASSET")"
		echo "| oxidns | sha256 | \`(空)\` | \`${sha:0:12}…\` | $oxi_tag |" >> "$REPORT"
		changed=1
		deps_changed=1
		[ "$DRY_RUN" -eq 1 ] || sed -i "s|^OXIDNS_SHA256=.*|OXIDNS_SHA256=$sha|" "$CORES"
	elif [ "$oxi_new" = "$OXIDNS_VERSION" ]; then
		printf '  %-24s 已最新 %s\n' oxidns "$OXIDNS_VERSION"
	else
		printf '  %-24s %s → %s\n' oxidns "$OXIDNS_VERSION" "$oxi_new"
		gh api "repos/svenshi/oxidns/releases/tags/$oxi_tag" --jq '.assets[].name' \
			| grep -qx "$OXIDNS_ASSET" || die "新版本 $oxi_tag 里没有 $OXIDNS_ASSET，检查 assets 命名"
		sha="$(sha_of_url "https://github.com/svenshi/oxidns/releases/download/$oxi_tag/$OXIDNS_ASSET")"
		echo "| oxidns | release | \`$OXIDNS_VERSION\` | \`$oxi_new\` | $oxi_tag |" >> "$REPORT"
		changed=1
		deps_changed=1
		if [ "$DRY_RUN" -eq 0 ]; then
			sed -i "s|^OXIDNS_VERSION=.*|OXIDNS_VERSION=$oxi_new|" "$CORES"
			sed -i "s|^OXIDNS_SHA256=.*|OXIDNS_SHA256=$sha|" "$CORES"
		fi
	fi
fi

# --- pcdn-detect：lock 里存带 v 的 tag ---
pcdn_tag="$(latest_tag "$PCDN_REPO")"
if [ -z "$pcdn_tag" ]; then
	echo "  pcdn-detect 取不到 release，跳过" >&2
else
	if [ "$pcdn_tag" = "$PCDN_VERSION" ] && [ -z "${PCDN_SHA256:-}" ]; then
		printf '  %-24s 版本未变，补齐 SHA256\n' pcdn-detect
		sha="$(sha_of_url "https://github.com/$PCDN_REPO/releases/download/$pcdn_tag/$PCDN_ASSET")"
		echo "| pcdn-detect | sha256 | \`(空)\` | \`${sha:0:12}…\` | $pcdn_tag |" >> "$REPORT"
		changed=1
		deps_changed=1
		[ "$DRY_RUN" -eq 1 ] || sed -i "s|^PCDN_SHA256=.*|PCDN_SHA256=$sha|" "$CORES"
	elif [ "$pcdn_tag" = "$PCDN_VERSION" ]; then
		printf '  %-24s 已最新 %s\n' pcdn-detect "$PCDN_VERSION"
	else
		printf '  %-24s %s → %s\n' pcdn-detect "$PCDN_VERSION" "$pcdn_tag"
		gh api "repos/$PCDN_REPO/releases/tags/$pcdn_tag" --jq '.assets[].name' \
			| grep -qx "$PCDN_ASSET" || die "新版本 $pcdn_tag 里没有 $PCDN_ASSET，检查 assets 命名"
		sha="$(sha_of_url "https://github.com/$PCDN_REPO/releases/download/$pcdn_tag/$PCDN_ASSET")"
		echo "| pcdn-detect | release | \`$PCDN_VERSION\` | \`$pcdn_tag\` | $pcdn_tag |" >> "$REPORT"
		changed=1
		deps_changed=1
		if [ "$DRY_RUN" -eq 0 ]; then
			sed -i "s|^PCDN_VERSION=.*|PCDN_VERSION=$pcdn_tag|" "$CORES"
			sed -i "s|^PCDN_SHA256=.*|PCDN_SHA256=$sha|" "$CORES"
		fi
	fi
fi

echo "== 3) 基座（targets/rax3000m-nand.conf）"
TARGET="$ROOT/targets/rax3000m-nand.conf"
base_repo="$(sed -n 's/^UPSTREAM_REPO=//p' "$TARGET")"
base_branch="$(sed -n 's/^UPSTREAM_BRANCH=//p' "$TARGET")"
base_cur="$(sed -n 's/^UPSTREAM_COMMIT=//p' "$TARGET")"
base_slug="${base_repo#https://github.com/}"
base_slug="${base_slug%.git}"
read -r base_head base_date < <(gh api "repos/$base_slug/commits/$base_branch" --jq '.sha + " " + .commit.committer.date')

base_changed=0
if [ "$base_head" = "$base_cur" ]; then
	printf '  %-24s 已最新 %s\n' "mt798x-rebase" "${base_cur:0:8}"
else
	printf '  %-24s %s → %s\n' "mt798x-rebase" "${base_cur:0:8}" "${base_head:0:8}"
	echo "| 基座 | commit | \`${base_cur:0:8}\` | \`${base_head:0:8}\` | $base_date |" >> "$REPORT"
	changed=1
	base_changed=1
	if [ "$DRY_RUN" -eq 0 ]; then
		sed -i "s|^UPSTREAM_COMMIT=.*|UPSTREAM_COMMIT=$base_head|" "$TARGET"
	fi
fi

if [ "$changed" -eq 0 ]; then
	echo "全部已是最新，无需改动。" | tee -a "$REPORT"
else
	{
		echo
		echo "依赖与基座的更新都会直接提交到 main，然后统一派发一次 build："
		echo
		echo '```bash'
		echo "gh run list --workflow=build.yml --limit 1"
		echo '```'
	} >> "$REPORT"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "changed=$changed" >> "$GITHUB_OUTPUT"
	echo "deps_changed=$deps_changed" >> "$GITHUB_OUTPUT"
	echo "base_changed=$base_changed" >> "$GITHUB_OUTPUT"
	echo "base_sha=$base_head" >> "$GITHUB_OUTPUT"
fi

if [ "$DRY_RUN" -eq 1 ]; then echo "（dry-run：lock 未修改）"; fi
exit 0
