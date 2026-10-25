#!/bin/bash
# File name: setup-nikki-geoip.sh
# 在 OpenWrt 根目录执行：bash setup-nikki-geoip.sh

set -e

TOPDIR="$(pwd)"
PACKAGE_DIR="${TOPDIR}/package/new"
NIKKI_REPO="https://github.com/nikkinikki-org/OpenWrt-nikki.git"
NIKKI_DIR="${PACKAGE_DIR}/OpenWrt-nikki"
GEOIP_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
# 国内镜像备选（如果 GitHub 直连失败，注释上一行，启用下面一行）
# GEOIP_URL="https://ghfast.top/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"

# ---------- 环境检测 ----------
echo "==> 检测当前目录是否为 OpenWrt 源码根目录"
if [ ! -f "${TOPDIR}/rules.mk" ] || [ ! -d "${TOPDIR}/package" ]; then
    echo "错误：当前目录（${TOPDIR}）不是 OpenWrt 源码根目录" >&2
    echo "      请切换到包含 rules.mk 和 package/ 的目录后重新执行" >&2
    exit 1
fi
echo "    通过：${TOPDIR}"

echo "==> 检测必要命令（git / curl 或 wget）"
command -v git >/dev/null 2>&1 || { echo "错误：未找到 git，请先安装" >&2; exit 1; }
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "错误：未找到 curl 或 wget，请至少安装其一" >&2
    exit 1
fi
echo "    通过"

# ---------- 检测并创建 package/new ----------
echo "==> 检测 package/new 目录"
if [ -d "${PACKAGE_DIR}" ]; then
    echo "    已存在：${PACKAGE_DIR}"
else
    echo "    不存在，正在创建：${PACKAGE_DIR}"
    mkdir -p "${PACKAGE_DIR}"
    if [ ! -d "${PACKAGE_DIR}" ]; then
        echo "错误：package/new 创建失败" >&2
        exit 1
    fi
    echo "    创建成功"
fi

# ---------- 拉取 openwrt-nikki ----------
echo "==> 拉取 openwrt-nikki 到 package/new"
if [ -d "${NIKKI_DIR}/.git" ]; then
    echo "    仓库已存在，跳过克隆：${NIKKI_DIR}"
else
    git clone --depth=1 "${NIKKI_REPO}" "${NIKKI_DIR}"
fi

# ---------- 下载 geoip.metadb ----------
echo "==> 下载 geoip.metadb 到 nikki 包内"
GEOIP_DEST="${NIKKI_DIR}/nikki/geoip.metadb"
if [ -s "${GEOIP_DEST}" ]; then
    echo "    文件已存在，跳过下载：${GEOIP_DEST}"
else
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${GEOIP_URL}" -o "${GEOIP_DEST}"
    else
        wget -qO "${GEOIP_DEST}" "${GEOIP_URL}"
    fi
fi
if [ ! -s "${GEOIP_DEST}" ]; then
    echo "错误：geoip.metadb 下载失败或为空文件" >&2
    exit 1
fi
echo "    已就绪：${GEOIP_DEST}"

# ---------- 修改 nikki/Makefile ----------
echo "==> 修改 nikki/Makefile，将 geoip.metadb 加入 install 段"
MAKEFILE="${NIKKI_DIR}/nikki/Makefile"
if [ ! -f "${MAKEFILE}" ]; then
    echo "错误：未找到 ${MAKEFILE}，请检查仓库结构是否变化" >&2
    exit 1
fi

if grep -q "geoip.metadb" "${MAKEFILE}"; then
    echo "    Makefile 已包含 geoip.metadb 安装指令，跳过修改"
else
    awk '
    /^define Package\/nikki\/install$/ { in_install=1 }
    in_install && /^endef$/ {
        print "\t$(INSTALL_DIR) $(1)/etc/nikki/run"
        print "\t$(INSTALL_DATA) $(CURDIR)/geoip.metadb $(1)/etc/nikki/run/geoip.metadb"
        in_install=0
    }
    { print }
    ' "${MAKEFILE}" > "${MAKEFILE}.tmp" && mv "${MAKEFILE}.tmp" "${MAKEFILE}"
    echo "    Makefile 修改完成"
fi

echo ""
echo "==== 全部完成 ===="
