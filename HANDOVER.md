# Course-Thru（课速通）交接文档（更新版）

> 更新时间：2026-08-12（阶段十三修订：CRLF 行尾致 OCS 元数据解析失败故障修复 + 网课平台英文界面修复 + v1.0.19~1.0.22 发版 + .gitattributes 统一行尾；git 状态同步至 44 个提交、version.txt=1.0.22）
> 项目：Course-Thru（课速通）— 基于 Chromium + ScriptCat + OCS 的刷网课浏览器（Windows）
> 阅读顺序：先读 README.md（公共仓库文档）了解使用方式，再读本文了解来龙去脉与当前状态。
> 注意：本文自 **2026-08-12 起已入库**（完整交接文档随仓库维护，`.gitignore` 已移除忽略规则）；`VERSION.md` / `BRANDING-PATCH.md` / `CONSOLE-POLICY-NOTES.md` / `LOGO-REPLACEMENT.md` / `OPEN-VERSION-GUIDE.md` 仍为**本地文档**（gitignore 不入库），见阶段七第 4 条。

---

## 一、项目概述

开箱即用的 Windows 刷网课浏览器。核心思路：**不自己实现刷课逻辑**，而是把成熟的 ScriptCat（脚本猫）扩展和 OCS 网课助手脚本预置进 Chromium，用户打开浏览器即自动加载、自动可用。

只面向 Windows 平台。

---

## 二、阶段工作回顾

### 阶段一：从零搭建（已完成）

1. **技术选型**（关键决策，见第六节）：Electron 不可行 → Chromium for Testing；Chrome 137+ 移除 `--load-extension` → 用开源 Chromium；NSIS 官方源不可达 → 改用 Inno Setup。
2. **核心机制验证**（全部实测跑通）：ScriptCat 免安装加载、注入固定 RSA key 使扩展 ID 恒定、CDP 自动开启 userScripts 开关、正规安装 OCS 脚本、预置 profile 跨目录复制后数据完整。
3. **开发与构建**：Go 启动器、一键构建脚本、CDP profile 生成器、Inno Setup 安装脚本、安装版/便携版双形态。

### 阶段二：微调与收尾（2026-08-05，本轮重点）

1. **新增 AGENTS.md** 贡献者指南（项目结构、构建命令、代码风格、测试、提交约定）。
2. **密钥策略定稿**：公钥入库写死（扩展 ID 恒定），私钥仅本地备份不进仓库；`build.ps1` 改为公钥缺失即报错，防止误删导致 ID 漂移。
3. **修复「每次启动弹出 ScriptCat 安装成功页」**：
   - 根因：unpacked 扩展每次启动都会触发 `onInstalled(reason=install)`，ScriptCat 无条件打开 `docs.scriptcat.org/docs/use/install_comple` 页（已用真实浏览器对照实验证实，与 profile 是否重置无关）。
   - 修复：`build.ps1` 打包时给 `service_worker.js` 打补丁，条件改为恒 false。
   - 兜底：`main.go` 首次启动写 `first_run.flag`，并通过 CDP 自动关闭欢迎页；后续启动不带调试参数，行为与正常浏览器一致。
4. **构建产物流程**：`build.ps1` → `dist/`（便携版）+ `dist-installer/`（安装版）→ 汇总到 `Build-Product/`。
5. **清理记录**：
   - 清理了 `dist\chrome\.tools\profile-tmp` 开发期残留（约 10 MB），并在 `build.ps1` 增加打包前自动清理步骤（7.5 节）。
   - 清除了 `Build-Product\portable\profile` 用户数据（恢复出厂态）。
   - 尝试清除 `.tools/`、`.agents/`、`.claude/`、`skills-lock.json` —— **用户已叫停**，详见第三节「清理动作的实际状态」。
6. **OCS 本地化**：不再从 GitHub Release 下载，`ocs.user.js`（4.15.3）入库为 `extensions/ocs.user.js`，构建时直接复制进产物（`dist\extensions\ocs.user.js`），升级只需替换该文件并核对 `build.ps1` 顶部的 `$OcsTag`。**2026-08-07 刷新**：已重新从 GitHub Release 拉取最新原版（4.15.3）整体替换（哈希与官方发布资产一致、未做改动），此前外部修改（删除更新模块与更新日志入口）随之清除，脚本自带「📥 更新模块」恢复，自动更新能力保留。
7. **gen-profile.mjs 重写**（修时序 + 改架构）：
   - 去掉本地 HTTP 服务器和模拟点击安装：OCS 是 ScriptCat 的油猴脚本，现在**直接写入 ScriptCat 的 `chrome.storage.local`**（`script:<uuid>` 元数据 + `scriptCode:<uuid>` 代码，`status:1` 默认启用）；
   - 全部等待改为**真实信号驱动**（页面端 MutationObserver + 条件等待），不再固定 sleep；
   - **开发者模式**通过 CDP 点击 chrome://extensions 的开关并等待状态生效（写死默认开启，端用户首启不再弹「开启开发者模式」信任提示）；
   - 流程：配置开发者模式 + userScripts 开关 → 注入 OCS（等待落盘）→ 优雅关闭 → 重启验证（管理面板显示 OCS + SW 实测 userScripts 启用）→ 优雅关闭。
8. **build.ps1 编码修复**：manifest 注入与欢迎页补丁改用 UTF-8 显式读写（PS 5.1 的 `Get-Content` 默认 ANSI/GBK，曾把 `service_worker.js` 的中文读成乱码导致扩展加载失败——「加载扩展程序时候出错」的根因）。
9. **build.ps1 全新环境修复**（从零构建时暴露的两个 bug）：
   - **Go SDK 解压 bug**：原 `Unzip $goZip $Tools` 因目标目录已存在而被跳过，全新环境永远解压不出 Go。已改为解压到 `go-unpack` 临时目录再移动到 `.tools\go`。
   - **代理回退**：`curl.exe` 不读系统代理（WinINET），国内代理环境下 GitHub 下载失败。`Download` 函数现在直连失败后自动读取系统代理（注册表）重试，中文语言包同样走该函数。
10. **全链路从零构建验证通过**（2026-08-06）：清空产物与缓存后，build.ps1 重新下载全部组件 → 生成 profile_seed → 打包安装版，端到端实测（扩展加载、OCS 预置启用、开发者模式开启、无欢迎页、无扩展错误）全部通过。
11. **修复「启动弹出 8 个窗口」**（2026-08-06）：根因是种子携带了生成流程的会话恢复数据（`Default\Sessions` / `Sessions_Encrypted`），用户首启时 Chromium 恢复出生成期间打开的 options 页、扩展详情页、脚本猫更新日志/引导页（还有重复）。修复：`gen-profile.mjs` 生成结束时清理会话数据、`build.ps1` 组装种子时兜底清理、`main.go` 首次运行复制种子后同样清理（三重保险）。实测启动只打开 1 个页面（当时为 `about:blank`，阶段七起默认为内置主页）。

### 阶段三：改名上线与首次推送（2026-08-06）

1. **项目改名 Course-Thru（课速通）**：全仓库名称替换（产物 `Course-Thru.exe` / `Course-ThruSetup.exe`、安装目录 `%LOCALAPPDATA%\Course-Thru`、Go 模块 `coursethru/launcher`、`config.json` 的 `appName`、错误弹窗标题、首次运行标记内容），源码与文档零残留旧名；**README 全面重写**。
2. **首次推送 GitHub**：远程 `origin = https://github.com/IceFireIcer/Course-Thru-NBCC.git`，`main` 分支已推送并设置上游跟踪，工作区干净。提交历史：`f0423da` 初始搭建 → `42a45c4` 交接文档 → `df785ab` 改名与重构。
3. **build.ps1 编码约定**：**必须保持 UTF-8 BOM**——PowerShell 5.1 读取含中文的脚本依赖 BOM 才能正确解码；去 BOM 会导致「Missing ')'」解析错误。若用编辑器/补丁工具改完丢失 BOM，需补回（`EF BB BF` 前缀）。
4. **物理文件夹名**：磁盘目录仍为 `browserForLazy`（当前工作区根路径，改名会导致会话失效），未改动；如需要可手动重命名为 `Course-Thru`（不影响 git 内容）。
5. **安装器 AppId**：改名时保留了原 GUID（`F8E1B0C4-...`），保证旧版本升级/卸载路径兼容。

### 阶段四：谷歌功能清理与默认搜索引擎固化（2026-08-07）

1. **启动参数关闭谷歌相关功能**（全部在 M152 = CfT 152.0.7977.13 对应源码中逐项确认存在）：
   - 账号与云服务：`--disable-sync`（同步）、`--disable-background-networking`（后台联网：UMA/安全浏览/翻译/扩展更新）、`--disable-component-update`（组件更新）、`--disable-domain-reliability`（网络错误上报谷歌）、`--disable-crashpad-for-testing`（崩溃上报）、`--disable-default-apps`（谷歌默认应用）；
   - 服务类 feature：`--disable-features=OptimizationHints`（优化指导服务）、`NetworkTimeServiceQuerying`（网络时间服务）、`Translate`（谷歌翻译）；
   - AI 类 feature（M152 源码确认的功能名）：`Compose,PrivateAi,OptimizationGuideModelExecution,OptimizationGuideOnDeviceModel,OnDeviceModelBackgroundDownload,ModelQualityLogging,HistoryEmbeddings,HistoryEmbeddingsAnswers,GoogleSearchAiModeWorkspace,TextSafetyClassifier`。
