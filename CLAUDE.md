# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

Course-Thru（课速通）是仅面向 **Windows** 的「刷网课」浏览器发行版：以 Chromium for Testing 为内核，预置 ScriptCat（脚本猫）扩展 + OCS 网课助手脚本，开箱即用。本仓库即「开放版」（自维护/开源）。

核心链路：Go 启动器（`main.go`）读 `config.json` → 首次启动把 `profile_seed/` 复制为运行时 `profile/` → 以 `--load-extension` 拉起 Chromium。**品牌化和预置数据全部在构建期完成**，运行期启动器只做少量修正（注册表策略、Preferences 时间戳、CDP 关欢迎页）。

## 构建

```powershell
# 一键完整构建：下载组件 → 注入 key → 品牌/logo 替换 → 编译启动器 → 生成 profile_seed → 打包安装版
powershell -ExecutionPolicy Bypass -File build.ps1
# 仅便携版 dist/（不递增版本号）
powershell -ExecutionPolicy Bypass -File build.ps1 -NoNsis
# 复用已有 dist\profile_seed（只改了启动器/扩展、没动 gen-profile 时）
powershell -ExecutionPolicy Bypass -File build.ps1 -SkipProfile
# 手动指定里程碑版本
powershell -ExecutionPolicy Bypass -File build.ps1 -Version 1.1.0
```

产物：`dist/`（便携版，双击 `dist\Course-Thru.exe`）、`dist-installer/Course-Thru-<版本>-Setup.exe`（安装版）。`dist/`、`dist-installer/`、`.tools/`（组件下载缓存）都在 .gitignore 中，不进库。（旧 `Build-Product/` 手工交付目录已删除，交付以 `dist/` + `dist-installer/` 为准。）

**没有自动化测试**，验证循环 = 构建 + 手动启动。完整验证清单：
- 首启**只打开 1 个页面**（内置主页 `course-thru/index.html`），不恢复出生成流程的会话窗口；
- ScriptCat 图标加载 OCS 无报错、开发者模式已开启、userScripts 开关已持久化；
- 任何启动都不出现 `docs.scriptcat.org` 页面（install_comple / changelog / open-dev）；
- 首启后 `dist\first_run.flag` 出现；
- 默认搜索为百度（设置页标注「由扩展控制」）、新标签页直达百度且无任何确认弹窗。
改过 `gen-profile.mjs` 时必须删掉 `dist\profile_seed` 重新生成并端到端验证。

### 版本与组件（固定，保证可复现）

- 版本号单一来源 `version.txt`：完整构建 patch 自动 +1 并写回，`-NoNsis` 复用当前版本。发版后要提交并推送（详见本地 VERSION.md，已被 gitignore）。
- 组件固定在 `build.ps1` 顶部：Chromium 152.0.7977.13、ScriptCat v1.4.0、OCS 4.15.3。第三方许可证原文收录在 `third-party-licenses/`（OCS=MIT、ScriptCat=GPL v3，见该目录 README）。
- **OCS 脚本本地维护**（`extensions/ocs.user.js`，不下载）。升级 OCS：替换 `extensions/ocs.user.js` → 同步 `build.ps1` 顶部 `$OcsTag`（不一致只警告不阻塞）→ **删除 `dist\profile_seed` 重新生成**（OCS 数据写死在 seed 里）。脚本自带官方更新模块，gen-profile 预置时另开 ScriptCat 自动更新（`checkUpdate: true`，双通道）。

## 架构

