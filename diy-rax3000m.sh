#!/bin/bash

## 移除 SNAPSHOT 标签
sed -i 's,SNAPSHOT,,g' include/version.mk
sed -i 's,-SNAPSHOT,,g' package/base-files/image-config.in

## 修改openwrt登陆地址,把下面的192.168.11.1修改成你想要的就可以了
sed -i 's/192.168.1.1/192.168.11.1/g' package/base-files/files/bin/config_generate

# rm -rf package/new
mkdir -p package/new

## 下载主题luci-theme-argon
# git clone https://github.com/jerrykuku/luci-theme-argon.git package/new/luci-theme-argon
# git clone https://github.com/jerrykuku/luci-app-argon-config.git package/new/luci-app-argon-config
## 替换主题 bootstrap 为 argon
# sed -i 's/luci-theme-bootstrap/luci-theme-argon/' ./feeds/luci/collections/luci-light/Makefile
## 修改argon背景图片
rm -rf feeds/luci/themes/luci-theme-argon/htdocs/luci-static/argon/img/bg1.jpg
cp -f $GITHUB_WORKSPACE/bg1.jpg feeds/luci/themes/luci-theme-argon/htdocs/luci-static/argon/img/bg1.jpg

## 下载主题luci-theme-aurora
git clone https://github.com/eamonxg/luci-theme-aurora package/new/luci-theme-aurora
git clone https://github.com/eamonxg/luci-app-aurora-config package/new/luci-app-aurora-config
## 替换主题 bootstrap 为 aurora
# sed -i 's/luci-theme-bootstrap/luci-theme-aurora/' ./feeds/luci/collections/luci-light/Makefile

## Add luci-app-wechatpush
rm -rf feeds/luci/applications/luci-app-wechatpush
git clone --depth=1 https://github.com/tty228/luci-app-wechatpush package/new/luci-app-wechatpush

## Add luci-app-adguardhome
git clone https://github.com/Xiaokailnol/luci-app-adguardhome package/new/adguardhome
mv package/new/adguardhome/luci-app-adguardhome package/new/luci-app-adguardhome
rm -rf package/new/adguardhome

####################################
## clone kiddin9/openwrt-packages仓库
git clone https://github.com/kiddin9/kwrt-packages package/new/openwrt-packages

## Add luci-app-ddns-go
rm -rf feeds/luci/applications/luci-app-ddns-go
rm -rf feeds/packages/net/ddns-go
mv package/new/openwrt-packages/ddns-go package/new/ddns-go
mv package/new/openwrt-packages/luci-app-ddns-go package/new/luci-app-ddns-go

## Add luci-app-accesscontrol
mv package/new/openwrt-packages/luci-app-accesscontrol package/new/luci-app-accesscontrol

## Add luci-app-autoreboot
# mv package/new/openwrt-packages/luci-app-autoreboot package/new/luci-app-autoreboot

## Add luci-app-fileassistant
rm -rf feeds/luci/applications/luci-app-fileassistant
mv package/new/openwrt-packages/luci-app-fileassistant package/new/luci-app-fileassistant

## Add luci-app-wolplus
# mv package/new/openwrt-packages/luci-app-wolplus package/new/luci-app-wolplus

## Add luci-app-upnp
rm -rf feeds/luci/applications/luci-app-upnp
rm -rf feeds/packages/net/miniupnpd
mv package/new/openwrt-packages/miniupnpd package/new/miniupnpd
mv package/new/openwrt-packages/luci-app-upnp package/new/luci-app-upnp

rm -rf package/new/openwrt-packages
#################################

## openclash
# rm -rf feeds/luci/applications/luci-app-openclash
# bash $GITHUB_WORKSPACE/scripts/openclash.sh arm64

## Add luci-app-nikki
bash $GITHUB_WORKSPACE/scripts/nikki.sh

## zsh
bash $GITHUB_WORKSPACE/scripts/zsh.sh

## turboacc
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh && bash add_turboacc.sh --no-sfe
# curl -sSL https://raw.githubusercontent.com/mufeng05/turboacc/main/add_turboacc.sh -o add_turboacc.sh && bash add_turboacc.sh

ls -1 package/new/
