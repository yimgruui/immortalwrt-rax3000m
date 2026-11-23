#
# 预置文件包：把两个“只有壳、内核靠联网下载”的 LuCI 应用补成开箱可用。
#
#   /usr/bin/pcdn-detect                        ← pcdn-detect C 版（构建期下载）
#   /etc/pcdn-detect/pcdn-detect.toml           ← 调优后的检测配置（conffile）
#   /etc/uci-defaults/99-rax3000m-files         ← 首次启动对齐 UCI（pcdn / DNS / 时区）
#   /etc/uci-defaults/96-legacy-ssh-key         ← 删掉旧镜像带过来的全局兜底公钥
#   /www/luci-static/argon/background/rax3000m.jpg ← argon 3.x 登录背景（目录扫描，取唯一图片）
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
  TITLE:=RAX3000M 预置配置（pcdn-detector 默认值）
  DEPENDS:=+luci-app-pcdn-detector
  PKGARCH:=all
endef

define Package/rax3000m-files/description
 为 RAX3000M 固件预置 pcdn-detect（C 版）内核、调优后的 TOML，
 使刷机后无需在设备上手工配置；DNS 与去广告由 nikki 承担。
endef

define Package/rax3000m-files/conffiles
/etc/pcdn-detect/pcdn-detect.toml
endef

define Package/rax3000m-files/install
	@[ -x "$(CURDIR)/files/usr/bin/pcdn-detect" ] || { \
		echo "错误：缺少 pcdn-detect 内核，请先执行 scripts/fetch-assets.sh" >&2; exit 1; }
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(CURDIR)/files/usr/bin/pcdn-detect $(1)/usr/bin/pcdn-detect
	$(INSTALL_DIR) $(1)/etc/pcdn-detect
	$(INSTALL_CONF) $(CURDIR)/files/etc/pcdn-detect/pcdn-detect.toml $(1)/etc/pcdn-detect/pcdn-detect.toml
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(CURDIR)/files/etc/uci-defaults/99-rax3000m-files $(1)/etc/uci-defaults/99-rax3000m-files
	$(INSTALL_BIN) $(CURDIR)/files/etc/uci-defaults/96-legacy-ssh-key $(1)/etc/uci-defaults/96-legacy-ssh-key
	$(INSTALL_DIR) $(1)/www/luci-static/argon/background
	$(INSTALL_DATA) $(CURDIR)/files/www/luci-static/argon/background/rax3000m.jpg $(1)/www/luci-static/argon/background/rax3000m.jpg
endef

$(eval $(call BuildPackage,rax3000m-files))