| 组件 | 作用 |
|---|---|
| `main.go` | Go 启动器（GUI 子系统，无控制台窗口）。读 config.json；首启复制 profile_seed→profile（**copyDir 并发 8 worker + 1MB 缓冲**）并清 `Default/Sessions*`；组装 Chrome 参数（一大串 `--disable-*` 关闭谷歌功能）；写入 CfT 企业策略注册表（**整键一次查询、并行补写**）；修正 `Default/Preferences` 静默扩展接管弹窗（**UseNumber 保留精度**）；首启 `first_run.flag` 立即写入、CDP 关 ScriptCat 欢迎页放后台 goroutine |
| `build.ps1` | 构建流水线（步骤有编号注释）。幂等下载（直连失败自动回退系统代理）、语言裁剪、注入 key、调用各 patch 脚本 |
| `gen-profile.mjs` | CDP 驱动真实 Chromium 生成 `profile_seed`：开开发者模式 + userScripts 开关，把 OCS 直接写入 ScriptCat 的 `chrome.storage.local`（status=1 默认启用），重启后验证。**信号驱动**（DOM 条件等待 + MutationObserver），不固定 sleep |
| `patch-branding.py` | 构建期替换 `locales\*.pak` / `resources.pak` 里的 "Chrome for Testing" 品牌字样与 Google LLC 版权（幂等） |
| `generate-assets.py` / `patch-logo.py` / `patch-icons.py` | 从 `logo/logo.png` 生成全套资产，替换 Chromium pak 内嵌图片与 chrome.exe / chrome.dll / 启动器 PE 图标（幂等） |
| `extensions/baidu-search/` | 内置 MV3 扩展：默认搜索设为百度（chrome_settings_overrides）+ 新标签页跳百度（background.js 监听 chrome://newtab 并导航） |
| `extensions/ocs.user.js` | OCS 脚本（vendor，构建时打包进产物） |
| `course-thru/` | 内置主页（file:// 自包含，资源全相对路径，随程序分发） |
| `installer.iss` | Inno Setup：桌面图标任务**默认勾选**；卸载跑 `stop-browser.ps1` 关进程 + 删 CfT 注册表策略 |
| `keys/scriptcat.key` | 固定扩展 ID 的公钥，**不可删除/重新生成** |
| `third-party-licenses/` | 第三方开源许可证原文（OCS=MIT、ScriptCat=GPL v3），合规保留原作者署名 |

## 关键技术决策（接手人必读）

- **用 Chromium for Testing 而非 Electron**：ScriptCat 依赖 `chrome.userScripts` API，Electron 不支持（只支持 `chrome.scripting` 等子集）。也**不用 Chrome 品牌版**：Chrome 137+ 移除了 `--load-extension`。
- **注入固定 key**：unpacked 扩展无 `key` 时 ID 由安装路径决定，路径一变脚本数据就丢；固定公钥后 ID 恒定，预置数据可随 profile 移植（扩展 ID 由公钥做 SHA-256 取前 16 字节计算，见 gen-profile.mjs）。
- **预置 profile**：userScripts 开关与脚本数据存在扩展的 `chrome.storage.local`（LevelDB），构建时用真实 Chromium 配置好打包为 `profile_seed`，用户首启复制即开箱即用。
- **Inno Setup 而非 NSIS**：NSIS 官方二进制仅托管 SourceForge（国内不可达）。
- **抑制 CfT 测试横幅**：CfT 顶部固定显示「仅适用于自动测试」黄色横幅，靠 `--disable-infobars` 隐藏（CfT 2023-11 起支持）。
- **谷歌功能清理：能用启动参数就绝不用策略**。可关同步/后台联网/组件更新/崩溃上报/翻译/AI 的开关写死在 `main.go`；只有注册表策略能完成的（关登录入口、关后台运行、关安全浏览等 9 条）才走 CfT 策略注册表。升级 Chromium 后需复核这些开关在对应源码中仍存在（不存在的 feature 名会被 Chrome 静默忽略，无副作用）。

## 关键约束（踩过的坑）

