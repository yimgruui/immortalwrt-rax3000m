# RAX3000M 固件构建流水线

单变体、声明式、每周跟随上游自动构建：一份特性清单 → 一次构建 → 一个 `sysupgrade.itb`。
配套机型为中国移动 **RAX3000M（NAND 版）**，基座为 `immortalwrt-mt798x-rebase`（MT7981 私有 WiFi + HNAT/WARP）。

> 旧流水线（四套 `.config`、`diy-rax3000m.sh`、`nginx.sh`、`nikki.sh`、`patch/`、旧 workflow）已删除，
> 需要查看时用 `git log --diff-filter=D -- '*config*'` 或回到删除前的提交。设计取舍见文末「为什么弃用旧方案」。

## 目录

| 路径 | 作用 |
| --- | --- |
| [`targets/rax3000m-nand.conf`](../targets/rax3000m-nand.conf) | 机型、基座仓库/分支/**钉住的 commit**、体积上限 |
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

## 构建节奏（无定时器，按需触发）

`build` **没有 cron**，只在有变化时跑：

| 触发源 | 场景 |
|---|---|
| `bump-external` 自动 dispatch | 基座上游出现新提交（每天 01:00 检查） |
| push 到 `main` | 合并外部依赖/内核的 bump PR（命中 `locks/**`）；改特性片段、本地包、补丁、脚本 |
| 手动 `workflow_dispatch` | 复现某次构建（填 `base_commit`）、或勾 `clean_build` 排查坏缓存 |

上游改动导致构建失败时**不发版**，Release 仍保留上一版可刷。

## 自动化一览

| 工作流 | 触发 | 作用 |
| --- | --- | --- |
| `bump-external.yml` | **每天** 01:00 CST / 手动 | ① 检查基座，有新提交则更新钉值、提交并**自动拉起构建**；② 检查外部包与内核，有更新则开 PR；③ 上次构建失败则补一次重试；④ 清理 Actions 历史 |
| `build.yml` | bump 派发 / push / 手动 | 编译、校验、发版（保留 5 个 Release）；**自身没有定时器** |

清理逻辑在 [`tools/prune-runs.sh`](../tools/prune-runs.sh)：正在运行/排队的 run 一律不碰，只删 `completed`。
删 run 会连带删掉它的 artifact 和日志，所以 `build` 的日志留档只有最近 10 次。

> 重试策略见 [`tools/retry-build.sh`](../tools/retry-build.sh)：只在“最近一次构建失败、且距上次 ≥2 小时、且连续失败不到 2 次”时补发一次，避免每天白跑。
>
> `locks/**` 在 `build.yml` 的 `push.paths` 里，所以**合并 bump PR 就会出固件**——这也是取消定时器后
> 依赖升级仍能被构建的唯一入口。若某次不想构建，提交信息里带 `[skip ci]` 即可。

## 改配置

**加/删软件包**：编辑 `features/<层>.configfrag`，写入 `CONFIG_PACKAGE_xxx=y`。
不要手改 `openwrt/.config`（每次构建都会被重生成）；仓库里也没有 `.config` 这份文件。

改了片段后有两道前置校验：

- `check-config`：片段里每个 `CONFIG_PACKAGE_x=y` 都必须出现在 `.config` 里
  （`make defconfig` 对不存在的包是**静默丢弃**的）；
- `check-coverage`：`packages/local/*` 下有 `Makefile` 的包必须都被启用，
  防“建了包却忘了在片段里打开”——这个盲区曾让首个固件漏掉全部预置内核与配置。

构建后还有 `check-image` 拿 `*.manifest` 反查，确保这些包真的进了镜像。

**换基座**：改 `targets/rax3000m-nand.conf` 的 `UPSTREAM_REPO` / `UPSTREAM_BRANCH`。
`UPSTREAM_COMMIT` 由 `bump-external` 每天自动跟进，一般不用手改；留空则退化为“构建时跟随分支 HEAD”。

**升级外部包/内核**：改 `locks/external.lock`、`locks/cores.lock` 里的版本或 commit。
这三个 LuCI 应用与两个内核属于“外部依赖”，仍然钉死——它们不像基座那样每周都该动。

## 外部依赖升级（三个 LuCI 包 + 两个预置内核）

三个包与两个内核都钉版本；基座钉的是 commit，由同一个工作流每天跟进。三条路：

1. **自动（推荐）**：`bump-external` 工作流每天 01:00（CST）检查上游，
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


## 基座版本与可追溯

基座 commit 钉在 `targets/rax3000m-nand.conf` 的 `UPSTREAM_COMMIT`，由 `bump-external` 每天 01:00 检查：

1. 上游分支有新提交 → 更新钉值 → bot 提交到 `main`；
2. 由于 `GITHUB_TOKEN` 的推送不会触发工作流，脚本随后用 `gh workflow run build.yml` **显式拉起一次构建**；
3. 构建失败则不发版，Release 保留上一版；下次检测会继续跟进更新。

所以“跟随上游”和“可复现”同时成立：仓库里始终有一个明确的基座 SHA，而每次构建的实际 SHA 也写进
`build-manifest.json`（含特性层、内核版本、完整包列表、镜像 SHA256）。想重来一遍：手动 dispatch，
把 `base_commit` 填成 manifest 里的 SHA。

## 缓存策略

两层缓存，都只在构建成功时保存：

| 缓存 | 内容 | key |
|---|---|---|
| `openwrt/dl` | 源码包下载 | 配置内容哈希 + 前缀回退 |
| `openwrt/staging_dir` | **工具链 + 已编译的包** | `owrt-stage-<工具链签名>-<配置哈希>` |

**为什么不用基座 SHA 当 key**：基座是 rebase 分支，上游每次推送都会改写 commit，
即使一个文件没动 SHA 也变了——用 SHA 分桶等于每次自动构建都 miss，缓存形同虚设。

**工具链签名** = `toolchain/` + `include/toolchain.mk` + `rules.mk` 的内容哈希：

- 绝大多数上游提交不动这些文件 → 签名不变 → **复用缓存，只重编变动的包**；
- 工具链真的升级了 → 签名变 → `restore-keys` 也只回退到同签名的旧条目，
  **不会把旧工具链带过来**，该重编就重编。

想要彻底干净的一轮，手动触发时勾 `clean_build`。

> GitHub 每个仓库的缓存上限是 10GB，`staging_dir` 单份约 2~4GB，加上 `dl` 之后接近上限时
> 旧条目会被 LRU 淘汰，属正常现象。

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
| `base_commit` 取不到 | 该 SHA 已被上游 rebase 清理，换 manifest 里最近一次成功的 SHA |
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
