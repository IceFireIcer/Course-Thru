# Course-Thru（课速通）交接文档（更新版）

> 更新时间：2026-08-07（第五阶段后修订：git 状态与远程地址已同步至新仓库 Course-Thru；README 中扩展 ID 已移除；CfT 企业策略改为常驻设计，见 `CONSOLE-POLICY-NOTES.md`）
> 项目：Course-Thru（课速通）— 基于 Chromium + ScriptCat + OCS 的刷网课浏览器（Windows）
> 阅读顺序：先读 README.md 了解使用方式，再读本文了解来龙去脉与当前状态。

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
11. **修复「启动弹出 8 个窗口」**（2026-08-06）：根因是种子携带了生成流程的会话恢复数据（`Default\Sessions` / `Sessions_Encrypted`），用户首启时 Chromium 恢复出生成期间打开的 options 页、扩展详情页、脚本猫更新日志/引导页（还有重复）。修复：`gen-profile.mjs` 生成结束时清理会话数据、`build.ps1` 组装种子时兜底清理、`main.go` 首次运行复制种子后同样清理（三重保险）。实测启动只打开 1 个 `about:blank`。

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
5. **本次改动尚未提交**：`extensions/ocs.user.js`、`gen-profile.mjs`、`build.ps1`、`HANDOVER.md` 均为工作区改动；`dist\`、`Build-Product\` 为 gitignore 产物，不提交。

---

## 三、项目当前状态（2026-08-07 更新）

### 构建产物

| 产物 | 位置 | 说明 |
|---|---|---|
| 便携版 | `Build-Product\portable\`（约 466 MB） | **干净出厂态**（无用户 profile 数据），首次启动自动生成 `profile/` 与 `first_run.flag` |
| 安装版 | `Build-Product\Course-Thru-<版本>-Setup.exe`（约 150 MB，文件名含版本号） | Inno Setup 安装包，安装到 `%LOCALAPPDATA%\Course-Thru` |
| 工作输出 | `dist/`（约 466 MB）、`dist-installer/` | `build.ps1` 的标准输出目录，内容与 Build-Product 一致 |

### 组件版本（build.ps1 顶部固定，保证可复现）

- Chromium for Testing **152.0.7977.13**
- ScriptCat（脚本猫）**v1.4.0**
- OCS 网课助手 **4.15.3**

### 扩展 ID 与密钥

- 扩展 ID：由 `keys\scriptcat.key` 公钥计算，恒定（具体值不在文档中列出，构建产物 manifest 中可查）
- `keys\scriptcat.key`：公钥，**已入库，必备**，删除会改变 ID 并使既有用户数据失效
- `keys\scriptcat_private.pem`：私钥，gitignore，**仅本地备份**；unpacked 加载不需要它，只在将来 CRX 签名/商店上架时需要

### git 状态

- main 分支，10 个提交（`f0423da` 初始搭建、`42a45c4` 交接文档、`df785ab` 改名与重构、`52efc8b` 交接文档更新、`61fc0c5` 抑制 CfT 横幅、`bf66eb6` 关闭谷歌功能并以百度为默认搜索引擎、`600857d` 交接文档同步、`b156b73` 版本号自动递增、`c04a531` 严重错误日志打包、`1236ed1` README 同步），**已推送 GitHub**
- 远程：`origin = https://github.com/IceFireIcer/Course-Thru.git`（新公开仓库；原私有仓库 `Course-Thru-NBCC` 已弃用），`main` 已跟踪 `origin/main`，本地 `HEAD` 与远程一致，工作区干净
- 提交身份：`IceFireIcer <icefire_icer@outlook.com>`
- `.tools/`、`.agents/`、`.claude/`、`skills-lock.json`、`dist/`、`dist-installer/`、`Build-Product/`、私钥均被 gitignore

> **2026-08-07 修订说明**：本交接文档系从私有项目整库复制而来，git 状态与远程地址已按新仓库实际修订；推送时以本地历史覆盖了建仓自动生成的初始提交（其中的 Apache-2.0 LICENSE 已保留入库，README 以本项目为准）。

### 清理动作的实际状态（重要，未决事项）

用户已要求停止清理。当前实测：