- **`--load-extension` 是单值开关**：多个扩展必须逗号合并为一个参数值，重复传只认最后一个。
- **绝不能加 `--disable-extensions-except`**：会触发 Chromium「先禁用全部扩展再重启进程」流程，首启弹「加载扩展程序时候出错」并延迟出窗。
- **`keys/scriptcat.key` 丢失 = 扩展 ID 变化 = 所有既有用户脚本数据失效**。`build.ps1` 会直接 Fail 而不是重新生成密钥对，须用 `git restore` 恢复。私钥 `keys/scriptcat_private.pem` 被 gitignore，构建不依赖。
- **扩展接管弹窗**：不用 `chrome_url_overrides` 接管浏览器设置就不会弹确认框；默认搜索这类简单接管靠预置 `extensions.simple_override_begin_confirmation_timestamp` 未来时间戳静默（见 `main.go` 的 `silentOverrideTimestamp`，Preferences 解析用 `json.Decoder.UseNumber` 保留无关字段大整数精度、目标时间戳以整数原文写入，避免被改写成科学计数法丢精度，比较用 float64）；升级用户需在启动时清理 Preferences 里的 chrome_url_overrides 残留。
- **品牌字样/logo 无法用命令行或策略修改**：编译在 `locales\*.pak`、`chrome_*.pak` 与 PE 资源里，只能构建期替换。patch 脚本全部幂等，升级 Chromium 后构建自动重新打补丁。已知限制：新标签页顶部 Google 字标由二进制内资源动态提供，**无法替换**。
- **CfT 企业策略路径不同于普通 Chrome**（`HKCU\Software\Policies\Google\Chrome for Testing`），因此只影响本程序，不波及用户日常 Chrome；退出不删除，卸载时由 installer 清理。
- **默认搜索用扩展而非策略**：`DefaultSearchProvider*`、`MetricsReportingEnabled`、`SafeBrowsingEnabled` 都是 sensitive 策略，未加入域的机器上会被 Chrome 直接忽略（chrome://policy 显示「错误, 已忽略」）；扩展的 `chrome_settings_overrides` 在 unpacked 扩展上直接生效（设置页标注「由扩展控制」）。UMA 上传改由 `--disable-background-networking` 在网络层关闭。
- **UTF-8 读写**：build.ps1 改 UTF-8 文件（如 service_worker.js、manifest.json、version.txt）必须用 `[IO.File]::ReadAllText/WriteAllText` 显式指定 UTF-8 编码——PS 5.1 的 `Get-Content` 默认按 ANSI/GBK 解码会把中文读成乱码再写回，导致扩展语法损坏。**build.ps1 自身必须保持 UTF-8 BOM**：PS 5.1 读含中文脚本依赖 BOM，去 BOM 会报「Missing ')'」解析错误；编辑后需补回 `EF BB BF` 前缀。
- **语言包裁剪**：Chromium locales 只留 en-US/zh-CN/zh-TW，ScriptCat _locales 只留 en/zh_CN/zh_TW；缺失时浏览器自动回退 en-US、扩展回退 default_locale，不报错。清单在 build.ps1 顶部 `$KeepChromeLocales` / `$KeepExtLocales`。

## 运行时数据流（首次启动）

1. `profile/` 不存在 → 从 `profile_seed/` 复制（copyDir 并发 8 worker + 1MB 缓冲），并删 `Default/Sessions*`（防止恢复出生成流程的窗口；profile_seed 生成时也已清理，三重保险）。
2. 修正 `Default/Preferences`：删 chrome_url_overrides 残留 + 预置简单接管时间戳（UseNumber 保留精度、整数原文写入），先写临时文件再原子替换。
3. 组装参数启动 Chromium；首启额外加 `--remote-debugging-port=0`，从 `DevToolsActivePort` 读端口；`first_run.flag` **立即**写入，CDP 关 ScriptCat 欢迎页放后台 goroutine（纯兜底，构建期已在扩展源码屏蔽）。
4. 写入 9 条 CfT 企业策略（整键一次查询、值缺失或不对才**并行补写**；登录/同步/后台运行/安全浏览上报等）。
5. 启动地址：`defaultUrl` 留空 → 内置主页 `course-thru/index.html`（file://）；相对路径 → 解析为 file:// URL；完整网址 → 原样打开。

## 本地文档（gitignore 不入库，排查/扩展时必读）

HANDOVER.md（完整交接：阶段回顾、机制详解、待办）、VERSION.md（版本递增规则）、OPEN-VERSION-GUIDE.md（扩展接管静默、新标签页直达百度方案）、BRANDING-PATCH.md（品牌字样替换+语言包裁剪）、LOGO-REPLACEMENT.md（logo 全链路替换+验证清单）、CONSOLE-POLICY-NOTES.md（cmd 黑框屏蔽+CfT 策略生命周期）均为**本地维护、不入库**，改完不必推送。仓库入库文档只有 README.md、AGENTS.md，另含 LICENSE（Apache-2.0）与 `third-party-licenses/`（第三方许可证原文）。

## 约定

- 注释与用户可见字符串用**简体中文**，标识符用英文。
- Go：只用标准库、gofmt、导出符号带注释；`Config` 字段对应 camelCase JSON key（`defaultUrl`、`extraArgs`）。
- PowerShell：`$PSScriptRoot` 推导路径（不硬编码）、`$ErrorActionPreference = "Stop"`、`[build]` 前缀日志。
- 提交信息用中文 Conventional Commits + scope，subject ≤50 字（如 `fix(build): 修正 profile_seed 复制路径`），详见 AGENTS.md。
- 严禁提交 `keys/scriptcat_private.pem` 或其他密钥。
