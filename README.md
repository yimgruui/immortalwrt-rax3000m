# ImmortalWrt 固件构建仓库

[![build](https://github.com/yimgruui/immortalwrt-rax3000m/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/yimgruui/immortalwrt-rax3000m/actions/workflows/build.yml)
[![release](https://img.shields.io/github/v/release/yimgruui/immortalwrt-rax3000m?label=release)](https://github.com/yimgruui/immortalwrt-rax3000m/releases)

一套模板构建多台设备：设备模板 + 特性片段 → GitHub Actions → 每台设备独立固件。

```bash
git clone https://github.com/yimgruui/immortalwrt-rax3000m.git
```

当前设备：中国移动 **RAX3000M NAND 版**（MT7981B，128MB flash / 256MB RAM）。
基座 [`chasey-dev/immortalwrt-mt798x-rebase`](https://github.com/chasey-dev/immortalwrt-mt798x-rebase) `25.12`（MT7981 私有 WiFi 驱动 + HNAT/WARP 加速）。

> eMMC 版（`cmcc_rax3000m-emmc`）不能刷，会变砖。

## 特性

| 项 | 说明 |
|---|---|
| Web 服务 | nginx（不是 uhttpd），80 → 443 强制跳转，LuCI 走 https |
| 反向代理 | `luci-app-nginx-proxy`：域名/端口 → 内网服务，支持 TLS、WebSocket、Basic Auth、放行 WAN |
| DNS / 去广告 | nikki（mihomo）保持默认 fake-ip，`category-ads-all` + `adblock` 规则 REJECT |
| SSH | 不预置任何全局公钥；每台设备现场生成专属密钥（`luci-app-device-key`） |
| 预置二进制 | pcdn-detect、geoip/geosite，均钉版本 + SHA256，开箱可用 |
| 语言 | 简体 / 繁体中文随 LuCI 自动切换 |
| 产物 | sysupgrade / recovery 镜像 + sha256sums + build-manifest.json + release-notes.md |

## 目录

```
devices/<id>/device.conf   机型、基座、三元组、产物目录、体积上限
devices/<id>/series        该设备的特性片段顺序
features/*.configfrag      跨设备共享的配置片段（标准 .config 语法）
packages/local/            自维护包（pcdn 预置、nginx 静态配置、反代、设备密钥页、主题）
scripts/                   genconfig / prepare / patch-feeds / fixups / fetch-assets / verify
locks/                     external.lock（外部包 commit） + cores.lock（二进制版本 / SHA256）
tools/                     bump-external / retry-build / prune-runs
```

设计约束：

- 设备相关的一切都在 `devices/<id>/`，加设备 = 加一个目录；
- 仓库不存 `.config`，每次由 `scripts/genconfig.py` 从片段合成；
- 外部包与二进制全部钉 commit / 版本 + SHA256，构建可复现。

## 加一台设备

```bash
mkdir -p devices/my-router
cp devices/rax3000m-nand/device.conf devices/my-router/
cp devices/rax3000m-nand/series      devices/my-router/
# 改 DEVICE_TARGET / DEVICE_SUBTARGET / DEVICE_PROFILE / BIN_DIR / UPSTREAM_* / SIZE_MAX_MB
```

不用改 workflow：`plan` job 用 `scripts/devices.py --matrix` 扫描 `devices/*/device.conf`，
每台设备一个独立 build job、独立缓存、独立产物。

> 预置二进制目前只有 aarch64 资产（`pcdn-detect`）。换 armv7 / mips 设备时，要在
> `scripts/fetch-assets.sh` 里按 `DEVICE_ARCH` 选 release 资产，并同步 `locks/cores.lock` 的 SHA256。

## 构建与发布

```bash
gh workflow run build.yml                          # 全部设备
gh workflow run build.yml -f device=rax3000m-nand  # 单设备
gh workflow run build.yml -f base_commit=<sha>     # 复现历史构建
gh workflow run build.yml -f clean_build=true      # 不用缓存
```

- 改动命中 `devices/**`、`features/**`、`packages/**`、`locks/**`、`scripts/**`、workflow 时自动构建；
- 只有 `main` 分支会创建 Release（每设备保留最新 3 个），其他分支只上传 artifact；
- `bump-external` 每天 01:00 检查上游包与基座，有更新就提交并派发构建。

产物（artifact `firmware-<device>`）包含两个镜像与 `sha256sums`、`build-manifest.json`、
`release-notes.md`。默认管理地址 `192.168.11.1`。

## Web 栈

- `scripts/patch-feeds.sh` 在 `feeds install` 之后把 `feeds/luci/collections/luci-light/Makefile`
  的 `+uhttpd` 换成 `+nginx-mod-luci`（并删 `+uhttpd-mod-ubus`），改完带断言：上游结构一变就构建失败，
  不会悄悄把 uhttpd 装回来。
- `nginx-mod-luci` 自动选中 `nginx-ssl`，并拉入 `uwsgi` / `uwsgi-luci-support` / `nginx-mod-ubus`。
- **80 一律 301 跳到 https**：由 `packages/local/web-stack-files` 的
  `/etc/nginx/conf.d/luci-http.conf` 提供（`return 301 https://$host$request_uri;`）。
  想改回 80 直连就把这行换成 `include /etc/nginx/conf.d/luci.locations;`。
- 443 保留 nginx-util 的自签 server（浏览器首次会提示证书不受信）；要正式证书用 acme
  （`/etc/ssl/acme/*.crt`），或在反代插件里上传证书后给站点勾选 TLS。

### 反向代理（luci-app-nginx-proxy）

菜单：**服务 → Nginx Reverse Proxy**。

- 每条规则 = 域名 / 监听端口 → 内网 `host:port`，可选 TLS、WebSocket、Basic Auth、是否放行 WAN
  （自动写 `firewall.npxy_<port>`）；
- 只写 `/etc/nginx/conf.d/proxy.d/*.conf`，不碰 `uci.conf` / `luci.locations`，改坏也只影响反代；
- 应用时先渲染到临时目录，`nginx -t -c /etc/nginx/uci.conf` 通过才替换，失败自动回滚上一版；
- 保存即应用，列表里的勾选框可直接启用/停用；「查看配置」可看生成的 `.conf`；
- 「额外指令」可逐行插入 `location` 的 nginx 指令（如 qBittorrent 需要的
  `proxy_cookie_path  /  "/; Secure";`），保存前校验、写错由 `nginx -t` 拦下并回滚。

### 开机自愈

`/etc/init.d/nginx-guard` 在启动 25s 后探测 `http://127.0.0.1/`：没响应先重启 nginx；
配置语法坏了则清空 `conf.d/proxy.d`（必要时恢复 `/etc/nginx-proxy/last-good`）再重启，
保证 LuCI 不被反代配置拖死。

## DNS 与去广告

DNS 与去广告都由 nikki 承担，**镜像不修改 nikki 的任何设置**：

```
客户端 → :53（nft 劫持到 1053）→ mihomo(fake-ip) → DIRECT / 代理
                                         └─ category-ads-all / adblock → REJECT
```

- 换上传的配置文件即可在「纯拦截（`MATCH,DIRECT`）」与「带节点」之间切换；
- 广告在连接层被 REJECT，IPv4 / IPv6 都拦；
- dnsmasq 仍负责 DHCP 与 `.lan` 本地域名，客户端查询先被 nft 劫持到 mihomo。

**IPv6 提示**：fake-ip 默认只回 IPv4 假地址、AAAA 回空，表现是「设备有 IPv6 地址但域名解析不到 v6」。
需要时自己打开 IPv6 假地址段：

```sh
uci set nikki.mixin.fake_ip6_range='fc00::/18'
uci commit nikki && /etc/init.d/nikki restart
```

之后 AAAA 返回 `fc00::x`，连接照旧进 tproxy 按规则走。

## SSH

镜像不预置任何公钥，dropbear 在 2222 端口，首次用 root 密码登录。

每台设备用 **系统 → 管理权 → 设备 SSH 密钥** 生成自己的密钥：

1. 「生成新密钥对」→ 输入 root 密码，路由器本地 `ssh-keygen` 生成 ed25519；
2. 「显示一次私钥」→ 再输一次 root 密码，页面显示私钥，**同时设备上的私钥被删除**；
3. 保存到本地 `chmod 600`，按页面给出的命令登录（`ssh -i id_ed25519 [-p 端口] root@<IP>`）。

安全边界：

- 不自动生成，必须人工触发；私钥只存在 `/tmp/device-key`（tmpfs），领取即删；
- 生成 / 领取 / 吊销 / 改公钥都需要重新验证 root 密码；
- 设备长期只留公钥；本插件写入 `authorized_keys` 的行带 `device-key@` 注释，
  吊销只删这些行，手动粘贴的公钥不受影响；
- 私钥领走就没了；丢了只能重新生成。

确认专属密钥能登录后再考虑关密码：

```sh
uci set dropbear.@dropbear[0].PasswordAuth='off' && uci commit dropbear
```

保留配置升级会带上 `/etc/dropbear/authorized_keys` 与 `/etc/device-key`，密钥不用重新生成；
只有 `sysupgrade -n` 或手动吊销才需要重来。

## 校验（三道闸）

1. `check-config`：片段里的 `CONFIG_PACKAGE_x=y` 必须真出现在 `.config`（`make defconfig` 会静默丢弃不存在的包），
   同时校验设备三元组，并确认 `forbidden-packages.txt` 里的包（如 `uhttpd`）没被依赖拉回来；
2. `check-coverage`：`packages/local/*` 下有 `Makefile` 的包必须都被启用；
3. `check-image`：从设备模板推产物目录与体积上限，用 `*.manifest` 反查必需包、确认禁用包不在，
   生成 `sha256sums` / `build-manifest.json` / `release-notes.md`。

## 上游修正

- `scripts/fixups.sh`：checkout 之后、feeds 之前的 sed 修正（默认 LAN 192.168.1.1→192.168.11.1）；
- `scripts/patch-feeds.sh`：feeds install 之后改 feed 包定义（luci-light 的 uhttpd→nginx-mod-luci、
  删掉官方 SSH-Keys 菜单），每条都带正反断言。

上游修好后这些判断会自动失效，不会重复改。

## 缓存

只缓存工具链与 host 工具（`staging_dir/toolchain-*`、`host`、`hostpkg`），
key = `owrt-tc-<device>-<工具链签名>-<配置哈希>`，只在构建成功时保存。

- 同一签名即工具链完全一致，复用安全；签名变了就全新编译；
- 恢复后 `touch` 普通文件，避免 mtime 早于新 clone 的源码被判过期；
- 不缓存 target 包（会跳过错过的包），不缓存 `dl/`。

## 排障

| 现象 | 处理 |
|---|---|
| `check-config` 报缺包 | 包名在上游变了，或外部包没克隆成功 → 更新 `locks/external.lock` |
| `check-config` 报禁用包被启用 | 有别的包依赖 uhttpd → 找出依赖或加进 `patch-feeds.sh` |
| `luci-light 依赖改写失败` | 上游结构变了，按报错更新 `scripts/patch-feeds.sh` |
| 刷机后 LuCI 打不开 | 先试 `http://<LAN>/`；再看 `logread \| grep nginx-guard` |
| `check-coverage` 报未启用 | 新建了 `packages/local/` 包但忘了在片段里 `=y` |
| 构建失败 | 下载 `failure-<device>` 工件（`build.log`、`logs/**`、产物） |
| 疑似缓存问题 | 手动触发时勾 `clean_build` |
| `base_commit` 取不到 | 该 SHA 已被上游 rebase 清理，用 `build-manifest.json` 里可用的 SHA |

## 许可

构建脚本与本地包以 MIT 发布；各上游组件遵循其自身许可（ImmortalWrt、OpenWrt、LuCI、mihomo 等）。
