#!/usr/bin/env bash
# 在 feeds install 之后改写 feed 里的包定义（fixups.sh 太早，那时 feeds 还不存在）。
#
# 目前只有一条：luci-light 依赖 uhttpd → 改成 nginx-mod-luci。
#   * nginx-mod-luci 经 DEFAULT_VARIANT 选中 nginx-ssl，并拉 uwsgi/ubus 模块；
#   * 保留 luci 元包，只把唯一能把 uhttpd 拽进来的依赖换掉；
#   * 每条改写都带断言：上游改结构时立刻失败，而不是悄悄把 uhttpd 又装回来。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-$ROOT/openwrt}"
MK="$WORK/feeds/luci/collections/luci-light/Makefile"

log() { printf '  %s\n' "$*"; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }

[ -f "$MK" ] || die "找不到 $MK（feeds install 是否成功？）"

if grep -q '^	+uhttpd \\$' "$MK" || grep -q '^	+uhttpd$' "$MK"; then
	log "luci-light: +uhttpd → +nginx-mod-luci"
	sed -i -e 's/^	+uhttpd \\$/	+nginx-mod-luci \\/' -e 's/^	+uhttpd$/	+nginx-mod-luci/' "$MK"
fi

if grep -q '^	+uhttpd-mod-ubus' "$MK"; then
	log "luci-light: 移除 +uhttpd-mod-ubus"
	sed -i '/^	+uhttpd-mod-ubus/d' "$MK"
fi

# 断言：改完必须真的没有 uhttpd，且确实有 nginx-mod-luci
if grep -q 'uhttpd' "$MK"; then
	echo "----- $MK 里仍有 uhttpd 引用：" >&2
	grep -n 'uhttpd' "$MK" >&2
	die "luci-light 依赖改写失败"
fi
if ! grep -qx '	+nginx-mod-luci' "$MK" && ! grep -q '^	+nginx-mod-luci \\$' "$MK"; then
	echo "----- $MK 内容：" >&2
	sed -n '1,40p' "$MK" >&2
	die "luci-light 未出现 +nginx-mod-luci"
fi

log "luci-light 依赖已是 nginx-mod-luci"

# 官方「SSH-Keys」菜单由 luci-app-device-key 取代：菜单项是 luci-mod-system 的
# menu.d JSON 里的纯数据，删掉条目即可（视图文件留着无害）。
MENU="$WORK/feeds/luci/modules/luci-mod-system/root/usr/share/luci/menu.d/luci-mod-system.json"
if [ -f "$MENU" ]; then
	if grep -q '"admin/system/admin/sshkeys"' "$MENU"; then
		log "luci-mod-system: 移除官方 SSH-Keys 菜单（由 luci-app-device-key 取代）"
		python3 - "$MENU" <<'PY'
import json, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
	data = json.load(fh)

data.pop("admin/system/admin/sshkeys", None)

with open(path, "w", encoding="utf-8") as fh:
	fh.write(json.dumps(data, indent="\t", ensure_ascii=False) + "\n")
PY
	fi

	if grep -q '"admin/system/admin/sshkeys"' "$MENU"; then
		die "官方 SSH-Keys 菜单删除失败"
	fi
fi

exit 0
