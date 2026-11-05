# RAX3000M 固件构建流水线

单变体、声明式、每周跟随上游自动构建：一份特性清单 → 一次构建 → 一个 `sysupgrade.itb`。
配套机型为中国移动 **RAX3000M（NAND 版）**，基座为 `immortalwrt-mt798x-rebase`（MT7981 私有 WiFi + HNAT/WARP）。

> 旧流水线（四套 `.config`、`diy-rax3000m.sh`、`nginx.sh`、`nikki.sh`、`patch/`、旧 workflow）已删除，
> 需要查看时用 `git log --diff-filter=D -- '*config*'` 或回到删除前的提交。设计取舍见文末「为什么弃用旧方案」。

## 目录

| 路径 | 作用 |
| --- | --- |
| [`targets/rax3000m-nand.conf`](../targets/rax3000m-nand.conf) | 机型、基座仓库/分支、体积上限（不固定 commit） |
| [`features/series`](../features/series) | 特性层顺序（后写覆盖先写） |
| [`features/*.configfrag`](../features) | 分层配置片段：`00-base` / `10-mtwifi` / `20-proxy` / `30-dns` / `40-ops` / `90-lab` |
| [`locks/external.lock`](../locks/external.lock) | 三个外部包的 repo + commit（这些钉死） |
| [`locks/cores.lock`](../locks/cores.lock) | 预置内核（oxidns / pcdn-detect）版本与可选 SHA256 |
| `packages/local/rax3000m-files/` | 自维护包：预置二进制、两份运行时配置、uci-defaults |
| [`patches/series`](../patches/series) | 补丁清单（当前为空） |
| [`scripts/genconfig.py`](../scripts/genconfig.py) | 片段 → `.config` + 期望包清单 |
| [`scripts/verify.py`](../scripts/verify.py) | 构建前查 `.config`、构建后查镜像与 manifest |
| [`scripts/prepare.sh`](../scripts/prepare.sh) | 基座/feeds/外部包/本地包/补丁 |
| [`scripts/fetch-cores.sh`](../scripts/fetch-cores.sh) | 下载并校验预置内核 |
| [`scripts/build.sh`](../scripts/build.sh) | 本地一键构建（与 CI 同流程） |

## 构建节奏

- **每周六 02:00（CST）**自动构建，取基座分支当时的 HEAD 编译一次并发布；
- 上游改动导致失败时，**当周不发版**，Release 里仍保留上一版可刷；
- 也可以手动 `workflow_dispatch`：
  - `base_commit` 填某个历史 SHA → 复现那一次构建；
  - `clean_build` 勾上 → 不复用 `dl/` 下载缓存，用于排查“缓存里是坏包”。

## 自动化一览

| 工作流 | 触发 | 作用 |
| --- | --- | --- |
| `build.yml` | 每周六 02:00 CST / 手动 / 改构建定义 | 跟随基座 HEAD 编译、校验、发版（保留 5 个 Release） |
| `bump-external.yml` | **每天** 11:00 CST / 手动 | 检查外部包与预置内核上游，有更新则开 PR（不自动合并） |
| `cleanup.yml` | **每天** 12:00 CST / 手动 | 删除已移除工作流的遗留 run；每个工作流只留最近 10 次 |

清理逻辑在 [`tools/prune-runs.sh`](../tools/prune-runs.sh)：正在运行/排队的 run 一律不碰，只删 `completed`。
删 run 会连带删掉它的 artifact 和日志，所以 `build` 的日志留档只有最近 10 次。

> `locks/` 下的两个锁文件**不在** `build.yml` 的 `push.paths` 里：升级外部依赖的 PR 合并后不会立刻排队构建，
> 而是等周六定时构建生效；要马上出固件就手动 `gh workflow run build.yml`。
> 包源码（`packages/local/**`）、特性片段、补丁、脚本的改动仍然会触发构建。

## 改配置

**加/删软件包**：编辑 `features/<层>.configfrag`，写入 `CONFIG_PACKAGE_xxx=y`。
不要手改 `openwrt/.config`（每次构建都会被重生成）；仓库里也没有 `.config` 这份文件。

改了片段后，`verify.py check-config` 会确认每个 `=y` 的包都真的进了 `.config`——
`make defconfig` 对不存在的包是**静默丢弃**的，这一步就是防“构建成功但功能没进去”。

