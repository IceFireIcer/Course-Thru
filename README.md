# BrowserForLazy 刷网课浏览器

基于 **Chromium for Testing** + **ScriptCat（脚本猫）** 的刷网课浏览器。预置了 ScriptCat 扩展和 **OCS 网课助手** 脚本，**打开即用**，无需手动安装扩展和脚本。

只面向 **Windows 平台**。

## 特性

- 🧩 **预置 ScriptCat**：通过 `--load-extension` 免安装加载，扩展 ID 固定（注入独立 key），并已开启「允许运行用户脚本」
- 📜 **预置 OCS 网课助手 4.15.3**：支持超星学习通、知到智慧树、职教云、智慧职教、中国大学MOOC、雨课堂等平台的自动刷课
- ⚡ **开箱即用**：预置 profile 已开启 `userScripts` 开关、已安装 OCS 脚本，首次启动自动部署
- 🚀 **启动器**：独立开发的 Windows 程序，负责首次部署预置数据并带参启动浏览器
- 📦 **安装版**：Inno Setup 打包，下一步式安装 + 开始菜单/桌面快捷方式 + 卸载器

## 使用

### 方式一：安装版（推荐给最终用户）

运行 `BrowserForLazySetup.exe`，安装完成后双击桌面快捷方式（或开始菜单 `BrowserForLazy`）即可。

打开支持的网课平台（如超星学习通 `chaoxing.com`），进入课程页面后 OCS 网课助手会自动运行。

### 方式二：便携版（开发/测试用）

`dist/` 目录是完整的便携目录，直接双击 `dist\BrowserForLazy.exe` 即可使用。

## 配置文件 `config.json`（默认页预留接口）

`config.json` 与启动器同目录，字段全部可选：

```json
{
  "defaultUrl": "",
  "extraArgs": [],
  "appName": "BrowserForLazy",
  "extensions": ["extensions/scriptcat"]
}
```

| 字段 | 说明 |
| --- | --- |
| `defaultUrl` | **启动后默认打开的网址**。留空打开空白页，填入如 `"https://www.chaoxing.com/"` 则启动即打开网课平台 |
| `extraArgs` | 附加给 Chromium 的命令行参数数组，如 `["--disable-gpu"]` |
| `appName` | 应用名（暂用于错误提示） |
| `extensions` | 启动时加载的 unpacked 扩展目录（相对启动器目录） |

> 修改 `config.json` 后需**完全关闭浏览器再启动**才生效（Chromium 进程存在时二次启动会转发给已运行实例）。

## 目录结构

```
dist/                           # 便携发布目录（构建产物）
├── BrowserForLazy.exe          # 启动器
├── config.json                 # 配置（默认页接口）
├── chrome/                     # Chromium for Testing
├── extensions/scriptcat/       # ScriptCat 扩展（注入固定 key）
├── profile_seed/               # 预置 profile（含 userScripts 开关 + OCS 脚本）
└── profile/                    # 运行时 profile（首次启动由启动器从 profile_seed 复制）
src/
├── launcher/                   # Go 启动器源码
├── build/
│   ├── build.ps1               # 一键构建脚本
│   ├── installer.iss           # Inno Setup 安装脚本
│   ├── stop-browser.ps1        # 卸载时关闭本程序浏览器进程
│   └── keys/scriptcat.key      # 扩展固定 key（勿删，删除会改变扩展 ID）
└── tools/
    └── gen-profile.mjs         # CDP 自动化生成预置 profile
.tools/                         # 构建缓存（下载的组件）
dist-installer/                 # 安装包输出目录
```

## 从源码构建

需要：Windows + node.js + 网络（GitHub、npmmirror 可达）。

```powershell
# 一键构建：下载组件 → 注入 key → 编译启动器 → 生成预置 profile → 打包安装版
powershell -ExecutionPolicy Bypass -File src\build\build.ps1
```

- 首次构建会下载 Chromium（约 160MB）与 Go SDK，后续构建自动复用 `.tools` 缓存
- 组件版本固定（Chromium 152、ScriptCat v1.4.0、OCS 4.15.3），保证可复现
- `-SkipProfile` 跳过预置 profile 生成（复用已有 `dist\profile_seed`）
- `-NoNsis` 跳过安装包（只产出便携 `dist`）

## 技术说明

- **为什么用 Chromium for Testing 而非 Electron**：ScriptCat 依赖 `chrome.userScripts` API，Electron 不支持该 API（只支持 `chrome.scripting` 等子集），会导致脚本无法注入。Chromium（非 Chrome 品牌版）完全支持，且 `--load-extension` 命令行参数在 Chromium 上依然可用（Chrome 137 起仅 Google Chrome 品牌版移除了该参数）
- **为什么注入 key**：unpacked 扩展无 `key` 字段时 ID 由安装路径决定，路径一变脚本数据就丢了。注入固定 key 后 ID 恒定（`hodgdaljmnbiliahlpcjcpiphnkbmfff`），预置数据可随 profile 移植
- **为什么预置 profile**：ScriptCat 的 userScripts 开关与脚本数据存在扩展的 `chrome.storage.local`（LevelDB），构建时用真实 Chromium 配置好后打包，用户首次启动复制即开箱即用
- **不能加 `--disable-extensions-except`**：该参数会触发 Chromium「先禁用全部扩展再重启进程」流程，首次启动会弹「加载扩展程序时候出错」并延迟出窗

## 常见问题

**Q：如何添加其他油猴脚本？**
打开浏览器 → 点击工具栏脚本猫图标 → 脚本管理 → 导入，或直接访问脚本站安装。脚本会保存在 `profile/` 中。

**Q：如何更换默认打开的网课平台？**
编辑 `config.json` 的 `defaultUrl` 字段为对应平台地址，完全关闭浏览器后重启。

**Q：卸载后想保留账号/脚本数据？**
卸载会删除 `%LOCALAPPDATA%\BrowserForLazy\` 全部数据。如需保留，卸载前复制该目录备份。
