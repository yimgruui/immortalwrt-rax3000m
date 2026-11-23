#
# Web 栈本地包：nginx 的静态配置 + 首启对齐 + 开机自愈。
#
#   /etc/nginx/conf.d/luci-http.conf   ← 80 端口直接提供 LuCI（HTTP，不强制跳 https）
#   /etc/uci-defaults/95-web-stack     ← 关掉 nginx-util 的 80→443 跳转，清掉旧版 nginx_manager 的自启链接
#   /usr/sbin/nginx-guard              ← 开机 25s 后自检；80 不通就修配置 / 重启 nginx
#   /etc/init.d/nginx-guard            ← 上面那个守护的入口
#
# 为什么需要 guard：任何配置错误（包括反代插件写坏 proxy.d）都会让重启后 LuCI 失联，
# 只能靠 U-Boot/SSH 救。这里用“先正常重启、再移除 proxy.d 兜底”的顺序保证 80 能回来。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=web-stack-files
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=yimgruui

include $(INCLUDE_DIR)/package.mk

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/web-stack-files
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=nginx 静态配置与 LuCI 自愈守护
  DEPENDS:=+nginx-mod-luci
  PKGARCH:=all
endef

define Package/web-stack-files/description
 为 LuCI 提供 80 端口 HTTP 服务（不强制跳 https），并在开机后自检 nginx，
 配置损坏时移除反代插件生成的站点、重启 nginx，避免重启后进不去管理界面。
endef

define Package/web-stack-files/install
	$(INSTALL_DIR) $(1)/etc/nginx/conf.d
	$(INSTALL_CONF) $(CURDIR)/files/etc/nginx/conf.d/luci-http.conf $(1)/etc/nginx/conf.d/luci-http.conf
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(CURDIR)/files/etc/uci-defaults/95-web-stack $(1)/etc/uci-defaults/95-web-stack
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(CURDIR)/files/usr/sbin/nginx-guard $(1)/usr/sbin/nginx-guard
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/etc/init.d/nginx-guard $(1)/etc/init.d/nginx-guard
endef

$(eval $(call BuildPackage,web-stack-files))
