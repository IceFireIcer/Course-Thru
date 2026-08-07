# Course-Thru 版本管理方案

> 建立时间：2026-08-07。规则经交接会话确认：版本号自动递增 + 远程仓库同步。

## 单一来源

- 仓库根 `version.txt` 记录当前版本（格式 `x.y.z`），是唯一的事实来源。
- `installer.iss` 不再硬编码版本，由 `build.ps1` 通过 `/DMyAppVersion=` 注入。
- `dist\version.txt` 随便携版与安装包一起分发，为将来启动器 UI 显示版本、自动更新比较预留接口。

## 递增规则

| 构建方式 | 版本行为 |
|---|---|
| `build.ps1`（默认完整构建） | patch 自动 +1（如 1.0.0 → 1.0.1）并写回 `version.txt` |
| `build.ps1 -NoNsis`（便携调试） | 复用当前版本，不递增、不改写 `version.txt` |
| `build.ps1 -Version 1.1.0`（里程碑） | 手动覆盖本次版本，完整构建时写回 `version.txt` |

细节：

- 版本号在构建开始时确定；完整构建一旦开始就会消耗一个 patch（即使中途失败，下次构建继续递增，无害）。
- 大版本（major/minor）用 `-Version` 覆盖，日常迭代靠 patch 自动递增。
- `version.txt` 缺失或格式非法时回退默认 `1.0.0` 并警告。

## 版本出现在哪里

- 安装包文件名：`Course-Thru-{版本}-Setup.exe`（微信分发时一眼可辨新旧）。
- 控制面板「卸载程序」中的 AppVersion（由 `installer.iss` 的 `MyAppVersion` 注入）。
- `dist\version.txt`：便携版与安装后的程序目录均有。

## 远程同步

每次正式发版构建后，把 `version.txt` 的递增结果随代码一起提交并推送 `origin/main`：

```powershell
git add version.txt
git commit -m "chore: 版本号递增至 x.y.z"
git push origin main
```

未推送的本地递增会在下次构建时继续叠加，因此发版后请及时推送。

## 未来扩展（当前不做）

- 启动器 UI 显示版本：读程序目录 `version.txt`，或编译时用 `-ldflags "-X main.version="` 注入 Go 变量。
- 自动更新：版本号按语义化比较（`x.y.z` 逐段比较），GitHub Releases 的 tag 与 `version.txt` 对齐。