| 项目 | 状态 | 说明 |
|---|---|---|
| `.tools/` | **存在，537 MB 完整** | 构建缓存（下载的组件），删除后下次构建自动重新下载（约 5-10 分钟）。删除命令当时报告已删，但实测仍在 |
| `.agents/` | **存在，16 MB，25 个技能完整** | 环境自动管理的技能库（来源 `heygen-com/hyperframes`），同上 |
| `skills-lock.json` | **存在** | 技能安装记录，同上 |
| `.claude/` | **部分清空** | 删除时 `find-skills` 目录访问被拒导致中断，技能文件内容已大部分被删，仅剩空壳目录；需进一步处理（恢复或彻底删除） |

> 说明：删除命令当时输出「.tools/.agents/skills-lock.json 已删除」，但事后检查文件仍在（可能被环境自动还原），该现象未查明，列为待办。

---

## 四、代码文件职责（逐个讲清楚）

### 源码与配置（必备，勿删）

| 文件 | 职责 |
|---|---|
| `main.go` | Go 启动器（GUI 子系统，无控制台）。读取 `config.json` → 首次启动把 `profile_seed/` 复制为 `profile/`（同时清理种子中的会话恢复数据）→ 带参启动 Chromium（`--user-data-dir` + `--load-extension`）。**2026-08-07 修改**：① 启动参数加入一批谷歌功能关闭开关（同步/后台联网/组件更新/崩溃上报/翻译/AI 等，见阶段四第 1 条）；② `applyCftPolicies()` 启动时确保 9 条 CfT 专用注册表策略生效（登录/同步/后台运行/安全浏览/泄露检测/搜索建议/网络预加载；缺失或值不对才写入、退出不删除、卸载由安装器清理）；③ 所有 `reg.exe` 子进程统一加 `CREATE_NO_WINDOW`（`hideConsole`）屏蔽 cmd 黑框；④ 默认扩展列表加入 `extensions/baidu-search`；⑤ 修复多扩展 `--load-extension` 合并（单值开关，逗号连接）；⑥ 新增 `coursethru.log` 滚动日志（2 MB 轮转）与严重错误日志自动打包（`crash-logs\` zip + 自动打开文件夹，见阶段五第 2 条）。 |
| `go.mod` | Go 模块定义（`coursethru/launcher`，go 1.26）。 |
| `build.ps1` | 一键构建：下载固定版本组件（直连失败自动回退系统代理）→ 校验/复用公钥（缺失即报错）→ 装配 ScriptCat（注入 key + 欢迎页补丁）→ 复制百度搜索扩展 → 编译启动器 → 生成/复用预置 profile → 写 `config.json`（默认扩展列表含 scriptcat + baidu-search）→ 清理产物残留（7.5 节）→ Inno Setup 打包。参数：`-SkipProfile`、`-NoNsis`。**注意：文件必须保持 UTF-8 BOM（PowerShell 5.1 中文脚本依赖）**。 |
| `extensions/baidu-search\manifest.json` | **2026-08-07 新增**。百度默认搜索引擎扩展（MV3，`chrome_settings_overrides.search_provider`），未托管机器上唯一可靠的默认搜索设置方式（sensitive 策略会被 Chrome 忽略）。 |
| `gen-profile.mjs` | CDP 驱动真实 Chromium 生成预置 profile：**直接写入 ScriptCat 存储预置 OCS（默认启用）**，开启开发者模式与 userScripts 开关，关闭→重启→自动验证。信号驱动（DOM 条件等待），无固定 sleep。**2026-08-07**：预置 OCS 时开启 ScriptCat 自动更新（`checkUpdate: true`，更新源为 GitHub 最新 Release 资产 URL）。由 `build.ps1` 调用。 |
| `extensions/ocs.user.js` | OCS 网课助手脚本（4.15.3，GitHub Release 最新原版、未改动），**随仓库入库**；自带官方「📥 更新模块」，并由 `gen-profile.mjs` 开启 ScriptCat 自动更新检查（双通道自动更新）。构建时复制进产物，由 `gen-profile.mjs` 预置到 ScriptCat 存储并默认启用。 |
| `installer.iss` | Inno Setup 安装脚本：把 `dist/` 内容装到 `{app}`，创建快捷方式，卸载时调用 `stop-browser.ps1`、删除应用目录，并在 `usPostUninstall` 阶段清理本程序写入的 CfT 企业策略（`DeleteCftPolicies`，常驻设计的硬性要求）。 |
| `stop-browser.ps1` | 卸载辅助：按路径关闭本程序启动的浏览器进程，不影响用户自己的 Chrome。 |
| `keys\scriptcat.key` | ScriptCat 扩展公钥（736 B，base64）。扩展 ID 由此确定，**缺失时构建直接报错**。 |
| `config.json.example` | `config.json` 字段参考：`defaultUrl`、`extraArgs`、`appName`、`extensions`。 |
| `version.txt` | 应用版本单一来源（`x.y.z`），完整构建自动 patch +1 并写回；构建时注入安装包与 `dist\version.txt`。**2026-08-07 新增**，方案见 `VERSION.md`。 |
| `.gitignore` | 忽略规则。**本轮修改**：新增 `/Build-Product/`。 |

### 文档

| 文件 | 职责 |
|---|---|
| `README.md` | 使用与构建文档（特性、目录结构、构建命令、常见问题）。已按 Course-Thru（课速通）重写。 |
| `VERSION.md` | 版本管理方案：`version.txt` 单一来源、完整构建 patch 自动递增、`-Version` 覆盖、远程同步步骤。**2026-08-07 新增**。 |
| `CONSOLE-POLICY-NOTES.md` | **2026-08-07 新增**。cmd 黑框屏蔽（`CREATE_NO_WINDOW`）与 CfT 企业策略生命周期（常驻 + 卸载清理）的交接说明，代码与设计取舍见该文。 |
| `AGENTS.md` | 贡献者指南（项目结构、构建/测试命令、代码风格、测试与提交约定、密钥安全）。**本轮新增**。 |
| `HANDOVER.md` | 本文档。 |

### 生成目录（非源码，均可重建）

| 目录/文件 | 职责 |
|---|---|
| `dist/` | 便携版构建输出（chrome、extensions、profile_seed、Course-Thru.exe、config.json）。 |
| `dist-installer/` | 安装版输出（`Course-Thru-<版本>-Setup.exe`，版本号由构建自动注入）。 |
| `Build-Product/` | 交付汇总：`portable/`（便携版完整目录）+ `Course-Thru-<版本>-Setup.exe`（安装版）。 |
| `.tools/` | 构建缓存：下载的 Chromium/Go/Inno Setup 压缩包与解压目录（约 537 MB）。 |
| `.agents/`、`.claude/`、`skills-lock.json` | 环境自动生成的技能库/配置，不属于本项目代码（gitignore 已注明）。 |
| `keys\scriptcat_private.pem` | 私钥备份（gitignore），勿删勿传。 |

---

## 五、关键机制

### 1. 首次启动流程（开箱即用）

1. 启动器检查 `profile/` 是否存在；不存在则从 `profile_seed/` 复制（种子已含 userScripts 开关 + OCS 脚本）。
2. 检查 `first_run.flag`；不存在则视为首次运行：带 `--remote-debugging-port=0` 启动，轮询 `profile/DevToolsActivePort`，通过 CDP HTTP 接口关闭 ScriptCat 欢迎页，然后写入标记文件。
3. 后续启动：不带调试参数，直接正常启动；用户数据持续写入 `profile/`，跨目录拷贝也有效（扩展 ID 恒定）。

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

### 5. 谷歌功能清理机制（2026-08-07）

1. **能用启动参数就绝不用策略**：同步、后台联网、组件更新、崩溃上报、翻译、AI 等功能都有命令行开关，已写死在 `main.go`（改动组件版本时需复核这些开关在对应源码中仍然存在；不存在的 feature 名会被 Chrome 静默忽略，无副作用）。
2. **只有注册表策略能做的**（CDP/参数均无法完成）：关浏览器登录入口（`BrowserSignin`）、关同步（`SyncDisabled`）、关后台运行（`BackgroundModeEnabled`）、关安全浏览（`SafeBrowsingProtectionLevel`）等 9 条，写入 `HKCU\Software\Policies\Google\Chrome for Testing`（CfT 专属路径，不影响日常 Chrome）。生命周期为**常驻**：启动时逐条查询、缺失或值不对才写入，退出不删除；卸载时由 installer.iss 整键清理。早期"每次启动写入、退出恢复"版本已废弃（异常退出残留、每次退出多 ~20 次注册表操作，均无必要）。
3. **sensitive 策略陷阱**：未加入域的机器上 Chrome 会过滤 sensitive 策略（`DefaultSearchProvider*`、`MetricsReportingEnabled`、`SafeBrowsingEnabled` 等），写了也无效——所以默认搜索引擎改用扩展实现，UMA 用启动参数在网络层关闭。
4. **默认搜索引擎用扩展而非策略**：`chrome_settings_overrides.search_provider` 是官方机制，unpacked 扩展直接生效，且设置页会标注「由扩展控制」，用户无法在设置里改回。

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

构建后把产物汇总到交付目录：

```powershell
Copy-Item -Path 'dist\*' -Destination 'Build-Product\portable' -Recurse -Force
Copy-Item -Path 'dist-installer\Course-Thru-*-Setup.exe' -Destination 'Build-Product' -Force
```

验证要点：首次启动生成 `profile/` 与 `first_run.flag`，且**只打开 1 个 `about:blank`**（无多余会话窗口）；任何启动都不出现 `docs.scriptcat.org` 相关页面（install_comple / changelog / open-dev）；扩展 ID 恒定（由 `keys\scriptcat.key` 公钥计算，不随目录变化）。

---

## 七、已知问题与待办

| 事项 | 状态 | 说明 |
|---|---|---|
| 阶段四改动提交 | ✅ 已完成 | 2026-08-07：`main.go`、`build.ps1` 修改 + `extensions/baidu-search/` 新增 + `extensions/ocs.user.js` 外部修改，已随 `bf66eb6` 一并提交并推送，本地与远程同步 |
| 版本号自动递增 | ✅ 已完成 | `version.txt` 单一来源；完整构建 patch 自动 +1、`-NoNsis` 复用、`-Version` 覆盖；安装包文件名与 AppVersion 带版本；方案见 `VERSION.md` |
| 严重错误日志打包 | ✅ 已完成 | `coursethru.log` 滚动日志（2 MB 轮转）；致命错误时自动打包 zip 到 `crash-logs\` 并打开文件夹，弹窗附 zip 路径；端到端实测通过 |
| OCS 脚本维护 | ✅ 已完成 | 2026-08-07：已替换为 GitHub Release 最新原版 4.15.3 并启用自动更新（脚本自带更新模块 + ScriptCat `checkUpdate: true`，更新源为 GitHub 最新 Release 资产）。后续升级：替换 `extensions/ocs.user.js` → 同步 `build.ps1` 顶部 `$OcsTag` → 重新生成 `profile_seed` |
| `.claude/` 清理中断 | ⚠️ 待处理 | `find-skills` 访问被拒，技能内容大部分已删、剩空壳目录；用户已暂停清理，需决定恢复或彻底删除 |
| `.tools/`、`.agents/`、`skills-lock.json` 是否清除 | ⚠️ 待用户决定 | 清理已叫停；`.tools` 为可重建缓存，`.agents`/`skills-lock.json` 由环境管理 |
| `gen-profile.mjs` 时序/流程 | ✅ 已修复 | 已改为信号驱动 + 直接存储注入（无服务器、无 UI 点击安装）；`profile_seed` 已用新流程重新生成并端到端验证（OCS 预置启用、开发者模式开启、无欢迎页、无扩展错误、跨路径可移植） |
| 组件版本升级 | 📋 待办 | 改 `build.ps1` 顶部版本号 + 重新生成 `profile_seed` |
| 默认网课平台 | 📋 待办 | `config.json` 的 `defaultUrl` 留空 |
| 推送 GitHub | ✅ 已完成 | `origin = https://github.com/IceFireIcer/Course-Thru.git`（新仓库），main 分支已推送（10 个提交，含阶段四/五全部改动），本地与远程一致 |
| 私钥安全备份 | 📋 建议 | 把 `keys\scriptcat_private.pem` 备份到仓库外安全位置 |
| 应用图标 | 💡 可选 | 启动器与安装包用默认图标 |
| 物理文件夹改名 | 💡 可选 | 磁盘目录仍为 `browserForLazy`（工作区根路径未动），需要时可手动改名为 `Course-Thru` |

---

## 八、接手建议（suggested skills）

- 无强制技能。下一步大概率是：按阶段六/第七节维护 OCS（替换 `extensions/ocs.user.js` → 更新 `$OcsTag` → 重新生成 `profile_seed`；脚本自带更新模块 + ScriptCat 自动更新双通道兜底）、按第六节命令重建/验证、或处理清理相关的未决事项（`.claude/`、`.tools/` 等）。
- 若需要排查浏览器/构建行为异常（如扩展加载失败、参数失效），可考虑 `diagnosing-bugs` 技能。
- 若后续产出视频类产物（如产品演示），仓库技能库 `.agents/skills` 下有 hyperframes 系列（`changelog-video`、`general-video` 等），按需选用。
