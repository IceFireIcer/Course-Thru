# Course-Thru（课速通）

基于 **Chromium for Testing** + **ScriptCat（脚本猫）** + **OCS 网课助手** 的 Windows 刷网课浏览器，**打开即用**，无需手动安装扩展和脚本。

只面向 **Windows 平台**。

## 特性

- 🧩 **预置 ScriptCat**：通过 `--load-extension` 免安装加载，注入固定 key 使扩展 ID 恒定
- 📜 **预置 OCS 网课助手 4.15.3**：脚本直接写入 ScriptCat 存储并**默认启用**，支持超星学习通、知到智慧树、职教云、智慧职教、中国大学MOOC、雨课堂等平台
- ⚡ **开箱即用**：预置 profile 已开启「开发者模式」与「允许运行用户脚本」，OCS 已就绪；首次启动不弹任何引导页/信任提示
- 🖥️ **默认最大化窗口**：每次启动都以最大化窗口打开（写死，不受首次启动限制约束）
- 🚀 **启动器**：独立开发的 Windows 程序，首次启动部署预置数据并带参启动浏览器
- 📦 **安装版**：Inno Setup 打包，下一步式安装 + 开始菜单/桌面快捷方式 + 卸载器
- 🏠 **内置主页**：`course-thru/` 本地主页随程序分发，启动即打开（`file://` 自包含，离线可用）；可在 `config.json` 里换成任意网址
- 🆕 **新标签页直达百度**：点「+」/ Ctrl+T 直接打开百度，全程无确认弹窗；从链接新开的标签页不受影响
- 🚪 **每次启动全新开始**：关闭会话恢复——每次启动前自动清理会话数据，上次的标签页不会恢复，异常退出也不弹「恢复页面？」气泡，始终从默认页打开
- 🛡️ **默认关闭谷歌功能**：同步、后台联网、组件更新、崩溃上报、翻译与 AI 功能均通过启动参数禁用；另有 9 条 CfT 专用注册表策略关闭登录/后台运行/安全浏览上报等，**只影响本程序，不影响用户日常 Chrome**
- 🔍 **默认搜索引擎为百度**：通过内置扩展设置，设置页标注「由扩展控制」
- 🧯 **错误日志自动打包**：程序遇到严重错误无法启动时，自动把日志打包为 zip 存到 `crash-logs\` 并打开文件夹，方便微信回传排查

## 使用

### 方式一：安装版（推荐给最终用户）

运行安装包（`Course-Thru-<版本>-Setup.exe`，文件名含版本号），安装完成后双击桌面快捷方式（或开始菜单 `Course-Thru`）即可。

打开支持的网课平台（如超星学习通 `chaoxing.com`），进入课程页面后 OCS 网课助手会自动运行。

### 方式二：便携版（开发/测试用）

`dist/` 目录是完整的便携目录，直接双击 `dist\Course-Thru.exe` 即可使用。

## 配置文件 `config.json`（默认页预留接口）

`config.json` 与启动器同目录，字段全部可选：

```json
{
  "defaultUrl": "",
  "extraArgs": [],
  "appName": "Course-Thru",
  "extensions": ["extensions/scriptcat", "extensions/baidu-search"]
}
```

| 字段 | 说明 |
| --- | --- |
| `defaultUrl` | **启动后默认打开的网址**。留空打开内置主页（`course-thru/index.html`）；填相对路径（如 `"homepage/index.html"`）则打开程序目录下对应本地网页；填完整网址（如 `"https://www.chaoxing.com/"`）则启动即打开网课平台 |
| `extraArgs` | 附加给 Chromium 的命令行参数数组，如 `["--disable-gpu"]` |
| `appName` | 应用名（暂用于错误提示） |
| `extensions` | 启动时加载的 unpacked 扩展目录（相对启动器目录） |

> 修改 `config.json` 后需**完全关闭浏览器再启动**才生效（Chromium 进程存在时二次启动会转发给已运行实例）。

## 目录结构

```
main.go / go.mod                # Go 启动器源码（GUI 子系统）
build.ps1                       # 一键构建：下载组件 → 注入 key → 装配 ScriptCat → 编译 → 打包
patch-branding.py               # 构建期替换语言包里的 "Chrome for Testing" 品牌字样与版权署名（幂等）
generate-assets.py              # 从 logo/logo.png 生成 assets\ 全套 logo 资源（幂等）
patch-logo.py                   # 构建期替换 Chromium pak 里的产品 logo 图片（内容识别，幂等）
patch-icons.py                  # 构建期替换 chrome.exe / chrome.dll / 启动器 PE 图标（幂等）
assets/                         # 生成的 logo 资源（app.ico / 向导图 / pak 内嵌 PNG / ScriptCat 图标）
logo/logo.png                   # 唯一 logo 源文件
version.txt                     # 版本号单一来源（完整构建自动递增）
gen-profile.mjs                 # CDP 生成预置 profile（直接写入 ScriptCat 存储预置 OCS，默认启用）
installer.iss                   # Inno Setup 安装脚本
stop-browser.ps1                # 卸载时关闭本程序浏览器进程
keys/scriptcat.key              # 扩展固定 key（勿删，删除会改变扩展 ID）
extensions/ocs.user.js          # OCS 网课助手脚本（本地维护，构建时打包进产物）
extensions/baidu-search/        # 百度内置扩展（默认搜索引擎 + 新标签页直达百度）
course-thru/                    # 内置主页（index.html + fonts/js/logo，全部相对路径，随程序分发）
third-party-licenses/           # 第三方开源许可证原文（OCS=MIT、ScriptCat=GPL v3，合规署名）
config.json.example             # 配置示例（默认页接口）

