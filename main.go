// Course-Thru（课速通）启动器
// 职责：读取 config.json → 首次部署预置 profile → 启动 Chromium 并加载预置扩展。
// 只面向 Windows 平台，编译为 GUI 子系统（无控制台窗口），错误通过消息框提示。
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// Config 对应 config.json，字段全部可选，缺省有合理默认值。
type Config struct {
	DefaultURL string   `json:"defaultUrl"`
	ExtraArgs  []string `json:"extraArgs"`
	AppName    string   `json:"appName"`
	Extensions []string `json:"extensions"`
}

func main() {
	exeDir, err := os.Executable()
	if err != nil {
		fatal("无法定位程序目录: " + err.Error())
		return
	}
	exeDir = filepath.Dir(exeDir)

	cfg := loadConfig(exeDir)

	chromePath := filepath.Join(exeDir, "chrome", "chrome.exe")
	profileDir := filepath.Join(exeDir, "profile")
	seedDir := filepath.Join(exeDir, "profile_seed")

	// 首次运行：把预置的 profile 种子复制到运行时目录。
	// 之后用户的所有数据（脚本配置、登录态、浏览数据）都在 profile 里演进。
	if _, err := os.Stat(profileDir); os.IsNotExist(err) {
		if _, serr := os.Stat(seedDir); serr == nil {
			if err := copyDir(seedDir, profileDir); err != nil {
				fatal("初始化用户数据失败: " + err.Error())
				return
			}
			// 种子不应携带生成流程的会话恢复数据；
			// 删除后首次启动只打开默认页，不会恢复出生成时的窗口。
			for _, d := range []string{"Sessions", "Sessions_Encrypted"} {
				_ = os.RemoveAll(filepath.Join(profileDir, "Default", d))
			}
		}
	}

	if _, err := os.Stat(chromePath); err != nil {
		fatal("未找到 chromium，请重新安装本程序:\n" + chromePath)
		return
	}

	// 组装启动参数
	args := []string{
		fmt.Sprintf("--user-data-dir=%s", profileDir),
		"--no-first-run",
		"--no-default-browser-check",
		// 抑制 Chrome for Testing 的"仅用于自动化测试"横幅（--disable-infobars 对 CfT 有效）
		"--disable-infobars",
		// 关闭涉及谷歌的功能：本程序面向国内网课场景，不需要谷歌账号与云端服务。
		// 以下开关均已在 Chrome for Testing 152.0.7977.13 对应的 Chromium 源码中确认存在。
		"--disable-sync",                                // 禁用谷歌账号同步
		"--disable-background-networking",               // 禁用后台联网（UMA 统计、安全浏览、翻译、扩展更新等）
		"--disable-component-update",                    // 禁用组件更新（安全浏览、证书吊销等从谷歌下载的组件）
		"--disable-domain-reliability",                  // 禁用域名可靠性监控（网络错误不再上报谷歌）
		"--disable-crashpad-for-testing",                // 禁用 Crashpad 崩溃上报
		"--disable-default-apps",                        // 首次运行不再安装谷歌默认应用
		"--disable-features=OptimizationHints",          // 禁用优化指导服务（不再请求谷歌优化建议接口）
		"--disable-features=NetworkTimeServiceQuerying", // 禁用网络时间服务（不再查询谷歌时间服务器）
		"--disable-features=Translate",                  // 禁用内置谷歌翻译
		// 谷歌 AI 功能（功能名均在 M152 源码中确认）：Compose 写作助手、PrivateAi 设备端
		// AI 服务、模型执行/设备端模型下载、AI 模型质量日志（上报谷歌）、AI 历史记录搜索、
		// 地址栏 AI 搜索模式、文本安全分类器。
		"--disable-features=Compose,PrivateAi,OptimizationGuideModelExecution,OptimizationGuideOnDeviceModel,OnDeviceModelBackgroundDownload,ModelQualityLogging,HistoryEmbeddings,HistoryEmbeddingsAnswers,GoogleSearchAiModeWorkspace,TextSafetyClassifier",
	}
	// 仅使用 --load-extension 加载 unpacked 扩展。该开关是单值开关：重复传多个
	// --load-extension 时 Chromium 只认最后一个，因此多个扩展必须用逗号合并成
	// 一个参数值（--load-extension=a,b）。
	// 注意不要加 --disable-extensions-except：它会触发 Chromium
	// "先禁用全部扩展再重启进程"的流程，首次启动会弹出
	// "加载扩展程序时候出错"的错误提示。
	extPaths := make([]string, 0, len(cfg.Extensions))
	for _, ext := range cfg.Extensions {
		extPaths = append(extPaths, filepath.Join(exeDir, filepath.FromSlash(ext)))
	}
	if len(extPaths) > 0 {
		args = append(args, "--load-extension="+strings.Join(extPaths, ","))
	}
	args = append(args, cfg.ExtraArgs...)

	url := cfg.DefaultURL
	if url == "" {
		url = "about:blank"
	}
	args = append(args, url)

	// 首次运行标记：记录"首次初始化是否已完成"，决定是否执行欢迎页清理。
	// 仅首次启动开启 CDP（端口由 Chromium 自动分配，写入 profile/DevToolsActivePort），
	// 用于关掉 ScriptCat 的"安装成功"欢迎页；后续启动不带该参数，行为与正常浏览器一致。
	markerFile := filepath.Join(exeDir, "first_run.flag")
	firstRun := false
	if _, err := os.Stat(markerFile); os.IsNotExist(err) {
		firstRun = true
		args = append(args, "--remote-debugging-port=0")
	}

	// 启动浏览器。Chromium 对同一 user-data-dir 的二次启动会自行转发给已运行实例，
	// 因此这里不需要额外的单实例锁。
	// 启动前写入 CfT 专用企业策略（关闭谷歌登录/同步、禁用后台运行），浏览器退出后恢复。
	restorePolicies := applyCftPolicies()
	if restorePolicies != nil {
		defer restorePolicies()
	}
	cmd := exec.Command(chromePath, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		fatal("启动浏览器失败: " + err.Error())
		return
	}
	if firstRun {
		// 首次启动：自动关闭 ScriptCat 的安装成功欢迎页，并写入首次运行标记。
		closeScriptCatWelcome(profileDir)
		_ = os.WriteFile(markerFile, []byte("Course-Thru first run completed: "+time.Now().Format("2006-01-02 15:04:05")+"\n"), 0644)
	}
	// 保持启动器存活直到浏览器退出（GUI 子系统下不产生可见控制台）。
	_ = cmd.Wait()
}

