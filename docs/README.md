# RAX3000M 固件构建

声明式配置 → GitHub Actions 构建 → 单一固件。
机型：中国移动 **RAX3000M NAND 版**（MT7981B，128MB flash / 256MB RAM）。
基座：`chasey-dev/immortalwrt-mt798x-rebase` 的 `25.12`（MT7981 私有 WiFi 驱动 + HNAT/WARP 加速）。

> eMMC 版（`cmcc_rax3000m-emmc`）不能刷，会变砖。

## 日常

**不用定时构建**：没人改动、上游也没更新时就不编译。

| 触发 | 说明 |
|---|---|
| `bump-external` 每天 01:00 | 检查依赖与基座，有更新就提交并派发一次构建 |
| push 到 `main` | 改特性片段、本地包、锁文件、脚本 |
| 手动 | `gh workflow run build.yml` |

```bash
gh workflow run build.yml                          # 立即构建
gh workflow run build.yml -f base_commit=<sha>     # 复现某次构建
gh workflow run build.yml -f clean_build=true      # 不用缓存
gh workflow run bump-external.yml -f dry_run=true  # 只看有没有新版本
```

产物永远是**一个 Release**（只保留最新）：`sysupgrade.itb`、`recovery.itb`、
`sha256sums`、`build-manifest.json`。默认地址 `192.168.11.1`，无密码。

## 目录

| 路径 | 作用 |
|---|---|
| [`targets/rax3000m-nand.conf`](../targets/rax3000m-nand.conf) | 机型、基座仓库/分支、钉住的 commit、体积上限 |
| [`features/series`](../features/series) | 特性层顺序（后写覆盖先写） |
| [`features/*.configfrag`](../features) | 分层配置片段，标准 `.config` 语法 |
| [`locks/external.lock`](../locks/external.lock) | 三个 LuCI 包的 repo + commit |
| [`locks/cores.lock`](../locks/cores.lock) | 预置资源：oxidns / pcdn-detect 版本 + geo 数据地址 |
| `packages/local/` | 自维护包：预置内核、运行时配置、uci-defaults、登录背景 |
| [`scripts/genconfig.py`](../scripts/genconfig.py) | 片段 → `.config` + 期望包清单 |
| [`scripts/verify.py`](../scripts/verify.py) | 构建前后三道校验 + 生成发布物 |
| [`scripts/prepare.sh`](../scripts/prepare.sh) | 基座/feeds/外部包/本地包 + 工具链签名 |
| [`scripts/fixups.sh`](../scripts/fixups.sh) | 针对上游的本地修正（幂等，上游修好后自动变空操作） |
| [`scripts/fetch-assets.sh`](../scripts/fetch-assets.sh) | 下载预置资源（内核 + geo 数据） |
| `tools/` | 日常维护脚本（bump / prune / retry） |

## 改配置

加包就改片段，别改 `openwrt/.config`（每次构建都会重新生成，仓库里也没有这份文件）：

```bash
# features/20-proxy.configfrag
CONFIG_PACKAGE_luci-app-openclash=y
```

构建时有三道闸：

1. `check-config`：片段里写的每个 `CONFIG_PACKAGE_x=y` 必须真的出现在 `.config` 里
   （`make defconfig` 对不存在的包是静默丢弃的）；
2. `check-coverage`：`packages/local/*` 下有 `Makefile` 的包必须都被启用；
3. `check-image`：构建后拿 `*.manifest` 反查，非库包缺失直接判失败。

## 依赖与基座更新

`bump-external` 每天 01:00 依次做：

1. 外部包（3 个 LuCI 包）/ 内核（2 个）/ geo 数据有更新 → 改 `locks/*.lock` → 提交；
2. 基座有新提交 → 改 `targets/` 的 `UPSTREAM_COMMIT` → 提交；
3. 上面任一发生 → `gh workflow run build.yml`，**一次构建同时包含新插件与新基座**。

顺序是刻意的：依赖提交在基座之前，避免"基座先构建、插件后更新"导致固件里还是旧插件。
依赖更新失败时不会发版，Release 保留上一版，次日继续跟进。

## 上游修正（fixups）

上游偶尔会引入与我们配置冲突的依赖，这类问题不适合每次手动改：
[`scripts/fixups.sh`](../scripts/fixups.sh) 在每次 checkout 之后跑一遍，用最小的 sed 修掉，并且**幂等**——
上游自己修好后，脚本里的判断自动失效，不会重复改。

当前只有一条：

| 修正 | 原因 |
|---|---|
| `hnat-detect` 的 `+ip-tiny` → `+ip-full` | 新基座给 hnat-detect 声明了 `ip-tiny`，而 nikki/mihomo 需要 `ip-full`；两者都提供 `ip` 且互斥，apk 在打包阶段直接报 "unable to select packages" |

修正累积到 3 条以上就该换成正式的 patch 流程，而不是继续堆 sed。

## 缓存

只缓存**工具链与 host 工具**（`staging_dir/toolchain-*`、`host`、`hostpkg`），
key = `owrt-tc-<工具链签名>-<配置哈希>`，只在构建成功时保存。

- 签名的定义是 `toolchain/` + `rules.mk` + `include/toolchain.mk` 的内容哈希：
  同一签名意味着工具链内容完全一致，复用绝对安全；签名变了就全新编译。
- 恢复后会 `touch` 一遍普通文件——解压出的 mtime 早于新 clone 的源码，不刷新会被判过期。
- **不缓存 target 包**：一旦命中就会跳过错过的包，等于把旧包打进新固件。
- 不缓存 `dl/`：key 固定、永远不更新，占配额却命中率越来越低。

## 排障

| 现象 | 处理 |
|---|---|
| `check-config` 报缺包 | 包名在上游变了，或外部包没克隆成功 → 更新 `locks/external.lock` |
| `check-coverage` 报未启用 | `packages/local/` 里新建了包但忘了在片段里 `=y` |
| 构建失败 | 下载 `failure-debug` 工件（`build.log`、`logs/**`、产物） |
| 疑似缓存导致行为异常 | 手动触发时勾 `clean_build` |
| `base_commit` 取不到 | 该 SHA 已被上游 rebase 清理，用 `build-manifest.json` 里最近的可用 SHA |