**换基座**：只改 `targets/rax3000m-nand.conf` 的 `UPSTREAM_REPO` / `UPSTREAM_BRANCH`，
不需要维护 commit 钉值。

**升级外部包/内核**：改 `locks/external.lock`、`locks/cores.lock` 里的版本或 commit。
这三个 LuCI 应用与两个内核属于“外部依赖”，仍然钉死——它们不像基座那样每周都该动。

## 外部依赖升级（三个 LuCI 包 + 两个预置内核）

这三个包**钉 commit**（只有基座跟随 HEAD），所以“要最新版”是显式动作，不是自动漂移。三条路：

1. **自动（推荐）**：`bump-external` 工作流每天 11:00（CST）检查上游，
   有新提交就改 `locks/external.lock` 并开 PR，**不自动合并**。
   合并前先验证这个分支能编过：

   ```bash
   gh workflow run build.yml --ref chore/bump-external
   ```

2. **本地一键**：

   ```bash
   bash tools/bump-external.sh --dry-run   # 先看有哪些新版本
   bash tools/bump-external.sh             # 改 lock，并生成 build-artifacts/bump-report.md
   git commit -am "chore: bump external packages" && git push
   ```

3. **临时尝鲜某个 commit**：直接改 `locks/external.lock` 里对应的 `PKG_n_COMMIT` 再推。

> 升级外部包可能带来新依赖或要求更新的基座；PR 的构建红了就先别合。
> 不要图省事把 `prepare.sh` 改成“永远拉分支 HEAD”——那样每周产物不可复现，出问题无法定位到具体版本。

**内核也走同一套**：oxidns / pcdn-detect 的版本与 SHA256 在 `locks/cores.lock`，
同一个脚本/工作流每天检查上游 release 并一起 bump。版本变化时会**重新下载并重算 SHA256**，
所以上游换掉同名资源会立刻让构建失败，而不是悄悄打进一个不同的二进制；SHA 为空时也会自动补齐。

## 本地构建

```bash
bash scripts/build.sh                 # 完整构建（首次约 2~4 小时，需 ≥25G 空间）
bash scripts/build.sh --skip-download # 依赖已在 dl/ 里时跳过下载
bash scripts/build.sh --commit <sha>  # 复现某次构建
```

本机为 Arch Linux，需要：`base-devel clang flex bison gawk ncurses openssl python
rsync unzip zlib libelf wget`。产物在 `dist/`。

## 预置内核（刷完即用）

`luci-app-oxidns` 与 `luci-app-pcdn-detector` 本身只是“壳”：内核要在页面上点安装、从 GitHub 下载。
国内设备侧基本连不上，所以本流水线在**构建期**把内核打进镜像：

| 组件 | 版本/形态 | 落地路径 |
| --- | --- | --- |
| oxidns | `1.6.1` **standard**（aarch64-musl，4.9MB 包） | `/usr/bin/oxidns` + `/usr/share/oxidns/webui/` |
| pcdn-detect | `v0.0.1-beta.2` **C 版**（0.38MB） | `/usr/bin/pcdn-detect` |

- oxidns 用 `standard` 而非 `full`：lite 配置只用 11 个插件（cron / download / reload_provider /
  adguard_rule / black_hole / metrics_collector / cache / forward / sequence / udp_server / tcp_server），
  standard 全部包含，且已用该二进制跑过 `oxidns check` 通过。
- 建议在 `locks/cores.lock` 里填上 SHA256：留空只记录，填上则上游换文件会立刻失败。
- 升级：改 `cores.lock` → 构建 → 包内 `/etc/uci-defaults/99-rax3000m-files` 会把 UCI 的
  `core_bundle`、`build_variant`、`repo` 对齐；UI 里的“升级内核”仍然可用，`download_proxy`
  已预置 `ghfast.top` 作为备用通道。

## oxidns 与 pcdn 的配置

两份运行时配置是**版本控制 + 打包进镜像**的（不是刷完再手工拷）：

- `/etc/oxidns/config.yaml`（conffile）：lite 方案——只做广告拦截（REFUSED）+ 单缓存 + 阿里 DoH 主用/火山 UDP 兜底
- `/etc/pcdn-detect/pcdn-detect.toml`（conffile）：检测 + nftables 自动封禁 + UPnP 拦截

pcdn 调参（相对上游默认值）：

