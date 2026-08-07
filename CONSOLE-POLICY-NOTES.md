# 开放版课速通：cmd 窗口屏蔽与 CfT 企业策略（交接说明）

> 本文写给负责「开放版课速通」的 AI / 开发者。说明本项目如何做到两件事：
> 1. 屏蔽 GUI 启动器拉起控制台子进程时的 cmd 黑框；
> 2. 管理 Chrome for Testing（CfT）企业策略的写入与清理。
> 代码可以直接复制，改动前请先读一遍下面的设计取舍。

## 1. cmd 黑框从哪来

启动器用 Go 编译为 **GUI 子系统**（`-ldflags "-H=windowsgui"`），自身没有控制台。但它需要
通过 `reg.exe` 读写注册表企业策略。`reg.exe` 是**控制台程序**：从没有控制台的 GUI 父进程
拉起它时，Windows 默认会给子进程分配一个**可见的控制台窗口**，表现为启动/退出时
一闪而过的多个 cmd 黑框（本项目启动约 18 次 reg 调用、旧版退出恢复约 20 次）。

结论：这些窗口纯属副产物，功能上完全不需要，必须屏蔽。

## 2. 屏蔽方法：CREATE_NO_WINDOW

给子进程加 `CREATE_NO_WINDOW`（`0x08000000`）标志：子进程控制台照常工作，但**不创建可见窗口**。

Go 侧封装（main.go，本项目实测代码）：

```go
// hideConsole 让子进程不创建/不显示控制台窗口。
// GUI 子系统启动器拉起 reg.exe 等控制台程序时，Windows 默认会给子进程分配
// 新的控制台窗口（一闪而过的 cmd 黑框）；加 CREATE_NO_WINDOW 后子进程
// 不创建可见控制台，彻底消除弹窗。
func hideConsole(cmd *exec.Cmd) *exec.Cmd {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000} // CREATE_NO_WINDOW
	return cmd
}
```

使用方式：所有 `reg` 调用都包一层 `hideConsole(...)`；`explorer.exe` 等 GUI 程序本身
不会弹控制台，包了也无害。

其他语言的等价做法：

- C#：`ProcessStartInfo.CreateNoWindow = true`（配合 `UseShellExecute = false`）。
- C++：`CreateProcess` 传 `CREATE_NO_WINDOW` 标志。

**注意**：`CREATE_NO_WINDOW` 只是不显示窗口，控制台会话仍然存在——`conhost.exe` 进程
可能仍会出现（隐形控制台），所以不要用"有没有 conhost 进程"判断是否生效，要用
"有没有可见窗口"（如 conhost 的 `MainWindowHandle != 0`）或直接人工肉眼确认。

## 3. CfT 企业策略

### 3.1 策略是什么

- 路径：`HKCU\Software\Policies\Google\Chrome for Testing`
  （CfT 专属路径；普通 Chrome 是 `Software\Policies\Google\Chrome`，**互不影响**）。
- 用户级策略：当前 Windows 账户下**所有** CfT 浏览器都会读到，包括同账户下其他程序拉起的 CfT。
- 全部为 REG_DWORD、非 sensitive 策略，未加域机器同样生效。

9 条策略：

| 策略 | 值 | 作用 |
| --- | --- | --- |
| `BrowserSignin` | 0 | 禁用谷歌账号登录入口 |
| `SyncDisabled` | 1 | 禁用谷歌同步 |
| `BackgroundModeEnabled` | 0 | 关闭"关闭浏览器后继续运行后台应用" |
| `SafeBrowsingProtectionLevel` | 0 | 关闭安全浏览（副作用：不拦截恶意网站） |
| `SafeBrowsingExtendedReportingEnabled` | 0 | 关闭安全浏览增强报告 |
| `SafeBrowsingSurveysEnabled` | 0 | 关闭安全浏览调查问卷 |
| `PasswordLeakDetectionEnabled` | 0 | 关闭密码泄露检测（哈希不再发谷歌） |
| `SearchSuggestEnabled` | 0 | 关闭地址栏搜索建议 |
| `NetworkPredictionOptions` | 2 | 关闭网络预加载/预连接 |

### 3.2 生命周期（2026-08-07 定稿）

当前设计（**折中方案**）：

1. **启动时**：逐条 `reg query`，缺失或值不对才 `reg add`；已生效的策略跳过，平时启动开销极小。
2. **退出时**：**不删除**，策略常驻注册表（保证下次启动一定生效）。
3. **卸载时**：由安装器（installer.iss）在 `usPostUninstall` 删除整键，避免残留。