2. **默认搜索引擎改为百度**：新增 `extensions/baidu-search/`（MV3，`chrome_settings_overrides.search_provider`）。为什么不用策略：`DefaultSearchProvider*` 是 sensitive 策略，未加入域的机器上 Chrome 会直接忽略（已实测：chrome://policy 显示「错误, 已忽略」）。扩展方案实测生效：设置页显示「百度（默认）」并标注由扩展控制。
3. **企业策略关闭谷歌登录/同步/后台运行**（只能走注册表，CDP 与启动参数都无法完成）：`main.go` 新增 `applyCftPolicies()`，启动时逐条查询 `HKCU\Software\Policies\Google\Chrome for Testing`，缺失或值不对才写入；策略**常驻注册表、退出不删除**，卸载时由安装器 `DeleteCftPolicies` 清理（设计定稿见 `CONSOLE-POLICY-NOTES.md`；早期版本曾采用"退出删除并还原旧值"，后取消）。关键发现：CfT 的策略注册表路径是 `...\Google\Chrome for Testing`（通过扫描 chrome.dll 二进制字符串 + 实测双重确认），**与日常 Chrome 的 `...\Google\Chrome` 不同，因此这些策略不影响用户日常使用的 Chrome**。
4. **注册表策略现为 9 条**（全部非 sensitive，未托管机器实测全部「正常」生效）：`BrowserSignin=0`（关登录入口）、`SyncDisabled=1`（关同步）、`BackgroundModeEnabled=0`（关后台运行）、`SafeBrowsingProtectionLevel=0`（关安全浏览，副作用：不拦截恶意网站）、`SafeBrowsingExtendedReportingEnabled=0`、`SafeBrowsingSurveysEnabled=0`、`PasswordLeakDetectionEnabled=0`（密码哈希不再发谷歌）、`SearchSuggestEnabled=0`（搜索建议不再外发）、`NetworkPredictionOptions=2`（关网络预加载）。排除的 sensitive 策略：`MetricsReportingEnabled`、`SafeBrowsingEnabled`、`DefaultSearchProvider*`（写了也被忽略；UMA 上传已由 `--disable-background-networking` 在网络层关闭）。
5. **修复 `--load-extension` 多扩展 bug**：该开关是单值开关，重复传多个时 Chromium 只认最后一个 → 多个扩展必须用逗号合并为一个参数值（`--load-extension=a,b`）。此前只有 ScriptCat 单扩展未暴露，加入百度扩展后脚本猫不再加载，已修复并验证。
6. **端到端验证**（临时目录真实运行 `Course-Thru.exe` 首启全流程）：chrome://policy 9 条策略全部「正常」、默认搜索引擎为百度（扩展控制）、脚本猫 + 百度默认搜索两个扩展均正常加载、所有禁用参数在命令行可见。该次验证对应早期"退出恢复"版本；定稿改为常驻后验证清单见 `CONSOLE-POLICY-NOTES.md` §4（关闭浏览器后策略仍在、卸载后整键删除）。
7. **OCS 恢复上游原版并启用自动更新**（2026-08-07）：`extensions/ocs.user.js` 曾在本会话期间被外部改动（删除 OCS 更新模块与更新日志入口，约 135 行，非本会话所为）。现已从 GitHub Release（`ocsjs/ocsjs` 最新 4.15.3）重新拉取并整体替换为未修改的原版脚本：被删除的「📥 更新模块」与更新日志入口已恢复，功能完整保留；同时 `gen-profile.mjs` 预置 OCS 时开启 ScriptCat 自动更新（`checkUpdate: true`，更新源改为有效的 GitHub 最新 Release 资产 URL），`dist\profile_seed` 已重新生成并验证。
8. **阶段四改动已提交并推送**（2026-08-07 复查确认）：`main.go`、`build.ps1` 修改 + `extensions/baidu-search/` 新增 + `extensions/ocs.user.js` 外部修改，已随提交 `bf66eb6`（关闭谷歌功能并以百度为默认搜索引擎）一并入库并推送 `origin/main`；另有 `61fc0c5`（抑制 CfT 横幅）与 `52efc8b`（交接文档更新）两个提交。本地与远程完全同步，工作区干净。

### 阶段五：版本与日志小功能（2026-08-07）