// loadConfig 读取 exe 同目录下的 config.json，缺省使用内置默认值。
func loadConfig(exeDir string) Config {
	cfg := Config{
		AppName:    "Course-Thru",
		DefaultURL: "",
		Extensions: []string{"extensions/scriptcat", "extensions/baidu-search"},
	}
	path := filepath.Join(exeDir, "config.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg
	}
	var raw map[string]json.RawMessage
	if json.Unmarshal(data, &raw) != nil {
		return cfg
	}
	if v, ok := raw["defaultUrl"]; ok {
		_ = json.Unmarshal(v, &cfg.DefaultURL)
	}
	if v, ok := raw["extraArgs"]; ok {
		_ = json.Unmarshal(v, &cfg.ExtraArgs)
	}
	if v, ok := raw["appName"]; ok {
		_ = json.Unmarshal(v, &cfg.AppName)
	}
	if v, ok := raw["extensions"]; ok {
		_ = json.Unmarshal(v, &cfg.Extensions)
	}
	return cfg
}

// copyDir 递归复制目录内容。
func copyDir(src, dst string) error {
	return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0755)
		}
		return copyFile(path, target)
	})
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return nil
}

// cftPolicyKey 是 Chrome for Testing 的企业策略注册表路径。CfT 与普通 Chrome 的策略
// 路径不同（普通 Chrome 为 Software\Policies\Google\Chrome），因此这里写入的策略
// 只影响本程序的浏览器，不会波及用户日常使用的 Chrome。
const cftPolicyKey = `HKCU\Software\Policies\Google\Chrome for Testing`

