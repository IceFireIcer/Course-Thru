# 交接文档

> 生成时间：2026-08-05
> 项目：BrowserForLazy — 基于 Chromium + ScriptCat + OCS 的刷网课浏览器（Windows）
> 本文件是本次开发的完整交接说明，接手人应先读 README.md 了解使用方式，再读本文了解来龙去脉。

---

## 一、本次对话做了什么

从零搭建并交付了一个**开箱即用的刷网课浏览器**。核心思路：不自己实现刷课逻辑，而是把成熟的 **ScriptCat（脚本猫）** 和 **OCS 网课助手** 预置进 Chromium，用户打开浏览器即自动加载、自动可用。

### 主要工作流程

1. **技术选型调研**（关键决策）
   - 确认 Electron 方案**不可行**：ScriptCat 依赖 `chrome.userScripts` API，而 Electron 不支持该 API（只支持 `chrome.scripting` 等子集），会导致脚本无法注入页面
   - 确认 **Chromium for Testing** 可行：完全支持 MV3 `userScripts` API，且 `--load-extension` 命令行加载扩展在 Chromium 上依然可用（Chrome 137 起仅 Google Chrome 品牌版移除了该参数）
   - 确认 NSIS 官方二进制只托管在 SourceForge（国内不可达），经用户确认**改用 Inno Setup**（官网/GitHub 可达，功能等价）

2. **核心机制验证**（全部实测跑通）
   - ScriptCat v1.4.0 免安装加载
   - 注入固定 RSA key 使扩展 ID 恒定，解决"unpacked 扩展 ID 随路径变化导致数据丢失"问题
   - 通过 CDP 自动开启「允许运行用户脚本」开关并确认持久化
   - 通过正规安装流程安装 OCS 脚本
   - 预置 profile（LevelDB 数据）跨目录复制后脚本与开关状态完整保留

3. **开发与构建**
   - Go 启动器（首次部署预置 profile、带参启动浏览器）
   - 一键构建脚本 build.ps1
   - CDP 自动化 profile 生成器 gen-profile.mjs
   - Inno Setup 安装脚本 + 卸载辅助脚本
   - 安装版 / 便携版双形态产物

4. **排障**
   - 修复「加载扩展程序时候出错」：移除 `--disable-extensions-except`（它触发 Chromium 先禁用全部扩展再重启进程的流程）
   - 修复未开 `userScripts` 开关导致 ScriptCat 后台崩溃报错（通过预置已开开关的 profile 根治）
   - 修复 build.ps1 迁移根目录后的 `$Root` 路径 bug

5. **git 整理**
   - 清除无用代码（验证临时目录、重复文件）
   - 核心源码扁平化到根目录
   - 初始化 git 仓库，写好 .gitignore（构建产物/缓存/环境目录/私钥全部忽略）
   - 首次提交并修正提交作者身份为 IceFireIcer

---

## 二、项目当前状态

### 产物（已构建、已验证可用）