1. **版本号自动递增**：`version.txt` 单一来源（`x.y.z`），完整构建 patch 自动 +1 并写回、`-NoNsis` 便携调试复用、`-Version` 手动覆盖；安装包文件名与 AppVersion 带版本号，`dist\version.txt` 随产物分发。方案见 `VERSION.md`（提交 `b156b73`）。
2. **严重错误日志自动打包**：启动器新增 `coursethru.log` 滚动日志（2 MB 轮转）；遇到致命错误（找不到 chromium、初始化失败、启动失败等）时自动把日志 + `version.txt` 打包为 zip 存入 `crash-logs\`，并打开文件夹定位 zip，错误弹窗内附 zip 路径，便于微信回传排查。端到端已实测（临时目录触发致命错误 → zip 自动生成，内容正确）。

### 阶段六：OCS 恢复上游原版并启用自动更新（2026-08-07）

1. **重新拉取并整体替换**：从 OCS 官方仓库 `ocsjs/ocsjs` 的 GitHub Release 重新拉取最新脚本 4.15.3（`releases/latest/download/ocs.user.js` 与 tag 资产 SHA-256 一致），整体替换 `extensions/ocs.user.js`（仓库源）、`dist\extensions\ocs.user.js` 与 `Build-Product\portable\extensions\ocs.user.js`（产物副本）。之前外部修改删除的「📥 更新模块」（约 135 行，官方更新源 `cdn.ocsjs.com`）与更新日志入口全部恢复，脚本与上游完全一致、功能完整保留。
2. **开启 ScriptCat 自动更新**：`gen-profile.mjs` 预置 OCS 时把 `checkUpdate: false` 改为 `checkUpdate: true`，并把失效的更新地址（`raw.githubusercontent.com/ocsjs/ocsjs/master/dist/ocs.user.js`，404）替换为稳定有效的 GitHub 最新 Release 资产 URL（`https://github.com/ocsjs/ocsjs/releases/latest/download/ocs.user.js`）。ScriptCat 会定期对比 `@version`，发现新版自动提示；与脚本自带官方更新模块形成双通道自动更新。
3. **重新生成并验证 profile_seed**：用 `gen-profile.mjs` 以真实 Chromium 重新生成 `dist\profile_seed` 并同步 `Build-Product\portable\profile_seed`。验证通过：OCS 4.15.3 写入 ScriptCat 存储且管理面板可见、开发者模式与 userScripts 开关持久化（SW 实测）、无会话恢复数据残留。
4. **构建脚本注释同步**：`build.ps1` 顶部补充自动更新机制说明（脚本自带更新模块 + ScriptCat `checkUpdate`）；`$OcsTag` 仍为 4.15.3，与替换后的脚本一致。
5. **提交状态**：上述改动已随提交 `9ed5660`（恢复上游原版并启用自动更新）入库并推送；`dist\`、`Build-Product\` 为 gitignore 产物，不提交。

### 阶段七：品牌化、内置主页与开放版收尾（2026-08-07 晚间）

1. **构建期品牌字样替换与语言包裁剪**（提交 `8e3ca7e`）：新增 `patch-branding.py`，把 `locales\*.pak` 里的 "Chrome for Testing" / "Google Chrome for Testing" 替换为 "Course-Thru 课速通" / "Course-Thru"（窗口标题模板、新标签页「自定义」按钮、设置「关于」页等），幂等可重复执行，Chromium 解压后由 build.ps1 统一调用。同时裁剪 Chromium `locales\*.pak` 只保留 en-US / zh-CN / zh-TW（含性别变体）、ScriptCat `_locales` 只保留 en / zh_CN / zh_TW，减小发布体积；首选语言缺失时自动回退 en-US / default_locale(en)，不会报错。方案与踩坑记录见本地文档 `BRANDING-PATCH.md`。
2. **CfT 企业策略改常驻 + 屏蔽 cmd 黑框**（提交 `922f7c2`）：`applyCftPolicies()` 相关 `reg.exe` 子进程统一加 `CREATE_NO_WINDOW`（`hideConsole`），启动器不再闪黑框；策略生命周期定为**常驻**（启动时逐条查询、缺失或值不对才写入，退出不删除，卸载由安装器清理），早期"退出恢复"版本废弃。设计与取舍见本地文档 `CONSOLE-POLICY-NOTES.md`。
3. **全链路替换品牌 logo**（提交 `ecfd972`）：新增 `logo/logo.png`（唯一源文件）、`generate-assets.py`（生成 `assets\` 全套：app.ico、安装向导图、pak 内嵌 PNG、ScriptCat 扩展图标）、`patch-logo.py`（内容识别替换 `chrome_*.pak` / `resources.pak` 内产品 logo PNG，幂等）、`patch-icons.py`（重建资源段替换 chrome.exe / chrome.dll / chrome_pwa_launcher.exe / 启动器 PE 图标）；ScriptCat 工具栏图标与 Inno Setup 安装包图标/向导图一并替换。已知限制：NTP 顶部 Google 字标由二进制内资源动态提供，无法替换。方案与验证清单见本地文档 `LOGO-REPLACEMENT.md`。
4. **本地交接/技术文档移出仓库**（提交 `cb7b6d6`）：HANDOVER.md、VERSION.md、BRANDING-PATCH.md、CONSOLE-POLICY-NOTES.md、LOGO-REPLACEMENT.md 不再入库，`.gitignore` 增加忽略规则；仓库文档只保留 README.md 与 AGENTS.md。本地保留完整文档供开发使用（`OPEN-VERSION-GUIDE.md` 随后在 `0d2ecf4` 一并加入忽略）。
5. **关于页版权署名替换 + 默认最大化窗口**（提交 `af57464`）：build.ps1 新增 3.55 步，把 Chromium 自带 `ABOUT` 文件里的 "Copyright 2026 Google LLC. All rights reserved." 幂等替换为 "Copyright 2026 IceFire_Icer. All rights reserved."；`patch-branding.py` 同步把 pak 内 "Google LLC." 替换为 "IceFire_Icer."（只替换带句点的完整公司名，避免误伤其他声明）。main.go 启动参数新增 `--start-maximized`，每次启动都以最大化窗口打开。版本号随该次构建递增至 1.0.9。
6. **内置主页 + 新标签页直达百度**（提交 `0d2ecf4`，开放版）：
   - 新增 `course-thru/` 内置主页（index.html + SmileySans 字体 + GSAP + logo.png，全部相对路径、file:// 自包含、离线可用）；启动器新增 `resolveStartURL()`：`defaultUrl` 留空 → 打开内置主页；相对路径 → 解析为程序目录下 file:// URL；完整网址 → 原样打开。
   - `extensions/baidu-search` 升级 1.1.0：新增 `background.js`，监听新标签页——若为 `chrome://newtab`（或 `chrome://new-tab-page-third-party`）且无 openerTabId（非从链接新开），导航到百度；**不接管浏览器设置**（不用 chrome_url_overrides），因此不弹「更改此网页是您的本意吗？」确认框。从链接/脚本新开的标签页一律不碰。
   - `main.go` 新增 `ensureBaiduQuiet()`：启动前修正 profile 的 `Default/Preferences`——删除旧版 `extensions.chrome_url_overrides` 残留（升级用户必做），并把 `simple_override_begin_confirmation_timestamp` 预置为 2099 年时间戳，让「更改搜索服务提供商是您的本意吗？」不再弹出；先写临时文件再原子替换，失败不阻塞主流程。方案见本地文档 `OPEN-VERSION-GUIDE.md` §2。
   - `installer.iss`：新增安装 `course-thru\` 目录；桌面图标任务去掉 `Flags: unchecked`，缺省即默认勾选，安装完成桌面直接出现快捷方式。
7. **git 状态更新**：阶段七 6 个提交（`8e3ca7e` / `922f7c2` / `ecfd972` / `cb7b6d6` / `af57464` / `0d2ecf4`）已全部推送，HEAD = `0d2ecf4`，合计 11 个提交；`version.txt` = 1.0.9；本地与远程同步、工作区干净。

### 阶段八：注册表/Preferences 修复、首启性能优化与许可证收录（2026-08-08）

1. **README 同步**（提交 `597db33`）：按开放版现状修正 README（与 0d2ecf4 同批的文档收尾）。
2. **修复注册表策略值与 Preferences 精度处理**（提交 `21dcf46`）：
   - `regValueEquals` 把 reg.exe 输出的十六进制值（如 `0x10`）解析为无符号整数后再与目标十进制比较，杜绝多位数十六进制与十进制的字符串误判；
   - `ensureBaiduQuiet` 改用 `json.Decoder.UseNumber` 解析 Preferences：除接管时间戳外还有大量其他超大整数（随机种子、各类时间戳），默认 float64 解析会在写回时丢精度/改写成科学计数法；UseNumber 让无关字段以 json.Number 原文保留、写回逐字节原样输出，目标时间戳以**整数原文**写入（不触发 Marshal 的科学计数法）；
   - 首启 `first_run.flag` **立即写入**（不再等欢迎页清理结果），CDP 关 ScriptCat 欢迎页移入**后台 goroutine**（纯兜底，失败无副作用，不阻塞启动器出窗）；
   - `loadConfig` **强制保留 `extensions/scriptcat`**：用户自定义扩展列表时自动追加 scriptcat（幂等去重），预置 OCS 数据的载体扩展不可能被配置移除；
   - `applyCftPolicies` 改为**整键一次 `reg query`**（不带 /v 列出键下全部值），逐条比对已有值、缺失或值不对才补写，替代原逐条 query（每次启动少 ~8 次 spawn 往返）；
   - `copyDir` 改为**并发复制**：第一遍遍历建目录 + 预计算相对路径，第二遍固定 8 worker 池并发复制文件，任一失败即停并返回首个错误（行为等价旧实现）。profile_seed 约 200 文件 / 14MB、小文件密集，机械硬盘上并发显著缩短首启出窗时间。
3. **首启冷启动再优化**（提交 `61e4d05`）：
   - `copyFile` 用 **1MB 缓冲**替代 `io.Copy` 默认 32KB：4 个大文件占 ~10MB，read/write 系统调用从 ~320 次降到 ~10 次；
   - `applyCftPolicies` 补写策略改为**并行 goroutine**（`addCftPoliciesParallel`）：9 条 `reg add` 写各自独立值名、互不覆盖，可安全并发，首启写策略从 9 次串行往返压缩到约一次往返。
4. **第三方许可证收录**（提交 `f1ead6c`）：
   - 新增 `third-party-licenses/` 目录存放依赖组件的许可证原文：OCS（`ocsjs-LICENSE.txt`，MIT，Copyright (c) 2022 enncy，取 4.15.3 标签）、ScriptCat（`scriptcat-LICENSE.txt`，**GPL v3**，作者 CodFrm，取 v1.4.0 标签）；
   - **注意**：ScriptCat 实为 **GPL v3** 而非 MIT，已按 GitHub 原文如实收录，并在 `third-party-licenses/README.md` 与公共 README 明确标注；以浏览器扩展形式与 Course-Thru 一并分发时需遵守 GPL v3 条款。
5. **git 状态更新**：阶段八 4 个提交（`597db33` / `21dcf46` / `f1ead6c` / `61e4d05`）已全部推送，HEAD = `61e4d05`，合计 **23 个提交**；`version.txt` = 1.0.11；本地与远程同步、工作区干净。

### 阶段九：关闭会话恢复、许可证改 GPL v3 与 v1.0.12 发版（2026-08-09）

1. **关闭会话恢复**（提交 `5de7e34`）：启动器每次启动前清理 `Default/Sessions` / `Sessions_Encrypted`（原仅首次复制种子后清理，现改为每次启动都清），并新增启动参数 `--disable-session-crashed-bubble`（异常退出后不弹「恢复页面？」气泡）。效果：每次打开浏览器都从默认页（内置主页）全新开始，不恢复上次标签页。实测验证通过：多标签页 → 优雅关闭 → 再启动只打开默认页；人为植入伪造会话也被启动前清理。
2. **项目许可证改为 GPL v3**：根目录 `LICENSE` 由 Apache-2.0 全文替换为 GPL v3 全文（674 行标准文本，取自 `third-party-licenses/scriptcat-LICENSE.txt` 同源）。与内置 ScriptCat 扩展（同为 GPL v3）许可证完全兼容，规避混合许可证合规复杂度；README / AGENTS / CLAUDE 三份入库文档同步更新许可证声明。
3. **v1.0.12 发版**：完整构建（`build.ps1`，patch 自动递增 1.0.11→1.0.12）产出便携版 `dist/` + 安装版 `Course-Thru-1.0.12-Setup.exe`；验证清单全过（首启只开 1 页、无欢迎页、first_run.flag、会话不恢复）；提交 `5de7e34` 推送 `origin/main`，tag `v1.0.12` 已创建并推送，GitHub Release「Course-Thru 1.0.12」（Latest）已发布，含 Setup.exe 与 portable.zip 两个资产。
4. **git 状态更新**：阶段九 1 个提交（`5de7e34`）已推送，HEAD = `5de7e34`，合计 **24 个提交**；`version.txt` = 1.0.12；本地与远程同步、工作区干净。

### 阶段十：扩展 ID 固定、主页大改版与 Chrome 152 新标签页修复（2026-08-09 ~ 2026-08-10）

1. **固定百度扩展 ID**（提交 `f7dbdc6`，v1.0.14）：此前只有 ScriptCat 注入固定 key，百度扩展 ID 随安装路径漂移（实测复现不同路径下 ID 变化），导致扩展事件偶发丢失、新标签页跳百度时灵时不灵。生成 `keys/baidu-search.key`（公钥入库）+ `keys/baidu-search_private.pem`（私钥 gitignore，通配规则 `/keys/*_private.pem`），`build.ps1` 注入 key 到百度扩展 manifest（公钥缺失即 Fail）。固定后 ID 恒为 `kjkhdfinhacckmpplnddgcbbpmncmfmk`。
2. **主页大改版**（提交 `cdcd1f0`，v1.0.15）：
   - 网课快捷入口从 6 个增至 **10 个**（学习通/中国大学MOOC/智慧树/雨课堂/学银在线/智慧职教/学堂在线/国家高等教育智慧教育平台/浙江省高等学校在线开放课程管理中心/DeepSeek 在最后）；网格改为横向 10 列铺开，卡片内部用**容器查询单位 `cqw` 自动缩放**（图标/字号/内边距随卡宽缩放），窄屏降级 5 列/3 列；
   - **动态字号策略**（JS `fitNameFontSize`）：名称短的入口单行放大字号（可达 22px），需换行的长名称自动调小（多行上限 18px，最多 3 行完整显示不截断），触发时机为每次渲染后/字体加载完成后/窗口 resize；
   - 右上角新增**版本 pill**（Liquid Glass：毛玻璃 + 斜向扫光动画），构建期由 `build.ps1` 把 `v__VERSION__` 占位符替换为 `version.txt` 实际版本（UTF-8 显式读写），本地直接打开源码显示 `v-dev` 兜底；
   - 左下角新增**反馈按钮**（大号 Liquid Glass 圆角矩形，得意黑 + 亮橙黄），点击跳转飞书反馈表单 `zcnxkzym5740.feishu.cn/share/base/form/shrcnak0wsQxurCqxYbw2WPsJTf`；
   - `LINKS_KEY` 从 v1 升级为 v2，让老用户 localStorage 缓存失效、自动套用新 10 平台列表；
   - 修复移动端 `overflow:hidden` 裁剪问题（改为可滚动 + 短内容垂直居中），修复 `.add-card` 引用 cqw 却未声明 container-type 的 bug。
3. **修复「点击加号新建标签页不跳百度」**（提交 `a714d67`，v1.0.16，用户实测反馈）：
   - **根因**：Chrome 152 起通过 UI（Ctrl+T / 点击加号）新建的标签页 `openerTabId` 非空（指向当前活动标签页），旧版 `background.js` 用 `!tab.openerTabId` 判断「非从链接新开」会**误拦截真实用户操作**，导致点击加号停留在 `chrome://newtab` 不跳百度；
   - **修复**：`background.js` 去掉 openerTabId 判断，**只按 URL 判断**是否新标签页页（`chrome://newtab` / `chrome://new-tab-page-third-party`），从链接/脚本新开的标签地址是具体链接不会误伤；
   - **排查教训**：CDP `Target.createTarget` 创建的标签带 opener 会误判「不跳百度」，之前测试用 SW 内 `chrome.tabs.create` 无 opener 掩盖了真实 UI 场景；最终用**系统级 Ctrl+T 键击**复现用户问题，再注入 SW 实时监听器确证 `openerTabId` 非空。正确复现方法见 `OPEN-VERSION-GUIDE.md` §四第 6 条；
   - `main.go` 的 `loadConfig` 同步强制保留 `extensions/baidu-search`（与 scriptcat 兜底对称），防止旧版 config.json 缺项导致扩展不加载。
4. **构建验证与发布**：v1.0.14 / v1.0.15 / v1.0.16 三次完整构建均通过端到端验证（首启单页、版本注入、扩展 ID 固定、反馈链接正确、真实 Ctrl+T 跳百度、从链接新开不误伤），GitHub Release 均已发布并标记 Latest。
5. **git 状态更新**：阶段十 7 个提交（`f7dbdc6` / `d59a3b8` / `cdcd1f0` / `87a3dd9` / `a714d67` / `d53b45f`，另有 1.0.13 相关 `bdcd046` / `1916982` 等）已全部推送，HEAD = `d53b45f`，合计 **37 个提交**；`version.txt` = 1.0.16；本地与远程同步、工作区干净。

### 阶段十一：主页动画选择器修复与 v1.0.17 构建（2026-08-10）

1. **修复主页版权元素 GSAP 入场动画失效**（提交 `e85d536`）：`course-thru/index.html` 的版权元素 HTML 是类选择器（`<a class="copyright">`，无 `id`），但 GSAP 入场动画（`fromTo`）与 `prefers-reduced-motion` 降级分支里都用了 `#copyright` id 选择器，导致该元素不参与入场动画（无淡入上移动效）。统一改为 `.copyright` 类选择器（桌面/移动两套时间线 + reduce 分支共 4 处）。验证：主页打开后版权元素正常参与入场动画、reduce-motion 下直接显示。
2. **v1.0.17 完整构建**：完整构建（patch 自动递增 1.0.16→1.0.17）产出便携版 `dist/`（version pill 注入 `v1.0.17`）+ 安装版 `dist-installer/Course-Thru-1.0.17-Setup.exe`；**尚未打 tag、未发 Release**（待办见第七节）。
3. **git 状态更新**：阶段十一 1 个提交（`e85d536`）已推送，HEAD = `e85d536`，合计 **38 个提交**；本地与远程同步。`version.txt` = **1.0.17** 与三份入库文档的阶段性同步改动暂存于工作区（未提交），待发版时一并提交。

### 阶段十二：快捷方式中文名与 v1.0.18 发版（2026-08-10）

1. **安装版快捷方式改中文名「课速通」**（提交 `ac15eb5` 之后）：`installer.iss` 的 `[Icons]` 段把开始菜单/桌面快捷方式名称从 `{#MyAppName}`（Course-Thru）改为中文「课速通」，安装完成页「立即启动」按钮文案同步改为「立即启动 课速通」；安装目录/进程名/AppId 均不变（`{app}\Course-Thru.exe`）。
2. **v1.0.18 完整构建与发版**：完整构建（patch 自动递增 1.0.17→1.0.18）产出便携版 `dist/`（version pill 注入 `v1.0.18`）+ 安装版 `dist-installer/Course-Thru-1.0.18-Setup.exe`；tag `v1.0.18` + GitHub Release 已发布（Setup.exe + portable.zip）。旧 1.0.17 安装包已从 dist-installer 清理。
3. **git 状态更新**：阶段十二提交已推送，合计 **39 个提交**；本地与远程同步、工作区干净。

### 阶段十三：OCS 加载故障（CRLF 行尾）与中文界面修复 + v1.0.19~1.0.22 发版（2026-08-12，重点排查会话）

1. **故障现象（用户实测反馈）**：全新安装 1.0.19 后打开网课平台**没有 OCS 悬浮窗**，ScriptCat 面板里网课助手版本显示 **0.0**。1.0.18 也存在同样问题。
2. **根因定位（CRLF 行尾）**：
   - 仓库 git 里 `extensions/ocs.user.js` 是 LF（`git show HEAD` 验证），但 Windows 检出时 `core.autocrlf=true` 把工作区文件转成 **CRLF**（828508 字节 vs 官方 807227）；
   - `gen-profile.mjs` 的 `parseUserscriptMeta` 用 `split('\n')` + 正则 `^\s*\/\/\s+@([\w-]+)\s*(.*)$` 解析元数据头，**行尾 `\r` 使 `$` 无法匹配** → 全部 `@version`/`@match` 解析失败 → `metadata:{}` 空对象写入 ScriptCat storage；
   - ScriptCat 面板版本读 `metadata.version` → 空 → 显示 0.0；无 `@match` → 脚本不注入任何页面 → 无悬浮窗；
   - **构建验证被名字回退骗过**：面板验证只查「OCS 网课助手」文本，而解析失败时名字回退默认值同样叫「OCS 网课助手」，坏 seed 照样通过构建验证（LevelDB 中实锤 `"metadata":{}`）。
3. **修复（提交 `971aa5e`）**：
   - `gen-profile.mjs` `parseUserscriptMeta` 解析前 `block[1].replace(/\r/g, '')`，兼容 CRLF/LF 任意行尾（根治）；
   - 验证环节**增强**：面板名字验证后读回 `script:<uuid>` 检查 `metadata.version` 与 `metadata.match` 非空，否则构建直接 Fail——此类问题以后构建期即暴露；
   - 本地 `git config core.autocrlf input`（检出保持 LF）。
4. **新增 `.gitattributes`（提交 `0c08b63`）**：`* text=auto eol=lf` + 二进制白名单（png/jpg/ico/key/zip/exe/pem），全仓库统一 LF——所有克隆者/CI 不再踩 CRLF 坑；仓库 index 全部 24 个文本文件均为 LF，renormalize 无变化，无需重写历史。注意：git 对已存在文件不强制重写物理行尾（归一化比较视为一致），工作区残留 CRLF 不影响功能（gen-profile 已加固），不必强求。
5. **中文界面修复（用户反馈「超星变英文」，提交 `c960a28`）**：
   - 根因：seed 的 `Default/Preferences` 只有 `intl.selected_languages` 而无 `intl.accept_languages`（`--no-first-run` 跳过首次运行初始化），Chromium 回退 en-US → Accept-Language 头英文 → 超星等平台返回英文界面；
   - 修复：`main.go` 启动参数新增 **`--lang=zh-CN`**（命令行优先级最高，每次启动覆盖；已 CDP 实测 `navigator.language=zh-CN`）；`gen-profile.mjs` launch 也带 `--lang=zh-CN`（seed 侧兜底）；
   - 注意：gen-profile 加 `--lang` 后 seed 的 intl 仍只有 selected_languages（accept_languages 只由首次运行初始化写入），运行时靠命令行参数覆盖，功能正常。
6. **构建流程注意（本次踩坑）**：
   - gen-profile 用真实 Chromium 弹窗操作（开发者模式/写存储/验证面板），**构建期间关闭弹出的浏览器窗口会导致 CDP 连接断开、构建失败**（`CDP WebSocket 连接已关闭`）；构建 ~8-10 分钟期间不要碰弹出的窗口；
   - `build.ps1` **不产出 portable zip**，发布便携版需手动打包 dist（Python zipfile，平铺结构，与 1.0.18 portable.zip 一致）；
   - gen-profile 单独失败时可用 dist 内的 chrome/extensions 手动重跑验证（组件缓存齐全时很快）。
7. **release notes 坑（用户发现 Contributors 区出现 "match"）**：release notes 里裸写 `@match` 会被 GitHub 渲染成用户提及，新版 release 页的 **Contributors 区块会展示 notes 中被提及的用户**（`@match` 用户不存在 → 显示裸文本 "match"）。已把 notes 里的 `@version/@match` 改为反引号代码格式，区块消失（实测验证）。**教训：release notes 勿裸写 `@xxx`，用反引号包裹**。
8. **发版记录**：v1.0.19（错误构建，OCS 加载问题未修复即发布，被用户测试发现）→ v1.0.20（修复后构建，gen-profile 偶发失败中断）→ v1.0.21（修复完成、storage 校验通过、用户确认 OCS 加载恢复）→ v1.0.22（中文界面修复，tag + Release 发布，Setup.exe + portable.zip）。
9. **git 状态更新**：阶段十三 4 个提交（`971aa5e` fix(profile) CRLF 修复 / `c960a28` fix(launcher) 中文 / `0c08b63` chore .gitattributes / `1497c86` chore 版本 1.0.22）已全部推送，HEAD = `1497c86`，合计 **44 个提交**；`version.txt` = **1.0.22**；本地与远程同步、工作区干净。

---

## 三、项目当前状态（2026-08-12 更新）

### 构建产物

| 产物 | 位置 | 说明 |
|---|---|---|
| 便携版 | `dist/`（`version.txt` 为 **1.0.22**，版本 pill 注入 `v1.0.22`） | **干净出厂态**（无用户 profile 数据），首次启动自动生成 `profile/` 与 `first_run.flag` |
| 便携 zip | `dist-installer/Course-Thru-1.0.22-portable.zip`（199.5 MB，633 文件） | 手动打包（build.ps1 无 zip 步骤），与 1.0.18 portable.zip 平铺结构一致 |
| 安装版 | `dist-installer/Course-Thru-1.0.22-Setup.exe` | Inno Setup 安装包，安装到 `%LOCALAPPDATA%\Course-Thru`（保留 1.0.18/1.0.19/1.0.21/1.0.22 安装包，旧版可清理） |
| 交付 | `dist/` + `dist-installer/` | `build.ps1` 标准输出目录，即最终交付形态；旧 `Build-Product/` 手工汇总目录**已删除**，不再维护 |

### 组件版本（build.ps1 顶部固定，保证可复现）

- Chromium for Testing **152.0.7977.13**
- ScriptCat（脚本猫）**v1.4.0**
- OCS 网课助手 **4.15.3**

### 扩展 ID 与密钥

- 扩展 ID 由各自公钥计算，恒定（实际 ID 见构建产物 manifest 或下列固定值）：
  - ScriptCat = `hodgdaljmnbiliahlpcjcpiphnkbmfff`
  - 百度 = `kjkhdfinhacckmpplnddgcbbpmncmfmk`
- `keys\scriptcat.key` / `keys\baidu-search.key`：两个扩展的公钥，**均已入库，必备**，删除会改变 ID 并使既有用户数据失效（`build.ps1` 公钥缺失直接 Fail，用 `git restore` 恢复）
- `keys\*_private.pem`：私钥（gitignore 通配 `/keys/*_private.pem`），**仅本地备份**；unpacked 加载不需要它，只在将来 CRX 签名/商店上架时需要

### git 状态

- main 分支，**44 个提交**，HEAD = `1497c86`（版本 1.0.22），**已推送 GitHub**，本地与远程一致、工作区干净
- 阶段十三关键提交：`1497c86` 版本 1.0.22、`0c08b63` 新增 .gitattributes（统一 LF）、`c960a28` 启动器 --lang=zh-CN（中文界面）、`971aa5e` gen-profile CRLF 元数据解析修复 + storage 校验
- 阶段十二关键提交：安装版快捷方式改名「课速通」（`[Icons]` 段 `{#MyAppName}`→中文名）+ 版本 1.0.18 发版（tag + Release）
- 阶段十一关键提交：`e85d536` 主页版权元素 GSAP 动画选择器修复（`#copyright`→`.copyright`，动画选择器与类名一致）
- 阶段十关键提交（倒序）：`d53b45f` 版本 1.0.16、`a714d67` 修复点击加号不跳百度（Chrome 152 opener）、`87a3dd9` 版本 1.0.15、`cdcd1f0` 主页版本 pill/反馈按钮/10 网课入口、`d59a3b8` 版本 1.0.14、`f7dbdc6` 固定百度扩展 ID
- 阶段九关键提交（倒序）：`5de7e34` 关闭会话恢复（每次启动清 `Default/Sessions*` + `--disable-session-crashed-bubble`）+ 版本 1.0.12 发版（Release 已发布）
- 阶段八关键提交（倒序）：`61e4d05` 首启冷启动优化（1MB 缓冲 + 策略并行写）、`f1ead6c` 收录第三方许可证（third-party-licenses/）、`21dcf46` 注册表/Preferences 修复 + copyDir 并发 + UseNumber、`597db33` README 同步
- 阶段七关键提交：`0d2ecf4` 内置主页+新标签页直达百度、`af57464` 关于页版权署名+默认最大化窗口、`cb7b6d6` 移除本地交接文档并加入忽略规则、`ecfd972` 全链路替换品牌 logo、`922f7c2` CfT 策略常驻+屏蔽 cmd 黑框、`8e3ca7e` 品牌字样替换+语言包裁剪、`9ed5660` OCS 恢复上游原版并启用自动更新
- 远程：`origin = https://github.com/IceFireIcer/Course-Thru.git`（新公开仓库；原私有仓库 `Course-Thru-NBCC` 已弃用），`main` 已跟踪 `origin/main`；另有本地备份分支 `backup-before-claude-removal`（`9eb5b4f`，CfT 策略常驻提交处）
- `version.txt` = **1.0.22**
- 提交身份：`IceFireIcer <icefire_icer@outlook.com>`
- `.gitattributes`：全仓库统一 LF（`* text=auto eol=lf` + 二进制白名单），2026-08-12 新增；本机 `core.autocrlf=input`
- gitignore：`.tools/`、`.agents/`、`.claude/`、`skills-lock.json`、`dist/`、`dist-installer/`、`Build-Product/`、私钥（`/keys/*_private.pem`），以及全部本地交接/技术文档（`HANDOVER.md`、`VERSION.md`、`BRANDING-PATCH.md`、`CONSOLE-POLICY-NOTES.md`、`LOGO-REPLACEMENT.md`、`OPEN-VERSION-GUIDE.md`）

> **2026-08-07 修订说明**：本交接文档系从私有项目整库复制而来，git 状态与远程地址已按新仓库实际修订；推送时以本地历史覆盖了建仓自动生成的初始提交（当时的 LICENSE 已保留入库，README 以本项目为准）。
>
> **2026-08-09 修订说明**：项目许可证由 Apache-2.0 改为 **GPL v3**（与内置 ScriptCat 扩展的 GPL v3 一致，规避混合许可证的合规复杂度）。本次同时完成：关闭会话恢复（每次启动清 `Default/Sessions*` + 禁崩溃气泡）、发布 v1.0.12（含 Release），git 状态同步至 24 个提交、HEAD `5de7e34`、version.txt=1.0.12。
>
> **2026-08-10 修订说明**：阶段十——固定百度扩展 ID（`f7dbdc6`）、主页大改版（10 网课入口 / 版本 pill / 反馈按钮，`cdcd1f0`）、修复点击加号不跳百度（Chrome 152 opener 行为变化，`a714d67`）；发版 v1.0.14/v1.0.15/v1.0.16 均已推送并发布 Release，git 状态同步至 37 个提交、HEAD `d53b45f`、version.txt=1.0.16。
>
> **2026-08-10 修订说明（阶段十一）**：主页版权元素 GSAP 入场动画选择器修复（`e85d536`，`#copyright`→`.copyright`），已推送；v1.0.17 完整构建完成（dist + Setup.exe 已出），version.txt=1.0.17 与三份入库文档同步改动暂存工作区，**未提交、未发版**（待办见第七节）。git 状态同步至 38 个提交、HEAD `e85d536`。
>
> **2026-08-10 修订说明（阶段十二）**：安装版快捷方式名称改为中文「课速通」（`installer.iss` `[Icons]` 段），v1.0.18 完整构建 + tag + GitHub Release 已发布（Setup.exe + portable.zip）；git 状态同步至 39 个提交、工作区干净。
>
> **2026-08-12 修订说明（阶段十三）**：用户实测反馈 OCS 版本 0.0、无悬浮窗——根因是 Windows 检出 CRLF 行尾导致 gen-profile 解析 OCS 元数据全部失败（`metadata:{}` 写入 ScriptCat 存储），且构建验证只查面板名字被回退默认值骗过。修复：parseUserscriptMeta 兼容 CRLF + 验证环节读回 storage 校验 @version/@match + 新增 .gitattributes 统一 LF。随后修复超星等平台英文界面（seed 缺 `intl.accept_languages`，启动参数加 `--lang=zh-CN`）。v1.0.19~1.0.22 连续构建发版，1.0.22 确认修复。git 状态同步至 44 个提交、HEAD `1497c86`、version.txt=1.0.22。

### 清理动作的实际状态（重要，未决事项）

用户曾要求清理 `.tools/`、`.agents/`、`.claude/`、`skills-lock.json`，已叫停。当前实测（2026-08-08）：

| 项目 | 状态 | 说明 |
|---|---|---|
| `.tools/` | **存在，537 MB 完整** | 构建缓存（下载的组件），删除后下次构建自动重新下载（约 5-10 分钟）。删除命令当时报告已删，但实测仍在 |
| `.agents/` | **存在，16 MB，25 个技能完整** | 环境自动管理的技能库（来源 `heygen-com/hyperframes`），同上 |
| `skills-lock.json` | **存在** | 技能安装记录，同上 |
| `.claude/` | **已恢复** | 2026-08-08 实测：`.claude/skills` 已有 12 个技能（find-skills / frontend-dev / fullstack-dev / grill-me / gsap-* / openspec-* / skill-creator），不再需要处理 |

> 说明：删除命令当时输出「.tools/.agents/skills-lock.json 已删除」，但事后检查文件仍在（可能被环境自动还原），该现象未查明，列为待办。

---

## 四、代码文件职责（逐个讲清楚）

### 源码与配置（必备，勿删）

| 文件 | 职责 |
|---|---|
| `main.go` | Go 启动器（GUI 子系统，无控制台）。读取 `config.json` → 首次启动把 `profile_seed/` 复制为 `profile/`（同时清理种子中的会话恢复数据）→ 带参启动 Chromium（`--user-data-dir` + `--load-extension`）。**2026-08-07 修改**：① 启动参数加入一批谷歌功能关闭开关（同步/后台联网/组件更新/崩溃上报/翻译/AI 等，见阶段四第 1 条）；② `applyCftPolicies()` 启动时确保 9 条 CfT 专用注册表策略生效（登录/同步/后台运行/安全浏览/泄露检测/搜索建议/网络预加载；缺失或值不对才写入、退出不删除、卸载由安装器清理）；③ 所有 `reg.exe` 子进程统一加 `CREATE_NO_WINDOW`（`hideConsole`）屏蔽 cmd 黑框；④ 默认扩展列表加入 `extensions/baidu-search`；⑤ 修复多扩展 `--load-extension` 合并（单值开关，逗号连接）；⑥ 新增 `coursethru.log` 滚动日志（2 MB 轮转）与严重错误日志自动打包（`crash-logs\` zip + 自动打开文件夹，见阶段五第 2 条）；⑦ 新增 `--start-maximized` 默认最大化窗口；⑧ 新增 `resolveStartURL()`：`defaultUrl` 留空打开内置主页 `course-thru/index.html`，相对路径解析为程序目录下 file:// URL，完整网址原样打开；⑨ 新增 `ensureBaiduQuiet()`：启动前修正 `Default/Preferences`（删除旧版 `chrome_url_overrides` 残留 + 预置接管确认时间戳为 2099），静默扩展接管确认框（先写临时文件再原子替换，失败不阻塞）。**2026-08-08 修改（阶段八）**：⑩ `copyDir` 并发复制（8 worker 池 + 1MB 缓冲），首启出窗更快；⑪ `ensureBaiduQuiet` 改用 `json.Decoder.UseNumber` 解析 Preferences，保留无关大整数精度、时间戳整数原文写入；⑫ 首启 `first_run.flag` 立即写入、CDP 关欢迎页移入后台 goroutine；⑬ `loadConfig` 强制保留 `extensions/scriptcat`（自定义列表不会破坏预置 OCS）；⑭ `applyCftPolicies` 整键一次查询、值缺失/不对才补写，且补写并行（`addCftPoliciesParallel`）；⑮ `regValueEquals` 十六进制解析为数值后比较，杜绝 0x10 类误判。**2026-08-09 修改（阶段九）**：⑯ 关闭会话恢复——每次启动前清理 `Default/Sessions` / `Sessions_Encrypted`（原仅首次复制种子时清理，现改为每次启动都清，杜绝上次会话被恢复）；⑰ 启动参数新增 `--disable-session-crashed-bubble`，异常退出后不弹「恢复页面？」气泡，配合 ⑯ 实现每次启动都从默认页全新开始。**2026-08-10 修改（阶段十）**：⑱ `loadConfig` 强制保留 `extensions/baidu-search`（与 scriptcat 兜底对称，防止旧版 config.json 缺项导致百度扩展不加载、新标签页不跳百度）。**2026-08-12 修改（阶段十三）**：⑲ 启动参数新增 `--lang=zh-CN`——seed 缺 `intl.accept_languages` 时 Chromium 回退 en-US，超星等网课平台按英文界面返回；命令行参数优先级最高，每次启动覆盖（实测 `navigator.language=zh-CN`）。 |
| `go.mod` | Go 模块定义（`coursethru/launcher`，go 1.26）。 |
| `build.ps1` | 一键构建：下载固定版本组件（直连失败自动回退系统代理）→ 校验/复用公钥（scriptcat + baidu-search 两个公钥，缺失即报错）→ 装配 ScriptCat（注入 key + 欢迎页补丁）→ 品牌化处理（`patch-branding.py` 替换 pak 品牌字样与 "Google LLC." 版权、3.55 步替换 `ABOUT` 版权署名、`patch-logo.py` + `patch-icons.py` 替换 logo/图标、裁剪语言包只保留中英繁）→ 复制百度扩展（注入 key）与内置主页 `course-thru/`（**替换 `v__VERSION__` 占位符为当前版本**，UTF-8 显式读写）→ 编译启动器 → 生成/复用预置 profile → 写 `config.json`（默认扩展列表含 scriptcat + baidu-search）→ 清理产物残留（7.5 节）→ Inno Setup 打包。参数：`-SkipProfile`、`-NoNsis`、`-Version x.y.z`。**注意：文件必须保持 UTF-8 BOM（PowerShell 5.1 中文脚本依赖）**。 |
| `extensions/baidu-search/` | **2026-08-07 新增，v1.1.0**。百度内置扩展（MV3）：① `manifest.json` 用 `chrome_settings_overrides.search_provider` 设默认搜索引擎（未托管机器上唯一可靠方式，sensitive 策略会被 Chrome 忽略，设置页标注「由扩展控制」）；② `background.js` 监听新标签页（`onCreated`/`onUpdated`），**只按 URL 判断**是否 `chrome://newtab`（或 `chrome://new-tab-page-third-party`），命中即导航到百度——**不查 openerTabId**（Chrome 152 起 UI 新建标签页 openerTabId 非空，查 opener 会误拦截真实用户点击，v1.0.16 已修复）；不接管 `chrome_url_overrides`，不弹确认框；改 `BAIDU_URL` 可换目标页。 |
| `course-thru/` | **2026-08-07 新增，2026-08-10 大改版**。内置主页（`index.html` + `fonts/SmileySans` 字体 + `js/gsap.min.js` + `logo.png`，全部相对路径、file:// 自包含、离线可用）：10 个网课平台快捷入口（横向 10 列铺开 + 卡片容器查询 `cqw` 自动缩放 + JS 动态字号策略 `fitNameFontSize`——短名单行放大、长名自动调小最多 3 行）；右上角版本 pill（Liquid Glass，构建期注入 `v<版本>`，源码直开显示 `v-dev`）；左下角反馈按钮（Liquid Glass + 得意黑 + 亮橙黄，跳飞书表单）；`defaultUrl` 留空时启动打开；installer 随程序安装。 |
| `gen-profile.mjs` | CDP 驱动真实 Chromium 生成预置 profile：**直接写入 ScriptCat 存储预置 OCS（默认启用）**，开启开发者模式与 userScripts 开关，关闭→重启→自动验证。信号驱动（DOM 条件等待），无固定 sleep。**2026-08-07**：预置 OCS 时开启 ScriptCat 自动更新（`checkUpdate: true`，更新源为 GitHub 最新 Release 资产 URL）。**2026-08-12（阶段十三）**：① `parseUserscriptMeta` 解析前统一去 `\r`，兼容 CRLF/LF 任意行尾（CRLF 曾致全部元数据解析失败 → OCS 版本 0.0，见阶段十三）；② 验证环节读回 `script:<uuid>` 校验 `metadata.version`/`metadata.match` 非空（只查面板名字会被回退默认值骗过）；③ launch 带 `--lang=zh-CN` 初始化 seed 语言（`intl.accept_languages` 仍不写入，运行时靠 main.go 的 --lang 覆盖）。由 `build.ps1` 调用。 |
| `.gitattributes` | **2026-08-12 新增**。全仓库统一行尾：`* text=auto eol=lf` + 二进制白名单（png/jpg/jpeg/ico/key/zip/exe/pem）。防止 Windows 检出 CRLF 破坏脚本元数据解析（阶段十三故障的源头防线）；仓库 index 全部文本文件为 LF，无需 renormalize。 |
| `extensions/ocs.user.js` | OCS 网课助手脚本（4.15.3，GitHub Release 最新原版、未改动），**随仓库入库**；自带官方「📥 更新模块」，并由 `gen-profile.mjs` 开启 ScriptCat 自动更新检查（双通道自动更新）。构建时复制进产物，由 `gen-profile.mjs` 预置到 ScriptCat 存储并默认启用。 |
| `course-thru/` | **2026-08-07 新增**。内置主页（`index.html` + `fonts/SmileySans` 字体 + `js/gsap.min.js` + `logo.png`，全部相对路径、file:// 自包含、离线可用）；`defaultUrl` 留空时启动打开；installer 随程序安装。 |
| `logo/logo.png` | **2026-08-07 新增**。唯一 logo 源文件，`generate-assets.py` 据此生成全套资源。 |
| `assets/` | **2026-08-07 新增**。生成的 logo 资源（`app.ico`、安装向导图、pak 内嵌 PNG、ScriptCat 扩展图标等），构建期由脚本消费，勿手改（重新生成会覆盖）。 |
| `generate-assets.py` / `patch-logo.py` / `patch-icons.py` | **2026-08-07 新增**。构建期品牌资源脚本：`generate-assets.py` 从 logo 生成全套资产；`patch-logo.py` 内容识别替换 pak 内产品 logo PNG；`patch-icons.py` 重建资源段替换 chrome.exe / chrome.dll / 启动器 PE 图标。均幂等。 |
| `patch-branding.py` | **2026-08-07 新增**。构建期把 `locales\*.pak` 里的 "Chrome for Testing" 替换为 "Course-Thru 课速通"、"Google LLC." 替换为 "IceFire_Icer."（幂等）。 |
| `installer.iss` | Inno Setup 安装脚本：把 `dist/` 内容（含 `course-thru/` 内置主页）装到 `{app}`，创建快捷方式（桌面图标任务**默认勾选**），卸载时调用 `stop-browser.ps1`、删除应用目录，并在 `usPostUninstall` 阶段清理本程序写入的 CfT 企业策略（`DeleteCftPolicies`，常驻设计的硬性要求）。 |
| `stop-browser.ps1` | 卸载辅助：按路径关闭本程序启动的浏览器进程，不影响用户自己的 Chrome。 |
| `keys\scriptcat.key` | ScriptCat 扩展公钥（736 B，base64）。扩展 ID 由此确定，**缺失时构建直接报错**。 |
| `config.json.example` | `config.json` 字段参考：`defaultUrl`、`extraArgs`、`appName`、`extensions`。 |
| `version.txt` | 应用版本单一来源（`x.y.z`），完整构建自动 patch +1 并写回；构建时注入安装包与 `dist\version.txt`。**2026-08-07 新增**，方案见 `VERSION.md`。 |
| `third-party-licenses/` | **2026-08-08 新增**。第三方开源许可证原文：OCS（MIT，enncy）+ ScriptCat（**GPL v3**，CodFrm），见 `README.md`；以扩展形式分发 ScriptCat 需遵守 GPL v3。 |
| `.gitignore` | 忽略规则。**本轮修改**：新增 `/Build-Product/`。 |

### 文档

| 文件 | 职责 |
|---|---|
| `README.md` | **公共仓库唯一的使用与构建文档**（特性、目录结构、构建命令、常见问题、许可证），入库并与本文档同步维护。 |
| `AGENTS.md` | 贡献者指南（项目结构、构建/测试命令、代码风格、测试与提交约定、密钥安全），入库。 |
| `LICENSE` / `third-party-licenses/` | **2026-08-08**：项目 LICENSE 与第三方许可证原文（OCS=MIT、ScriptCat=GPL v3），入库随仓库分发。**2026-08-09**：项目许可证由 Apache-2.0 **改为 GPL v3**（`LICENSE` 换为 GPL v3 全文，与 ScriptCat 的 GPL v3 完全兼容）；在官方「How to Apply」模板区填入项目版权信息「Course-Thru（课速通）浏览器发行版 / Copyright (C) 2026 IceFire_Icer」（保持官方文本 674 行不变）。 |
| `HANDOVER.md` | 本文档（**2026-08-12 起入库**，完整交接随仓库维护）。 |
| `VERSION.md` | 版本管理方案：`version.txt` 单一来源、完整构建 patch 自动递增、`-Version` 覆盖、远程同步步骤（**本地维护**）。 |
| `CONSOLE-POLICY-NOTES.md` | cmd 黑框屏蔽（`CREATE_NO_WINDOW`）与 CfT 企业策略生命周期（常驻 + 卸载清理）的设计取舍（**本地维护**）。 |
| `BRANDING-PATCH.md` | 品牌字样替换与语言包裁剪方案（**本地维护**）。 |
| `LOGO-REPLACEMENT.md` | logo 全链路替换方案、验证清单与踩坑记录（**本地维护**）。 |
| `OPEN-VERSION-GUIDE.md` | 开放版设计：扩展接管静默（`ensureBaiduQuiet`）、新标签页直达百度等方案说明（**本地维护**）。 |

### 生成目录（非源码，均可重建）

| 目录/文件 | 职责 |
|---|---|
| `dist/` | 便携版构建输出（chrome、extensions、profile_seed、Course-Thru.exe、config.json），即交付形态。 |
| `dist-installer/` | 安装版输出（`Course-Thru-<版本>-Setup.exe`，版本号由构建自动注入），即交付形态。 |
| `Build-Product/` | 旧手工交付汇总目录，**2026-08-08 已删除**，不再维护（交付以 `dist/` + `dist-installer/` 为准）。 |
| `.tools/` | 构建缓存：下载的 Chromium/Go/Inno Setup 压缩包与解压目录（约 537 MB）。 |
| `.agents/`、`.claude/`、`skills-lock.json` | 环境自动生成的技能库/配置，不属于本项目代码（gitignore 已注明）。 |
| `keys\scriptcat_private.pem` | 私钥备份（gitignore），勿删勿传。 |

---

## 五、关键机制

### 1. 首次启动流程（开箱即用）

1. 启动器检查 `profile/` 是否存在；不存在则从 `profile_seed/` 复制（种子已含 userScripts 开关 + OCS 脚本；`copyDir` 并发 8 worker + 1MB 缓冲，机械硬盘上首启出窗更快）。
2. 启动前修正 `Default/Preferences`：`ensureBaiduQuiet()` 删除旧版 `chrome_url_overrides` 残留并预置接管确认时间戳（静默百度扩展的「接管设置」确认框）。
3. 解析启动地址：`defaultUrl` 留空 → 内置主页 `course-thru/index.html`；相对路径 → 程序目录下 file:// URL；完整网址 → 原样打开。
4. 检查 `first_run.flag`；不存在则视为首次运行：带 `--remote-debugging-port=0` 启动，**立即写入**标记文件，随后在后台 goroutine 轮询 `profile/DevToolsActivePort`、通过 CDP HTTP 接口关闭 ScriptCat 欢迎页（纯兜底，构建期已在扩展源码屏蔽，失败无副作用、不阻塞出窗）。
5. 后续启动：不带调试参数，直接正常启动；用户数据持续写入 `profile/`，跨目录拷贝也有效（扩展 ID 恒定）。

### 2. ScriptCat 欢迎页屏蔽（双层）

- **源码层**：`build.ps1` 把 `service_worker.js` 中 `if("install"===e.reason)chrome.tabs.create(...)` 改为 `if("install"===e.reason&&false)...`，任何启动都不再弹页。补丁检测区分「未打补丁/已打补丁/代码已变更」三种状态。
- **启动器层**：首次启动时 CDP 兜底关闭 `install_comple` 页面（URL 含 `install_comple` 即匹配），兼容旧版本扩展或未来版本变化。

### 3. 密钥与 ID 恒定

unpacked 扩展的 ID 只由 manifest 里的公钥派生，加载时不校验签名。因此公钥写死即可让所有安装的扩展 ID 相同，预置数据（按 ID 存储）随 profile 移植不失效；私钥只在未来 CRX 签名/商店上架时才需要。

### 4. 关键技术决策（接手人必读）

1. **不用 Electron**：缺 `chrome.userScripts` API，ScriptCat 脚本注入依赖它。
2. **不用 Chrome 品牌版**：Chrome 137+ 移除了 `--load-extension`；Chromium for Testing 不受影响。
3. **注入固定 key**：unpacked 扩展无 key 时 ID 随路径变化，预置数据会丢。
4. **预置 profile**：userScripts 开关与脚本数据在 `chrome.storage.local`（LevelDB），构建时用真实 Chromium 配好打包为 `profile_seed`。
5. **不能用 `--disable-extensions-except`**：会触发 Chromium「先禁用全部扩展再重启」流程，首次启动报错。
6. **Inno Setup 替代 NSIS**：NSIS 官方二进制仅 SourceForge 托管，国内不可达。
7. **抑制 CfT 测试横幅**：Chromium for Testing 顶部会固定显示「仅适用于自动测试」黄色横幅，启动参数带 `--disable-infobars` 即可隐藏（CfT 2023-11 起支持该开关），已加入 main.go 默认参数。
8. **行尾策略统一 LF（2026-08-12 教训）**：Windows 上 `core.autocrlf=true` 把检出文件转成 CRLF，会静默破坏按行解析的脚本（gen-profile 解析 OCS 元数据 → 版本 0.0）。防线三层：`.gitattributes`（`* text=auto eol=lf`）防检出、gen-profile 解析前去 `\r` 根治、本机 `core.autocrlf=input`。**教训：任何按行解析/拼接文本的构建脚本都要兼容 CRLF；构建验证必须校验数据内容而非 UI 文本**（面板名字解析失败会回退默认值，只查名字的验证是无效的）。
9. **网课平台语言跟随 Accept-Language**：超星等平台按 Accept-Language 头返回界面语言。seed 缺 `intl.accept_languages` 时 Chromium 回退 en-US → 英文界面。`--lang=zh-CN` 命令行参数优先级最高、每次启动覆盖，是最省心的强制手段（不依赖 Preferences 数据）。

### 5. 谷歌功能清理机制（2026-08-07）

1. **能用启动参数就绝不用策略**：同步、后台联网、组件更新、崩溃上报、翻译、AI 等功能都有命令行开关，已写死在 `main.go`（改动组件版本时需复核这些开关在对应源码中仍然存在；不存在的 feature 名会被 Chrome 静默忽略，无副作用）。
2. **只有注册表策略能做的**（CDP/参数均无法完成）：关浏览器登录入口（`BrowserSignin`）、关同步（`SyncDisabled`）、关后台运行（`BackgroundModeEnabled`）、关安全浏览（`SafeBrowsingProtectionLevel`）等 9 条，写入 `HKCU\Software\Policies\Google\Chrome for Testing`（CfT 专属路径，不影响日常 Chrome）。生命周期为**常驻**：启动时逐条查询、缺失或值不对才写入，退出不删除；卸载时由 installer.iss 整键清理。早期"每次启动写入、退出恢复"版本已废弃（异常退出残留、每次退出多 ~20 次注册表操作，均无必要）。
3. **sensitive 策略陷阱**：未加入域的机器上 Chrome 会过滤 sensitive 策略（`DefaultSearchProvider*`、`MetricsReportingEnabled`、`SafeBrowsingEnabled` 等），写了也无效——所以默认搜索引擎改用扩展实现，UMA 用启动参数在网络层关闭。
4. **默认搜索引擎用扩展而非策略**：`chrome_settings_overrides.search_provider` 是官方机制，unpacked 扩展直接生效，且设置页会标注「由扩展控制」，用户无法在设置里改回。

### 6. 内置主页与新标签页/默认搜索机制（2026-08-07）

1. **默认搜索用扩展**：见第 5 节第 4 条，百度扩展的 `chrome_settings_overrides.search_provider` 在 unpacked 扩展上直接生效。
2. **新标签页直达百度但不接管设置**：百度扩展 `background.js` 只监听新标签页创建/地址变化，若为 `chrome://newtab`（或 `chrome://new-tab-page-third-party`），导航到百度；不用 `chrome_url_overrides`，因此不弹「更改此网页是您的本意吗？」确认框。**v1.0.16 起只按 URL 判断、不查 openerTabId**——Chrome 152 起通过 UI（Ctrl+T/点击加号）新建的标签页 `openerTabId` 非空，旧版 `!tab.openerTabId` 判断会误拦截真实用户操作（点击加号停在新标签页不跳百度），已修复。从链接/脚本新开的标签地址是具体链接（非 newtab），不会被误伤。
3. **确认框静默（升级用户必做）**：`main.go` 的 `ensureBaiduQuiet()` 在启动前修正 `Default/Preferences`——① 删除旧版 `extensions.chrome_url_overrides` 残留（Chrome 只清理「扩展已不存在」的记录，不会清理「扩展还在但已不声明接管」的残留）；② 把 `simple_override_begin_confirmation_timestamp` 预置为 2099 年时间戳，让「更改搜索服务提供商是您的本意吗？」不再弹出。Preferences 解析用 `json.Decoder.UseNumber` 保留无关字段大整数精度、目标时间戳以整数原文写入（避免被改写成科学计数法丢精度）。先写临时文件再原子替换，解析失败则跳过、不阻塞主流程。方案见 `OPEN-VERSION-GUIDE.md` §2。
4. **内置主页**：`course-thru/` 全部相对路径、file:// 自包含、离线可用；字体（SmileySans）与动画库（GSAP）随目录分发，不依赖网络。**v1.0.15 大改版**：10 个网课平台快捷入口（横向 10 列 + 卡片 `cqw` 容器查询自动缩放 + JS 动态字号 `fitNameFontSize`——短名单行放大、长名多行调小）、右上角版本 pill（Liquid Glass，构建期 `build.ps1` 替换 `v__VERSION__` 为实际版本）、左下角反馈按钮（Liquid Glass，跳飞书表单）。

### 7. 品牌化机制（构建期，2026-08-07）

1. **品牌字样与版权署名**：`patch-branding.py` 把 `locales\*.pak` 里 "Chrome for Testing" / "Google Chrome for Testing" 替换为 "Course-Thru 课速通" / "Course-Thru"（窗口标题模板、新标签页「自定义」按钮、设置「关于」页等），并把 "Google LLC." 替换为 "IceFire_Icer."；`build.ps1` 3.55 步直接替换 `ABOUT` 文件的完整版权行。全部幂等，升级 Chromium 版本后由构建自动重打（未匹配到原文会警告，需按版本更新补丁）。
2. **logo 与图标**：`generate-assets.py` 从 `logo/logo.png` 生成全套资源（app.ico、安装向导图、pak 内嵌 PNG、ScriptCat 图标）；`patch-logo.py` 内容识别替换 `chrome_*.pak` / `resources.pak` 内产品 logo；`patch-icons.py` 重建资源段替换 chrome.exe / chrome.dll / chrome_pwa_launcher.exe / 启动器 PE 图标；安装包图标/向导图一并替换。已知限制：NTP 顶部 Google 字标由二进制内资源动态提供，无法替换（见 `LOGO-REPLACEMENT.md` 6.9）。
3. **语言包裁剪**：Chromium 只保留 en-US / zh-CN / zh-TW（含性别变体），ScriptCat 只保留 en / zh_CN / zh_TW；首选语言缺失时自动回退 en-US / default_locale(en)，不会报错。

---

## 六、常用命令

```powershell
# 完整构建（便携版 dist + 安装版 dist-installer）
powershell -ExecutionPolicy Bypass -File build.ps1

# 只构建便携版
powershell -ExecutionPolicy Bypass -File build.ps1 -NoNsis

# 跳过预置 profile 生成（复用已有 dist\profile_seed）
powershell -ExecutionPolicy Bypass -File build.ps1 -SkipProfile
```

`dist/` 与 `dist-installer/` 即最终交付形态（旧 `Build-Product/` 汇总目录已删除，无需再手工同步）。

验证要点：首次启动生成 `profile/` 与 `first_run.flag`，且**只打开 1 个页面（内置主页 `course-thru/index.html`）**（无多余会话窗口）；任何启动都不出现 `docs.scriptcat.org` 相关页面（install_comple / changelog / open-dev）；扩展 ID 恒定（由 `keys\scriptcat.key` 公钥计算，不随目录变化）；默认搜索引擎为百度（设置页标注「由扩展控制」）、新标签页直达百度且无任何确认弹窗；**ScriptCat 面板 OCS 版本显示 4.15.3（0.0 = 元数据解析失败，构建会 Fail）**；网课平台（超星等）显示中文界面（`navigator.language`=zh-CN）。

发布便携 zip（build.ps1 无此步骤）：Python `zipfile` 打包 `dist/` 全部内容（平铺结构，与旧 portable.zip 一致）到 `dist-installer/Course-Thru-<版本>-portable.zip`。**构建期间勿关闭 gen-profile 弹出的浏览器窗口**（CDP 驱动中，关闭即构建失败）。**release notes 勿裸写 `@xxx`**（GitHub 渲染成 @提及，Contributors 区块会展示提及用户）。

---

## 七、已知问题与待办

| 事项 | 状态 | 说明 |
|---|---|---|
| 阶段四改动提交 | ✅ 已完成 | 2026-08-07：`main.go`、`build.ps1` 修改 + `extensions/baidu-search/` 新增 + `extensions/ocs.user.js` 外部修改，已随 `bf66eb6` 一并提交并推送，本地与远程同步 |
| 注册表/Preferences 处理修复 | ✅ 已完成 | 2026-08-08：`21dcf46` 已提交推送——`regValueEquals` 十六进制解析数值比较、`ensureBaiduQuiet` 用 UseNumber 保留大整数精度、首启 `first_run.flag` 立即写入 + 欢迎页清理后台化、`loadConfig` 强制保留 scriptcat、`applyCftPolicies` 整键一次查询 |
| 首启冷启动性能优化 | ✅ 已完成 | 2026-08-08：`61e4d05` 已提交推送——copyDir 并发 8 worker、copyFile 1MB 缓冲、CfT 策略并行补写（9 条 reg add 压缩为约一次往返） |
| 第三方许可证收录 | ✅ 已完成 | 2026-08-08：`f1ead6c` 已提交推送——新增 `third-party-licenses/`（OCS=MIT、ScriptCat=**GPL v3**），公共 README 与 README.md 同步标注 |
| 版本号自动递增 | ✅ 已完成 | `version.txt` 单一来源；完整构建 patch 自动 +1、`-NoNsis` 复用、`-Version` 覆盖；安装包文件名与 AppVersion 带版本；方案见 `VERSION.md` |
| 严重错误日志打包 | ✅ 已完成 | `coursethru.log` 滚动日志（2 MB 轮转）；致命错误时自动打包 zip 到 `crash-logs\` 并打开文件夹，弹窗附 zip 路径；端到端实测通过 |
| OCS 脚本维护 | ✅ 已完成 | 2026-08-07：已替换为 GitHub Release 最新原版 4.15.3 并启用自动更新（脚本自带更新模块 + ScriptCat `checkUpdate: true`，更新源为 GitHub 最新 Release 资产）。后续升级：替换 `extensions/ocs.user.js` → 同步 `build.ps1` 顶部 `$OcsTag` → 重新生成 `profile_seed` |
| `.claude/` 清理中断 | ⚠️ 已恢复 | 2026-08-08：`.claude/skills` 已恢复完整（12 个技能：find-skills / frontend-dev / fullstack-dev / grill-me / gsap-* / openspec-* / skill-creator），不再需要处理 |
| `.tools/`、`.agents/`、`skills-lock.json` 是否清除 | ⚠️ 待用户决定 | 清理已叫停；`.tools` 为可重建缓存（约 537 MB），`.agents`/`skills-lock.json` 由环境管理 |
| `gen-profile.mjs` 时序/流程 | ✅ 已修复 | 已改为信号驱动 + 直接存储注入（无服务器、无 UI 点击安装）；`profile_seed` 已用新流程重新生成并端到端验证（OCS 预置启用、开发者模式开启、无欢迎页、无扩展错误、跨路径可移植） |
| 组件版本升级 | 📋 待办 | 改 `build.ps1` 顶部版本号 + 重新生成 `profile_seed` |
| 默认网课平台 | 📋 待办 | `config.json` 的 `defaultUrl` 留空（启动打开内置主页）；需要时填入平台地址 |
| 推送 GitHub | ✅ 已完成 | `origin = https://github.com/IceFireIcer/Course-Thru.git`（新仓库），main 分支已推送（**38 个提交**，HEAD `e85d536`，含阶段四~十一全部改动），本地与远程一致；v1.0.14 / v1.0.15 / v1.0.16 tag + Release 均已发布 |
| 主页版权元素动画选择器修复 | ✅ 已完成 | `e85d536` 已提交推送：GSAP 入场动画 `#copyright`→`.copyright`（与 HTML 类名一致，桌面/移动两套时间线 + reduce 分支共 4 处），版权元素恢复淡入上移动效 |
| v1.0.17 发版 | ✅ 已完成 | 2026-08-10：提交 `ac15eb5`（version.txt=1.0.17 + 三份入库文档同步）+ tag `v1.0.17` + GitHub Release（Setup.exe + portable.zip）均已发布 |
| 快捷方式中文名 + v1.0.18 发版 | ✅ 已完成 | 2026-08-10：`installer.iss` `[Icons]` 段快捷方式名改为「课速通」（安装目录/进程名不变）；v1.0.18 完整构建 + tag + Release 已发布 |
| OCS 加载故障（版本 0.0） | ✅ 已修复 | 2026-08-12：CRLF 行尾致 gen-profile 解析 OCS 元数据全部失败（`metadata:{}`）。`971aa5e` 已提交推送——parseUserscriptMeta 去 `\r` 根治 + 验证环节读回 storage 校验 @version/@match（构建期即拦截）；`.gitattributes`（`0c08b63`）统一 LF 防复发 |
| 网课平台英文界面 | ✅ 已修复 | 2026-08-12：seed 缺 `intl.accept_languages` 回退 en-US。`c960a28` 已提交推送——main.go 启动参数 `--lang=zh-CN`（+ gen-profile launch 兜底），实测超星恢复中文 |
| v1.0.19~1.0.22 发版 | ✅ 已完成 | 2026-08-12：1.0.19（坏，未修复即发）、1.0.20（构建中断）、1.0.21（OCS 修复确认）、1.0.22（中文修复，tag + Release 已发布：Setup.exe + portable.zip 手动打包）。旧安装包（1.0.18/1.0.19/1.0.21）可清理 |
| 关闭会话恢复 | ✅ 已完成 | 2026-08-09：`5de7e34` 已提交推送——每次启动清 `Default/Sessions*` + `--disable-session-crashed-bubble`，每次启动从默认页全新开始 |
| 项目许可证改 GPL v3 | ✅ 已完成 | 2026-08-09：`LICENSE` 替换为 GPL v3 全文，README / AGENTS / CLAUDE 同步，与 ScriptCat 的 GPL v3 完全兼容 |
| 品牌字样/版权署名/语言包裁剪 | ✅ 已完成 | `8e3ca7e`（品牌字样+语言包）与 `af57464`（关于页版权署名+默认最大化窗口）已提交推送；`patch-branding.py` 幂等，升级 Chromium 后自动重打 |
| 全链路品牌 logo | ✅ 已完成 | `ecfd972` 已提交推送；`logo/logo.png` 唯一源文件 → `generate-assets.py` / `patch-logo.py` / `patch-icons.py` 全链路替换；已知限制：NTP 顶部 Google 字标不可替换 |
| 内置主页 + 新标签页直达百度 | ✅ 已完成 | `0d2ecf4` 已提交推送；`course-thru/` 内置主页 + `resolveStartURL()` + 百度扩展 v1.1.0（background.js）+ `ensureBaiduQuiet()` 静默确认框 |
| 固定百度扩展 ID | ✅ 已完成 | `f7dbdc6` 已提交推送（v1.0.14）：新增 `keys/baidu-search.key`（公钥入库）+ 私钥 gitignore，`build.ps1` 注入 key，扩展 ID 固定为 `kjkhdfinhacckmpplnddgcbbpmncmfmk` |
| 主页大改版（10 网课入口 / 版本 pill / 反馈按钮） | ✅ 已完成 | `cdcd1f0` 已提交推送（v1.0.15）：10 网课入口横向铺开 + 动态字号；右上角版本 pill（Liquid Glass，构建期注入）；左下角反馈按钮（Liquid Glass 跳飞书表单）；`build.ps1` 版本占位符替换 |
| 修复点击加号不跳百度 | ✅ 已完成 | `a714d67` 已提交推送（v1.0.16）：Chrome 152 起 UI 新建标签页 `openerTabId` 非空，`background.js` 去掉 opener 判断、只按 URL 判断；`main.go` 强制保留 baidu-search 扩展；真实 Ctrl+T 端到端验证通过 |
| 本地交接文档移出仓库 | ✅ 已完成 | `cb7b6d6` 已提交推送；HANDOVER / VERSION / BRANDING-PATCH / CONSOLE-POLICY-NOTES / LOGO-REPLACEMENT / OPEN-VERSION-GUIDE 均 gitignore、仅本地维护；公共仓库只保留 README + AGENTS |
| Build-Product 交付目录 | ✅ 已删除 | 2026-08-08：旧手工汇总目录已不存在（gitignore 保留），交付以 `dist/` + `dist-installer/`（现仅含 1.0.17 安装包）为准，无需再同步 |
| 私钥安全备份 | 📋 建议 | 把 `keys\scriptcat_private.pem` 与 `keys\baidu-search_private.pem` 都备份到仓库外安全位置 |
| 应用图标 | ✅ 已完成 | 2026-08-07：按 `LOGO-REPLACEMENT.md` 全链路替换——pak 产品 logo（四色 + CfT 浅蓝 C 双启发式，内容识别，幂等）、chrome.exe / chrome.dll / chrome_pwa_launcher.exe / 启动器 PE 图标、ScriptCat 扩展图标、安装包图标与向导图；当时产物（1.0.7）已按 5.1/5.2/5.3 清单验证（pak 无残留、图标像素一致、headless 冒烟通过）。已知限制：NTP 顶部 Google 字标由二进制内资源动态提供，无法替换（见 LOGO-REPLACEMENT.md 6.9） |
| 物理文件夹改名 | 💡 可选 | 当前工作区根路径为 `Course-Thru-Open`，需要时可改名为 `Course-Thru`（不影响 git 内容） |

---

## 八、接手建议（suggested skills）

- 无强制技能。下一步大概率是：① 按阶段十三维护 OCS（替换 `extensions/ocs.user.js` → 更新 `$OcsTag` → **删除 `dist\profile_seed` 重新生成**；脚本自带更新模块 + ScriptCat 自动更新双通道兜底；**改过 gen-profile.mjs 必须重建 seed 并端到端验证**）；② 发版流程：完整构建（自动递增版本）→ 手动打 portable zip（build.ps1 无此步骤）→ 提交并推送 → tag + `gh release create`（notes 勿裸写 `@xxx`）；③ 关注 GPL v3 合规（`third-party-licenses/` 收录 ScriptCat GPL v3 许可证原文，以扩展形式分发时需遵守其条款）；④ 清理 dist-installer 旧安装包（1.0.18/1.0.19/1.0.21）。
- 交接与技术文档：**HANDOVER.md 已入库**（2026-08-12 起随仓库维护）；VERSION / BRANDING-PATCH / CONSOLE-POLICY-NOTES / LOGO-REPLACEMENT / OPEN-VERSION-GUIDE **仅本地维护、不入库**，改完不必推送。仓库入库文档：README.md、AGENTS.md、CLAUDE.md、HANDOVER.md，另含 LICENSE（GPL v3）与 `third-party-licenses/`。
- **构建期间勿关闭 gen-profile 弹出的浏览器窗口**（CDP 驱动中，关闭即 `CDP WebSocket 连接已关闭` 构建失败）。
- 若需要排查浏览器/构建行为异常（如扩展加载失败、参数失效），可考虑 `diagnosing-bugs` 技能。
- 若后续产出视频类产物（如产品演示），仓库技能库 `.agents/skills` 下有 hyperframes 系列（`changelog-video`、`general-video` 等），按需选用。
