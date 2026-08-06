# Course-Thru（课速通）交接文档（更新版）

> 更新时间：2026-08-06（第三阶段交接：改名上线与首次推送）
> 项目：Course-Thru（课速通）— 基于 Chromium + ScriptCat + OCS 的刷网课浏览器（Windows）
> 阅读顺序：先读 README.md 了解使用方式，再读本文了解来龙去脉与当前状态。

---

## 一、项目概述

开箱即用的 Windows 刷网课浏览器。核心思路：**不自己实现刷课逻辑**，而是把成熟的 ScriptCat（脚本猫）扩展和 OCS 网课助手脚本预置进 Chromium，用户打开浏览器即自动加载、自动可用。

只面向 Windows 平台。

---

## 二、三阶段工作回顾

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
6. **OCS 本地化**：不再从 GitHub Release 下载，`ocs.user.js`（4.15.3）入库为 `extensions/ocs.user.js`，构建时直接复制进产物（`dist\extensions\ocs.user.js`），升级只需替换该文件并核对 `build.ps1` 顶部的 `$OcsTag`。
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

---

## 三、项目当前状态（2026-08-06 实测）

### 构建产物

| 产物 | 位置 | 说明 |
|---|---|---|
| 便携版 | `Build-Product\portable\`（约 466 MB） | **干净出厂态**（无用户 profile 数据），首次启动自动生成 `profile/` 与 `first_run.flag` |
| 安装版 | `Build-Product\Course-ThruSetup.exe`（约 150 MB） | Inno Setup 安装包，安装到 `%LOCALAPPDATA%\Course-Thru` |
| 工作输出 | `dist/`（约 466 MB）、`dist-installer/` | `build.ps1` 的标准输出目录，内容与 Build-Product 一致 |

### 组件版本（build.ps1 顶部固定，保证可复现）

- Chromium for Testing **152.0.7977.13**
- ScriptCat（脚本猫）**v1.4.0**
- OCS 网课助手 **4.15.3**

### 扩展 ID 与密钥

- 扩展 ID：`hodgdaljmnbiliahlpcjcpiphnkbmfff`（由公钥计算，恒定）
- `keys\scriptcat.key`：公钥，**已入库，必备**，删除会改变 ID 并使既有用户数据失效
- `keys\scriptcat_private.pem`：私钥，gitignore，**仅本地备份**；unpacked 加载不需要它，只在将来 CRX 签名/商店上架时需要

### git 状态

- main 分支，3 个提交（`f0423da` 初始搭建、`42a45c4` 交接文档、`df785ab` 改名与重构），**已推送 GitHub**
- 远程：`origin = https://github.com/IceFireIcer/Course-Thru-NBCC.git`，`main` 已跟踪 `origin/main`，**工作区干净**
- 提交身份：`IceFireIcer <icefire_icer@outlook.com>`
- `.tools/`、`.agents/`、`.claude/`、`skills-lock.json`、`dist/`、`dist-installer/`、`Build-Product/`、私钥均被 gitignore

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
| `main.go` | Go 启动器（GUI 子系统，无控制台）。读取 `config.json` → 首次启动把 `profile_seed/` 复制为 `profile/`（同时清理种子中的会话恢复数据）→ 带参启动 Chromium（`--user-data-dir` + `--load-extension`）。**本轮修改**：首次启动写 `first_run.flag` 并通过 CDP 自动关闭 ScriptCat 欢迎页；后续启动不带调试参数。 |
| `go.mod` | Go 模块定义（`coursethru/launcher`，go 1.26）。 |
| `build.ps1` | 一键构建：下载固定版本组件（直连失败自动回退系统代理）→ 校验/复用公钥（缺失即报错）→ 装配 ScriptCat（注入 key + 欢迎页补丁）→ 编译启动器 → 生成/复用预置 profile → 写 `config.json` → 清理产物残留（7.5 节）→ Inno Setup 打包。参数：`-SkipProfile`、`-NoNsis`。**注意：文件必须保持 UTF-8 BOM（PowerShell 5.1 中文脚本依赖）**。 |
| `gen-profile.mjs` | CDP 驱动真实 Chromium 生成预置 profile：**直接写入 ScriptCat 存储预置 OCS（默认启用）**，开启开发者模式与 userScripts 开关，关闭→重启→自动验证。信号驱动（DOM 条件等待），无固定 sleep。由 `build.ps1` 调用。 |
| `extensions/ocs.user.js` | OCS 网课助手脚本（4.15.3），**本地维护、随仓库入库**；构建时复制进产物，由 `gen-profile.mjs` 预置到 ScriptCat 存储并默认启用。 |
| `installer.iss` | Inno Setup 安装脚本：把 `dist/` 内容装到 `{app}`，创建快捷方式，卸载时调用 `stop-browser.ps1` 并删除应用目录。 |
| `stop-browser.ps1` | 卸载辅助：按路径关闭本程序启动的浏览器进程，不影响用户自己的 Chrome。 |
| `keys\scriptcat.key` | ScriptCat 扩展公钥（736 B，base64）。扩展 ID 由此确定，**缺失时构建直接报错**。 |
| `config.json.example` | `config.json` 字段参考：`defaultUrl`、`extraArgs`、`appName`、`extensions`。 |
| `.gitignore` | 忽略规则。**本轮修改**：新增 `/Build-Product/`。 |