| 产物 | 位置 | 说明 |
|---|---|---|
| **安装版** | `dist-installer\BrowserForLazySetup.exe`（约 148 MB） | Inno Setup 打包，安装到 `%LOCALAPPDATA%\BrowserForLazy`，含快捷方式与卸载器 |
| **便携版** | `dist\` | 双击 `BrowserForLazy.exe` 即用 |

### 组件版本（build.ps1 中固定，保证可复现）

- Chromium for Testing **152.0.7977.13**（npmmirror 镜像下载）
- ScriptCat（脚本猫）**v1.4.0**（GitHub Release）
- OCS 网课助手 **4.15.3**（GitHub Release，`ocs.user.js`）

### 扩展 ID（关键常量）

`hodgdaljmnbiliahlpcjcpiphnkbmfff` —— 由注入的固定 key（`keys/scriptcat.key` 公钥）计算得出。**勿删 key 文件**，否则扩展 ID 变化、预置数据失效。

### git 状态

- main 分支，1 个提交 `f0423da`，工作区干净，**未推送 GitHub**
- 提交身份：`IceFireIcer <icefire_icer@outlook.com>`（仓库级）
- 入库文件（10 个）：main.go、go.mod、build.ps1、gen-profile.mjs、installer.iss、stop-browser.ps1、keys/scriptcat.key、config.json.example、README.md、.gitignore、HANDOVER.md
- 忽略项：`dist/`、`dist-installer/`、`.tools/`、`.claude/`、`.agents/`、`skills-lock.json`、`keys/scriptcat_private.pem`

### 目录结构（根目录扁平化）

```
browserForLazy/
├── main.go / go.mod          # Go 启动器源码（GUI 子系统，无控制台）
├── build.ps1                 # 一键构建：下载组件→注入 key→编译→生成 profile→打安装包
├── gen-profile.mjs           # CDP 自动化生成预置 profile（可选工具）
├── installer.iss             # Inno Setup 安装脚本
├── stop-browser.ps1          # 卸载时按路径关闭本程序的浏览器进程
├── keys/scriptcat.key        # 扩展公钥（入库，固定扩展 ID）
├── config.json.example       # 配置示例（默认页接口）
├── README.md                 # 使用与构建文档
└── HANDOVER.md               # 本交接文档
```

---

## 三、需求完成情况对照

| 原始需求 | 状态 | 说明 |
|---|---|---|
| 基于 Chromium 做浏览器 | ✅ 完成 | Chromium for Testing，完全支持 ScriptCat 所需的 MV3 API |
| 预置 ScriptCat 脚本猫 | ✅ 完成 | `--load-extension` 免安装加载，注入 key 固定 ID |
| 预置 OCS 网课助手 | ✅ 完成 | 已安装于脚本猫并注册生效（4.15.3，覆盖超星/智慧树/职教云/MOOC/雨课堂） |
| 打开就预加载/开箱即用 | ✅ 完成 | 预置 profile 已开「允许运行用户脚本」+ 装好 OCS，首次启动自动部署 |
| 只做 Windows 平台 | ✅ 完成 | 面向 win64，已验证 Windows 11 |
| 安装版发布 | ✅ 完成 | Inno Setup 安装包（原定 NSIS，因源不可达经确认改用） |
| 独立启动器程序 | ✅ 完成 | Go 编译单 exe，无依赖 |
| 默认页预留接口 | ✅ 完成 | `config.json` 的 `defaultUrl` 字段，改后重启生效 |

**整体完成度：约 95%。** 核心链路（安装 → 启动 → 自动带脚本 → 刷课）全部验证通过。

---

## 四、关键技术决策记录（接手人必读）

1. **为什么不是 Electron**：Electron 对 MV3 扩展支持不完整，缺 `chrome.userScripts`。这是硬性限制，ScriptCat 脚本注入依赖它。
2. **为什么是 Chromium 而非 Chrome**：Chrome 137+ 移除了 `--load-extension`；开源 Chromium 不受影响。
3. **为什么注入 key**：unpacked 扩展无 key 时 ID 由安装路径决定，路径一变脚本数据即丢失。注入固定 key 后 ID 恒定，预置数据可随 profile 移植。
4. **为什么预置 profile**：ScriptCat 的 userScripts 开关与脚本数据存在扩展的 `chrome.storage.local`（LevelDB）。构建时用真实 Chromium 配好，打包为 `profile_seed`，用户首次启动由启动器复制到 `profile/`。
5. **为什么不能用 `--disable-extensions-except`**：它触发 Chromium「先禁用全部扩展再重启进程」流程，首次启动弹「加载扩展程序时候出错」并延迟出窗。只用 `--load-extension` 即可。
6. **为什么 NSIS 换成 Inno Setup**：NSIS 官方二进制仅 SourceForge 托管，当前网络不可达（winget、conda 镜像均无果）。Inno Setup 功能等价。

---

## 五、已知问题与待办

| 事项 | 状态 | 说明 |
|---|---|---|
| `gen-profile.mjs` 自动化生成 profile 有时序不稳定的已知问题 | ⚠️ 已知 | 曾因 chrome://extensions 页面加载时序导致「扩展卡片未找到」；已加 SW 等待与轮询但仍建议重跑前人工核对。当前 `dist/profile_seed` 是手工（验证用 profile_c）生成并验证可用的，**功能完整** |
| 组件版本升级 | 📋 待办 | 升级 Chromium/ScriptCat/OCS 需改 `build.ps1` 顶部版本号，并重新生成 `profile_seed` |
| 默认网课平台 | 📋 待办 | `config.json` 的 `defaultUrl` 留空，用户自行填写或告知后写入 |
| 推送 GitHub | 📋 待办 | git 已就绪（main 分支），用户决定后 `git push`；需先配置远端地址 |
| 应用图标 | 💡 可选 | 当前启动器与安装包用默认图标，可后续替换 |

---

## 六、如何继续开发

```powershell
# 完整一键构建（含安装包）
powershell -ExecutionPolicy Bypass -File build.ps1

# 只构建便携版
powershell -ExecutionPolicy Bypass -File build.ps1 -NoNsis

# 单独重新生成预置 profile（可选，需 Chromium 环境可达）
node gen-profile.mjs --chromium "dist\chrome\chrome.exe" --ext "dist\extensions\scriptcat" --profile ".tools\profile-tmp" --ocs ".tools\ocs.user.js" --port 9333
# 然后将 .tools\profile-tmp 中 Local State + Default 复制到 dist\profile_seed
```

- 修改默认页：编辑安装目录的 `config.json` 的 `defaultUrl`，完全关闭浏览器后重启
- 添加油猴脚本：浏览器内点脚本猫图标 → 脚本管理 → 导入；数据保存在 `profile/`
- 修改安装行为：编辑 `installer.iss` 后重新运行 `build.ps1`