dist/                           # 便携发布目录（构建产物）
├── Course-Thru.exe             # 启动器
├── config.json                 # 配置（默认页接口）
├── version.txt                 # 当前版本号
├── coursthru.log               # 启动器滚动日志（2 MB 轮转）
├── crash-logs/                 # 严重错误时自动生成的日志 zip（首次出错时创建）
├── chrome/                     # Chromium for Testing
├── extensions/                 # ScriptCat + baidu-search + ocs.user.js
├── profile_seed/               # 预置 profile（开发者模式 + userScripts 开关 + OCS 已预置启用）
└── profile/                    # 运行时 profile（首次启动由启动器从 profile_seed 复制）
.tools/                         # 构建缓存（下载的组件）
dist-installer/                 # 安装包输出目录（Course-Thru-<版本>-Setup.exe）
```

## 从源码构建

需要：Windows + node.js + 网络（GitHub、npmmirror 可达；有系统代理时自动回退使用）。

```powershell
# 一键构建：下载组件 → 注入 key → 装配 ScriptCat → 编译启动器 → 打包安装版
powershell -ExecutionPolicy Bypass -File build.ps1
```

- 首次构建会下载 Chromium（约 160MB）与 Go SDK，后续构建自动复用 `.tools` 缓存
- 组件版本固定（Chromium 152、ScriptCat v1.4.0、OCS 4.15.3），保证可复现；OCS 脚本本地维护（`extensions/ocs.user.js`），不依赖 GitHub 下载
- 所依赖的开源组件许可证原文收录在 `third-party-licenses/`（OCS=MIT、ScriptCat=GPL v3），随仓库合规分发
- `-SkipProfile` 跳过预置 profile 生成（复用已有 `dist\profile_seed`）
- `-NoNsis` 跳过安装包（只产出便携 `dist`）
- `-Version x.y.z` 手动指定构建版本（默认完整构建 patch 自动 +1，`-NoNsis` 复用当前版本）
- 若本地 OCS 脚本的 `@version` 与 `build.ps1` 顶部 `$OcsTag` 不一致，构建会警告但不阻塞（升级 OCS 后请同步更新 `$OcsTag`）

## 技术说明

- **为什么用 Chromium for Testing 而非 Electron**：ScriptCat 依赖 `chrome.userScripts` API，Electron 不支持该 API（只支持 `chrome.scripting` 等子集），会导致脚本无法注入页面。Chromium（非 Chrome 品牌版）完全支持，且 `--load-extension` 命令行参数在 Chromium 上依然可用（Chrome 137 起仅 Google Chrome 品牌版移除了该参数）
- **为什么注入 key**：unpacked 扩展无 `key` 字段时 ID 由安装路径决定，路径一变脚本数据就丢了。注入固定 key 后 ID 恒定，预置数据可随 profile 移植
- **为什么预置 profile**：ScriptCat 的 userScripts 开关与脚本数据存在扩展的 `chrome.storage.local`（LevelDB），构建时用真实 Chromium 配置好后打包，用户首次启动复制即开箱即用
- **OCS 直接预置**：OCS 是 ScriptCat 的油猴脚本，生成 profile 时直接写入 ScriptCat 存储（`script:<uuid>` 元数据 + `scriptCode:<uuid>` 代码，`status:1` 默认启用），无需模拟点击安装，也不依赖网络
- **开发者模式默认开启**：生成 profile 时通过 CDP 点击 chrome://extensions 的真实开关并持久化，首次启动不弹「开启开发者模式」信任提示
- **首次启动只开一个页面**：启动打开内置主页 `course-thru/index.html`；生成流程的窗口会话数据已从种子中清理（三重保险：gen-profile、build.ps1、启动器），不会恢复出多余标签页
- **不能加 `--disable-extensions-except`**：该参数会触发 Chromium「先禁用全部扩展再重启进程」流程，首次启动会弹「加载扩展程序时候出错」并延迟出窗
- **默认搜索用扩展而非策略**：`DefaultSearchProvider*` 是 sensitive 策略，未加入域的机器上会被 Chrome 直接忽略；`chrome_settings_overrides.search_provider` 扩展机制在 unpacked 扩展上直接生效
- **多扩展必须逗号合并**：`--load-extension` 是单值开关，重复传多个只认最后一个，因此 ScriptCat 与百度扩展必须合并为一个参数值
- **品牌字样与版权署名靠构建期替换**：CDP 与企业策略都无法修改窗口标题模板、新标签页「自定义」按钮、设置「关于」页里的 "Chrome for Testing" 字样——这些字符串编译在 `locales\*.pak` 资源里。`patch-branding.py` 在 Chromium 解压后统一替换为 "Course-Thru 课速通"，并把 "Google LLC." 替换为 "IceFire_Icer."；`build.ps1` 还会替换 `ABOUT` 文件里的完整版权行。全部幂等可重复执行，升级 Chromium 版本后由构建自动重新打补丁
- **品牌 logo 靠构建期替换资源**：Chrome 图标/产品 logo 编译在 `chrome_*.pak`、`resources.pak` 与 chrome.exe / chrome.dll 的 PE 资源里，同样无法用命令行或策略修改。构建期用 `generate-assets.py`（从 `logo/logo.png` 生成全套资源）、`patch-logo.py`（内容识别替换 pak 内 PNG）与 `patch-icons.py`（重建资源段替换 PE 图标）统一换成品牌 logo；ScriptCat 工具栏图标与 Inno Setup 安装包图标/向导图也一并替换
- **只保留中英繁三语语言包**：构建时裁剪 Chromium `locales\*.pak`（保留 en-US / zh-CN / zh-TW，含性别变体）与 ScriptCat `_locales`（保留 en / zh_CN / zh_TW）。首选语言包缺失时 Chrome 自动回退 en-US、扩展回退 `default_locale`（en），程序不会报错；保留清单在 `build.ps1` 顶部的 `$KeepChromeLocales` / `$KeepExtLocales`

## 常见问题

**Q：如何添加其他油猴脚本？**
打开浏览器 → 点击工具栏脚本猫图标 → 脚本管理 → 导入，或直接访问脚本站安装。脚本会保存在 `profile/` 中。

**Q：如何更换默认打开的网课平台？**
编辑 `config.json` 的 `defaultUrl` 字段：填完整网址（如 `https://www.chaoxing.com/`）打开网课平台，填相对路径（如 `homepage/index.html`）打开本地网页，留空恢复内置主页。完全关闭浏览器后重启生效。

