#
# 预置文件包：把两个“只有壳、内核靠联网下载”的 LuCI 应用补成开箱可用。
#
#   /usr/bin/oxidns + /usr/share/oxidns/webui   ← oxidns standard 内核（构建期下载）
#   /usr/bin/pcdn-detect                        ← pcdn-detect C 版（构建期下载）
#   /etc/oxidns/config.yaml                     ← lite 配置（conffile）
#   /etc/pcdn-detect/pcdn-detect.toml           ← 调优后的检测配置（conffile）
#   /etc/uci-defaults/99-rax3000m-files         ← 首次启动对齐 UCI（bundle/版本/时区/启用）
#   /usr/share/rax3000m/bg1.jpg + 99-rax3000m-bg ← 首次启动替换 argon 登录背景
#
include $(TOPDIR)/rules.mk

PKG_NAME:=rax3000m-files
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=yimgruui

include $(INCLUDE_DIR)/package.mk

# 纯文件包（没有源码）：显式定义 Prepare/Compile，避免落到默认的
# “make -C $(PKG_BUILD_DIR)” 上——空目录里没有 Makefile，会以难以定位的方式失败。
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/rax3000m-files
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=RAX3000M 预置内核与配置（oxidns / pcdn-detector）
  DEPENDS:=+luci-app-oxidns +luci-app-pcdn-detector
  PKGARCH:=all
endef

define Package/rax3000m-files/description
 为 RAX3000M 固件预置 oxidns（standard）与 pcdn-detect（C 版）内核，
 以及两份运行时配置，使刷机后无需在设备上访问 GitHub 安装内核。
endef

define Package/rax3000m-files/conffiles
/etc/oxidns/config.yaml
/etc/pcdn-detect/pcdn-detect.toml
endef

define Package/rax3000m-files/install
	@[ -x "$(CURDIR)/files/usr/bin/oxidns" ] || { \
		echo "错误：缺少 oxidns 内核，请先执行 scripts/fetch-cores.sh" >&2; exit 1; }
	@[ -x "$(CURDIR)/files/usr/bin/pcdn-detect" ] || { \
		echo "错误：缺少 pcdn-detect 内核，请先执行 scripts/fetch-cores.sh" >&2; exit 1; }
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(CURDIR)/files/usr/bin/oxidns $(1)/usr/bin/oxidns
	$(INSTALL_BIN) $(CURDIR)/files/usr/bin/pcdn-detect $(1)/usr/bin/pcdn-detect
	$(INSTALL_DIR) $(1)/usr/share/oxidns
	$(CP) $(CURDIR)/files/usr/share/oxidns/webui $(1)/usr/share/oxidns/
	$(INSTALL_DATA) $(CURDIR)/files/usr/share/oxidns/LICENSE $(1)/usr/share/oxidns/LICENSE
	$(INSTALL_DIR) $(1)/etc/oxidns
	$(INSTALL_CONF) $(CURDIR)/files/etc/oxidns/config.yaml $(1)/etc/oxidns/config.yaml
	$(INSTALL_DIR) $(1)/etc/pcdn-detect
	$(INSTALL_CONF) $(CURDIR)/files/etc/pcdn-detect/pcdn-detect.toml $(1)/etc/pcdn-detect/pcdn-detect.toml
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(CURDIR)/files/etc/uci-defaults/99-rax3000m-files $(1)/etc/uci-defaults/99-rax3000m-files
	$(INSTALL_BIN) $(CURDIR)/files/etc/uci-defaults/99-rax3000m-bg $(1)/etc/uci-defaults/99-rax3000m-bg
	$(INSTALL_DIR) $(1)/usr/share/rax3000m
	$(INSTALL_DATA) $(CURDIR)/files/usr/share/rax3000m/bg1.jpg $(1)/usr/share/rax3000m/bg1.jpg
endef

$(eval $(call BuildPackage,rax3000m-files))