历史：早期是"每次启动写入、退出删除并还原旧值"。后来评估认为没必要——单用途浏览器
的策略本来就该常驻，每次启动写、退出删属于多余动作。代价是**同账户下其他 CfT 浏览器
也会永久受这 9 条策略影响**，因此"卸载必须清理"是这套设计的硬性要求，不能省。

写入失败不阻塞启动（策略是加固项，不应影响主流程）。

### 3.3 代码位置

main.go：

```go
const cftPolicyKey = `HKCU\Software\Policies\Google\Chrome for Testing`

var cftPolicies = []struct{ name, value string }{
	{"BrowserSignin", "0"},
	{"SyncDisabled", "1"},
	{"BackgroundModeEnabled", "0"},
	{"SafeBrowsingProtectionLevel", "0"},
	{"SafeBrowsingExtendedReportingEnabled", "0"},
	{"SafeBrowsingSurveysEnabled", "0"},
	{"PasswordLeakDetectionEnabled", "0"},
	{"SearchSuggestEnabled", "0"},
	{"NetworkPredictionOptions", "2"},
}

// applyCftPolicies 确保 CfT 企业策略已写入：逐条查询，缺失或值不对才写入，
// 已生效的策略跳过。退出时不删除策略；卸载时由 installer.iss 负责清理。
func applyCftPolicies() bool {
	ok := true
	for _, p := range cftPolicies {
		old := ""
		if out, err := hideConsole(exec.Command("reg", "query", cftPolicyKey, "/v", p.name)).CombinedOutput(); err == nil {
			old = parseRegValue(string(out), p.name)
		}
		// 已存在且值正确：跳过写入
		if old != "" && regValueEquals(old, p.value) {
			continue
		}
		if err := hideConsole(exec.Command("reg", "add", cftPolicyKey, "/v", p.name, "/t", "REG_DWORD", "/d", p.value, "/f")).Run(); err != nil {
			ok = false
		}
	}
	return ok
}
```

主流程在启动浏览器前调用：

```go
if applyCftPolicies() {
	logf("已确保 CfT 企业策略生效（缺失或值不对时写入，退出不删除）")
} else {
	logf("写入 CfT 企业策略失败（不影响主流程）")
}
```

installer.iss（卸载清理，Inno Setup 6.x）：

```pascal
// 清理本程序写入的 CfT 企业策略（常驻策略，卸载时必须删除，
// 否则残留会影响同账户下其他 Chrome for Testing 浏览器）
procedure DeleteCftPolicies();
var
  Key: string;
begin
  Key := 'Software\Policies\Google\Chrome for Testing';
  RegDeleteValue(HKCU, Key, 'BrowserSignin');
  RegDeleteValue(HKCU, Key, 'SyncDisabled');
  RegDeleteValue(HKCU, Key, 'BackgroundModeEnabled');
  RegDeleteValue(HKCU, Key, 'SafeBrowsingProtectionLevel');
  RegDeleteValue(HKCU, Key, 'SafeBrowsingExtendedReportingEnabled');
  RegDeleteValue(HKCU, Key, 'SafeBrowsingSurveysEnabled');
  RegDeleteValue(HKCU, Key, 'PasswordLeakDetectionEnabled');
  RegDeleteValue(HKCU, Key, 'SearchSuggestEnabled');
  RegDeleteValue(HKCU, Key, 'NetworkPredictionOptions');
  RegDeleteKeyIncludingSubkeys(HKCU, Key);
end;
```

在 `CurUninstallStepChanged` 的 `usPostUninstall` 阶段调用 `DeleteCftPolicies();`。

## 4. 验证清单

1. 启动后：`reg query "HKCU\Software\Policies\Google\Chrome for Testing"` 应列出 9 条 REG_DWORD。
2. 关闭浏览器后：键**仍在**（常驻，符合设计，不再是旧版的"退出删除"）。
3. 启动/关闭全程：无可见 cmd 黑框（可用"新增 conhost 的 MainWindowHandle 是否非 0"辅助判断）。
4. 卸载后：键被删除，注册表恢复干净。
5. 普通 Chrome 不受影响：策略路径不同。

## 5. 容易踩的坑

- 改了策略集合时，main.go 的 `cftPolicies` 表和 installer.iss 的 `DeleteCftPolicies` **要同步改**。
- 以后新增任何控制台子进程（curl、powershell 等）同样要包 `hideConsole`，否则黑框复发。
- 不要退回到"退出删除+还原旧值"：与常驻设计矛盾，且每次退出多 20 次注册表操作。
- 如果开放版不需要这层策略，删除 `applyCftPolicies()` 调用和 installer.iss 的清理即可，
  但注意这会让 CfT 浏览器恢复谷歌登录/同步等行为。