### 文档

| 文件 | 职责 |
|---|---|
| `README.md` | 使用与构建文档（特性、目录结构、构建命令、常见问题）。已按 Course-Thru（课速通）重写。 |
| `AGENTS.md` | 贡献者指南（项目结构、构建/测试命令、代码风格、测试与提交约定、密钥安全）。**本轮新增**。 |
| `HANDOVER.md` | 本文档。 |

### 生成目录（非源码，均可重建）

| 目录/文件 | 职责 |
|---|---|
| `dist/` | 便携版构建输出（chrome、extensions、profile_seed、Course-Thru.exe、config.json）。 |
| `dist-installer/` | 安装版输出（Course-ThruSetup.exe）。 |
| `Build-Product/` | 交付汇总：`portable/`（便携版完整目录）+ `Course-ThruSetup.exe`（安装版）。 |
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
Copy-Item -LiteralPath 'dist-installer\Course-ThruSetup.exe' -Destination 'Build-Product\Course-ThruSetup.exe' -Force
```

验证要点：首次启动生成 `profile/` 与 `first_run.flag`，且**只打开 1 个 `about:blank`**（无多余会话窗口）；任何启动都不出现 `docs.scriptcat.org` 相关页面（install_comple / changelog / open-dev）；扩展 ID 保持 `hodgdaljmnbiliahlpcjcpiphnkbmfff`。

---

## 七、已知问题与待办

| 事项 | 状态 | 说明 |
|---|---|---|
| `.claude/` 清理中断 | ⚠️ 待处理 | `find-skills` 访问被拒，技能内容大部分已删、剩空壳目录；用户已暂停清理，需决定恢复或彻底删除 |
| `.tools/`、`.agents/`、`skills-lock.json` 是否清除 | ⚠️ 待用户决定 | 清理已叫停；`.tools` 为可重建缓存，`.agents`/`skills-lock.json` 由环境管理 |
| `gen-profile.mjs` 时序/流程 | ✅ 已修复 | 已改为信号驱动 + 直接存储注入（无服务器、无 UI 点击安装）；`profile_seed` 已用新流程重新生成并端到端验证（OCS 预置启用、开发者模式开启、无欢迎页、无扩展错误、跨路径可移植） |
| 组件版本升级 | 📋 待办 | 改 `build.ps1` 顶部版本号 + 重新生成 `profile_seed` |
| 默认网课平台 | 📋 待办 | `config.json` 的 `defaultUrl` 留空 |
| 推送 GitHub | ✅ 已完成 | `origin = https://github.com/IceFireIcer/Course-Thru-NBCC.git`，main 分支已推送（3 个提交） |
| 私钥安全备份 | 📋 建议 | 把 `keys\scriptcat_private.pem` 备份到仓库外安全位置 |
| 应用图标 | 💡 可选 | 启动器与安装包用默认图标 |
| 物理文件夹改名 | 💡 可选 | 磁盘目录仍为 `browserForLazy`（工作区根路径未动），需要时可手动改名为 `Course-Thru` |