// cftPolicies 启动前写入的用户级策略（REG_DWORD）：
//
//	BrowserSignin=0          禁用谷歌账号登录入口
//	SyncDisabled=1           禁用谷歌同步
//	BackgroundModeEnabled=0  关闭"关闭浏览器后继续运行后台应用"
//
// 以下均为 CDP 无法完成、只能走注册表策略的动作；全部为非 sensitive 策略，
// 在未加入域的普通机器上同样生效（sensitive 策略如 DefaultSearchProvider*、
// MetricsReportingEnabled、SafeBrowsingEnabled 会被 Chrome 直接忽略，故不在此列；
// UMA 上传已由 --disable-background-networking 在网络层关闭）。
var cftPolicies = []struct{ name, value string }{
	{"BrowserSignin", "0"},                        // 禁用谷歌账号登录入口
	{"SyncDisabled", "1"},                         // 禁用谷歌同步
	{"BackgroundModeEnabled", "0"},                // 关闭"关闭浏览器后继续运行后台应用"
	{"SafeBrowsingProtectionLevel", "0"},          // 关闭安全浏览（URL 不再发谷歌检测；副作用：不拦截恶意网站）
	{"SafeBrowsingExtendedReportingEnabled", "0"}, // 关闭安全浏览增强报告（额外 URL/页面数据不再上报）
	{"SafeBrowsingSurveysEnabled", "0"},           // 关闭安全浏览调查问卷
	{"PasswordLeakDetectionEnabled", "0"},         // 关闭密码泄露检测（哈希不再发谷歌）
	{"SearchSuggestEnabled", "0"},                 // 关闭地址栏搜索建议（输入内容不再发给搜索引擎）
	{"NetworkPredictionOptions", "2"},             // 关闭网络预加载/预连接（减少后台网络请求）
}

// applyCftPolicies 在启动浏览器前写入 CfT 企业策略，返回浏览器退出后的恢复函数。
// 写入失败不阻塞启动（策略是加固项，不应影响主流程）；恢复时先删除本程序写入的值，
// 再还原用户原有的不同值；原本不存在的策略键会被整体删除。
func applyCftPolicies() func() {
	type savedPolicy struct {
		name    string
		typeVal string
	}
	var saved []savedPolicy
	keyExisted := false
	if out, err := exec.Command("reg", "query", cftPolicyKey).CombinedOutput(); err == nil {
		keyExisted = strings.Contains(string(out), "Chrome for Testing")
	}
	for _, p := range cftPolicies {
		old := ""
		if out, err := exec.Command("reg", "query", cftPolicyKey, "/v", p.name).CombinedOutput(); err == nil {
			old = parseRegValue(string(out), p.name)
		}
		// 旧值与即将写入的值相同（例如上次异常退出留下的残留）时不保存，
		// 退出时直接删除，避免残留策略无限延续。
		if old != "" && !regValueEquals(old, p.value) {
			saved = append(saved, savedPolicy{p.name, old})
		}
		_ = exec.Command("reg", "add", cftPolicyKey, "/v", p.name, "/t", "REG_DWORD", "/d", p.value, "/f").Run()
	}
	return func() {
		for _, p := range cftPolicies {
			_ = exec.Command("reg", "delete", cftPolicyKey, "/v", p.name, "/f").Run()
		}
		for _, s := range saved {
			fields := strings.SplitN(s.typeVal, " ", 2)
			if len(fields) == 2 {
				_ = exec.Command("reg", "add", cftPolicyKey, "/v", s.name, "/t", fields[0], "/d", fields[1], "/f").Run()
			}
		}
		if !keyExisted {
			_ = exec.Command("reg", "delete", cftPolicyKey, "/f").Run()
		}
	}
}

