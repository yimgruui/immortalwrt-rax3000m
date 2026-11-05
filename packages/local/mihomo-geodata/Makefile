# mihomo 规则数据：geoip.metadb + geosite.dat
#
# mihomo 以 `-d /etc/nikki/run` 作为工作目录启动，geo 数据必须放在那里才会被读取。
# nikki 自己只装了 nftables 用的 geoip_cn.nft，不含 mihomo 的 geodata，
# 所以单列一个包：构建期下载、随镜像交付，避免设备端再去 GitHub 拉。
#
# 数据文件不入库（见 .gitignore），由 scripts/fetch-geodata.sh 在构建前准备好。
include $(TOPDIR)/rules.mk

PKG_NAME:=mihomo-geodata
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

define Package/mihomo-geodata
  SECTION:=net
  CATEGORY:=Network
  TITLE:=mihomo geo 规则数据（geoip.metadb / geosite.dat）
  DEPENDS:=+nikki
  PKGARCH:=all
endef

define Package/mihomo-geodata/description
 为 mihomo（nikki 内核）预置 GeoIP 与 GeoSite 规则数据，避免运行期从 GitHub 下载。
endef

define Package/mihomo-geodata/install
	@[ -s "$(CURDIR)/files/etc/nikki/run/geoip.metadb" ] || { \
		echo "错误：缺少 geoip.metadb，请先执行 scripts/fetch-geodata.sh" >&2; exit 1; }
	@[ -s "$(CURDIR)/files/etc/nikki/run/geosite.dat" ] || { \
		echo "错误：缺少 geosite.dat，请先执行 scripts/fetch-geodata.sh" >&2; exit 1; }
	$(INSTALL_DIR) $(1)/etc/nikki/run
	$(INSTALL_DATA) $(CURDIR)/files/etc/nikki/run/geoip.metadb $(1)/etc/nikki/run/geoip.metadb
	$(INSTALL_DATA) $(CURDIR)/files/etc/nikki/run/geosite.dat $(1)/etc/nikki/run/geosite.dat
endef

$(eval $(call BuildPackage,mihomo-geodata))