| 参数 | 默认 | 本项目 | 原因 |
| --- | --- | --- | --- |
| `detect.threshold` | 20 | 30 | 20 个对端/60s 在 BT、多设备 4K 并发时易误判 |
| `detect.window` | 60s | 120s | 同上，降误报 |
| `capture.num_blocks` | 4 | 8 | 千兆满速少丢包，只多 256KB 内存 |
| `memory.peer_limit` / `max_ports` | 隐式 | 1000 / 512 | 写死避免上游默认值漂移 |
| `firewall.nftables.ban_ttl` | 30m | 1h | 减少“封了又解”的抖动 |
| `[upnp]` | 关闭 | `mode="device"` | 阻止 PCDN 自行打洞 |
| `[full_ban]` | 关闭 | 保持关闭 | 先观察一周误封情况再决定 |

> 阈值没有“通用最优”：先跑一周 `log.level="warn"` 观察是否误封自己的设备，
> 把下载机/NAS 的 MAC 加进 `[[filter.whitelist]]`，再决定是否收紧。

## 登录背景与品牌

argon 主题的登录背景由包内 `/usr/share/rax3000m/bg1.jpg` 提供，首次启动时
`/etc/uci-defaults/99-rax3000m-bg` 覆盖到 `/www/luci-static/argon/img/bg1.jpg`
（squashfs → overlay copy-up，重启后保留）。换图只需替换包内那张 jpg 再升级固件，
不需要改 feeds 里的主题源码。


## 可追溯（跟随 HEAD 的前提下）

不再固定 commit，改为**每次构建记录**：

- `build-manifest.json` 写入本次实际使用的基座 SHA、特性层、内核版本、完整包列表、镜像 SHA256；
- Release notes 顶部就是 `repo @ 短 SHA`，出问题能一眼对上是哪份代码；
- 想重来一遍：手动 dispatch，把 `base_commit` 填成 manifest 里的 SHA。

缓存只做一层：`openwrt/dl`（源码包下载），key 带内容哈希 + `restore-keys` 前缀。
**刻意不缓存 `staging_dir`/`ccache`**：基座每周 rebase 后，陈旧工具链与 target staging 是
“编译过了但行为诡异”的经典来源，而每周只跑一次的构建没必要为省几十分钟冒这个险。
哪天觉得慢，再单独加“只缓存 toolchain 目录 + 每周轮换 key”的方案。

## 刷机

- 仅适用于 **NAND 版**（`cmcc_rax3000m`）。eMMC 版（`cmcc_rax3000m-emmc`）刷入会变砖。
- 默认地址 `192.168.11.1`，**无默认密码**（首次登录请立刻设密码）。
- Release 里含 `sysupgrade.itb` 与 `recovery.itb`；`sha256sums` 用于校验。
- 回滚：保留上一个 Release 的 `sysupgrade.itb`；必要时走 recovery。

## 排障

| 现象 | 原因/处理 |
| --- | --- |
| `check-config` 报“必需包缺失” | 外部包没 clone 成功，或包名在上游变了 |
| `checkout 失败` | 外部包 commit 被删 → 更新 `locks/external.lock` |
| `base_commit` 取不到 | 该 SHA 已被上游 rebase 清理，换最近一次成功的 SHA |
| `磁盘不足` | runner 空间不足 25G；清理步骤失效时换 `ubuntu-24.04` 或扩大清理范围 |
| 下载失败 | 在仓库 Variables 里设 `GITHUB_MIRROR=https://ghfast.top` |
| 编译中途失败 | 下载 `build-log` 工件；没有“失败重试一次”的掩盖逻辑 |
| 怀疑缓存坏包 | 手动触发时勾 `clean_build` |

## 为什么弃用旧方案

1. **四份手抄 `.config`**：彼此漂移，CI 只认其中一份，另外三份是死代码。
2. **静默丢失**：外部包克隆失败时 `make defconfig` 直接丢包，构建仍然绿。
3. **死补丁**：`sh/nginx.sh` 被注释后，`patch/` 下 13 个补丁和 rust/nginx 那套替换全部无效，但目录还在。
4. **配置靠手拷**：`oxidns.config` / `pcdn-detector.config` 在 CI 里零引用，刷完是空功能。
5. **缓存互相踩**：两个工作流共用一个不可变 key，还要靠 `gh cache delete` 硬删。
6. **两套脚本漂移**：CI 跑一套、本地没法复用，改错一个 `sed` 只能等下周构建才知道。

新方案逐条对应：片段生成 + 断言、补丁失败即停、配置随包安装、单一构建脚本、全程记录 SHA。