**Q：点「+」新建标签页为什么直接是百度？能改吗？**
内置扩展会监听新建标签页并把 `chrome://newtab` 导航到百度（不接管浏览器设置，因此不弹确认框）。想换目标页，改 `background.js` 里的 `BAIDU_URL` 后重新构建即可。

**Q：浏览器打不开 / 启动报错怎么办？**
启动器遇到严重错误时会自动把日志打包成 zip（`crash-logs\` 文件夹）并打开所在位置，把 zip 文件通过微信发给开发者即可定位问题。

**Q：默认搜索引擎是百度，能改回吗？**
默认搜索由内置百度扩展控制，设置页会标注「由扩展控制」，无法在设置里改回。

**Q：卸载后想保留账号/脚本数据？**
卸载会删除 `%LOCALAPPDATA%\Course-Thru\` 全部数据。如需保留，卸载前复制该目录备份。

## 许可证

本项目以 **GPL v3**（GNU General Public License v3）开源（见仓库根目录 `LICENSE`）。

随程序分发的第三方开源组件许可原文收录在 `third-party-licenses/`：
- **OCS 网课助手**：MIT，Copyright (c) 2022 enncy（`ocsjs-LICENSE.txt`）
- **ScriptCat（脚本猫）**：**GPL v3**，作者 CodFrm（`scriptcat-LICENSE.txt`）——与本项目同为 GPL v3，许可证完全兼容
