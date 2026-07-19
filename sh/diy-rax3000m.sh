#!/bin/bash


# 移除 SNAPSHOT 标签
sed -i 's,-SNAPSHOT,,g' include/version.mk
sed -i 's,-SNAPSHOT,,g' package/base-files/image-config.in
sed -i '/CONFIG_BUILDBOT/d' include/feeds.mk
sed -i 's/;)\s*\\/; \\/' include/feeds.mk

# 修改openwrt登陆地址,把下面的192.168.11.1修改成你想要的就可以了
sed -i 's/192.168.1.1/192.168.11.1/g' package/base-files/files/bin/config_generate


# 修改 argon 为默认主题,可根据你喜欢的修改成其他的（不选择那些会自动改变为默认主题的主题才有效果）
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci-light/Makefile
sed -i 's/default Bootstrap theme/default Argon theme/g' feeds/luci/collections/luci-light/Makefile

mkdir -p package/new

# luci-theme-argon
rm -rf feed/luci/themes/luci-theme-argon
rm -rf feed/luci/applications/luci-app-argon-config
git clone https://github.com/jerrykuku/luci-theme-argon.git package/new/luci-theme-argon
git clone https://github.com/jerrykuku/luci-app-argon-config.git package/new/luci-app-argon-config
rm -rf package/new/luci-theme-argon/htdocs/luci-static/argon/img/bg1.jpg
cp -f $GITHUB_WORKSPACE/bg1.jpg package/new/luci-theme-argon/htdocs/luci-static/argon/img/bg1.jpg


# nikki
git clone https://github.com/nikkinikki-org/OpenWrt-nikki package/new/OpenWrt-nikki
mv package/new/OpenWrt-nikki/*nikki package/new/
mv package/new/OpenWrt-nikki/mihomo* package/new/
rm -rf package/new/OpenWrt-nikki

echo "###"
ls -1 package/new/