// parseRegValue 从 reg query 输出中提取指定策略值的"类型+值"（如 "REG_DWORD 0x1"）。
func parseRegValue(out, name string) string {
	idx := strings.Index(out, name)
	if idx < 0 {
		return ""
	}
	fields := strings.Fields(out[idx+len(name):])
	if len(fields) < 2 {
		return ""
	}
	return fields[0] + " " + fields[1]
}

// regValueEquals 比较 reg 查询出的值（如 "REG_DWORD 0x0"）与目标字符串（如 "0"）是否等价。
func regValueEquals(typeVal, target string) bool {
	fields := strings.Fields(typeVal)
	if len(fields) < 2 {
		return false
	}
	v := strings.ReplaceAll(fields[1], "0x", "")
	v = strings.TrimLeft(v, "0")
	if v == "" {
		v = "0"
	}
	return v == target
}

// closeScriptCatWelcome 通过 CDP HTTP 接口关闭 ScriptCat 的"安装成功"欢迎页。
// unpacked 扩展每次启动都会触发 onInstalled(reason=install)，ScriptCat 会因此
// 打开 docs.scriptcat.org 的安装完成页；构建时已在扩展源码中屏蔽该逻辑，
// 这里作为兜底，兼容旧版本扩展或未来版本变化。
func closeScriptCatWelcome(profileDir string) {
	port := waitDevToolsPort(profileDir)
	if port == 0 {
		return
	}
	client := &http.Client{Timeout: 2 * time.Second}
	deadline := time.Now().Add(12 * time.Second)
	errStreak := 0
	closedAny := false
	for time.Now().Before(deadline) {
		tabs, err := listDevToolsTabs(client, port)
		if err != nil {
			errStreak++
			// 连续失败说明浏览器已退出或 CDP 尚未就绪，放弃清理。
			if errStreak >= 3 {
				return
			}
			time.Sleep(500 * time.Millisecond)
			continue
		}
		errStreak = 0
		closed := 0
		for _, tab := range tabs {
			if strings.Contains(tab.URL, "install_comple") {
				if closeDevToolsTab(client, port, tab.ID) {
					closed++
				}
			}
		}
		if closed > 0 {
			closedAny = true
			time.Sleep(300 * time.Millisecond)
			continue
		}
		if closedAny {
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// waitDevToolsPort 读取 Chromium 写入的 DevToolsActivePort（第一行为实际端口）。
// 开启 --remote-debugging-port=0 时端口由系统分配，必须通过该文件获取。
func waitDevToolsPort(profileDir string) int {
	portFile := filepath.Join(profileDir, "DevToolsActivePort")
	for i := 0; i < 16; i++ {
		data, err := os.ReadFile(portFile)
		if err == nil {
			line := strings.TrimSpace(strings.SplitN(string(data), "\n", 2)[0])
			if n, err := strconv.Atoi(line); err == nil {
				return n
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	return 0
}

type devToolsTab struct {
	ID  string `json:"id"`
	URL string `json:"url"`
}

func listDevToolsTabs(client *http.Client, port int) ([]devToolsTab, error) {
	resp, err := client.Get(fmt.Sprintf("http://127.0.0.1:%d/json/list", port))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var tabs []devToolsTab
	if err := json.NewDecoder(resp.Body).Decode(&tabs); err != nil {
		return nil, err
	}
	return tabs, nil
}

func closeDevToolsTab(client *http.Client, port int, id string) bool {
	resp, err := client.Get(fmt.Sprintf("http://127.0.0.1:%d/json/close/%s", port, id))
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode == http.StatusOK
}

// fatal 显示错误消息框（GUI 子系统下没有控制台可见）。
func fatal(msg string) {
	user32 := syscall.NewLazyDLL("user32.dll")
	mb := user32.NewProc("MessageBoxW")
	title, _ := syscall.UTF16PtrFromString("Course-Thru")
	text, _ := syscall.UTF16PtrFromString(msg)
	mb.Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x10 /* MB_ICONERROR */)
}
