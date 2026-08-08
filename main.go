// Course-Thru（课速通）启动器
// 职责：读取 config.json → 首次部署预置 profile → 启动 Chromium 并加载预置扩展。
// 只面向 Windows 平台，编译为 GUI 子系统（无控制台窗口），错误通过消息框提示。
package main

import (
	"archive/zip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
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

// logFile 是启动器滚动日志的文件句柄；打开失败时所有日志静默丢弃，不阻塞主流程。
var logFile *os.File

// openLog 打开（或创建）启动器日志。日志超过 maxLogBytes 时轮转为
// coursthru.old.log 后重新开始，避免无限增长。
func openLog(exeDir string) {
	const maxLogBytes = 2 << 20 // 2 MB
	path := filepath.Join(exeDir, "coursethru.log")
	if fi, err := os.Stat(path); err == nil && fi.Size() > maxLogBytes {
		_ = os.Remove(filepath.Join(exeDir, "coursethru.old.log"))
		_ = os.Rename(path, filepath.Join(exeDir, "coursethru.old.log"))
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	logFile = f
}

// logf 写一条带时间戳的日志。
func logf(format string, args ...interface{}) {
	if logFile == nil {
		return
	}
	line := time.Now().Format("2006-01-02 15:04:05") + " [launcher] " + fmt.Sprintf(format, args...) + "\n"
	_, _ = io.WriteString(logFile, line)
}

func main() {
	exeDir, err := os.Executable()
	if err != nil {
		fatal("无法定位程序目录: " + err.Error())
		return
	}
	exeDir = filepath.Dir(exeDir)

	openLog(exeDir)
	logf("启动 Course-Thru，程序目录: %s", exeDir)

	cfg := loadConfig(exeDir)
	logf("配置: defaultUrl=%q, extensions=%v", cfg.DefaultURL, cfg.Extensions)

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
			logf("已从 profile_seed 复制初始用户数据")
		}
	}

	// 每次启动都清理会话恢复数据（Sessions / Sessions_Encrypted）：
	// 这是"关闭自动恢复上次标签页"的关键。Chromium 正常关闭会把打开的
	// 窗口/标签写入 Default\Sessions，若不清除，异常退出后即使没有恢复开关，
	// 下次启动也可能弹"恢复页面？"气泡甚至恢复会话。每次启动前清空，
	// 保证永远从默认页全新开始，且种子/生成流程的窗口也一并杜绝恢复。
	for _, d := range []string{"Sessions", "Sessions_Encrypted"} {
		_ = os.RemoveAll(filepath.Join(profileDir, "Default", d))
	}

	if _, err := os.Stat(chromePath); err != nil {
		fatal("未找到 chromium，请重新安装本程序:\n" + chromePath)
		return
	}

	// 静默内置扩展的"接管设置"确认框（方案见 OPEN-VERSION-GUIDE.md §2）：
	// 1) 清理旧版 chrome_url_overrides 残留（升级用户必做，否则旧记录会让
	//    确认框继续弹出）；2) 把简单接管（默认搜索引擎）的时间戳预置为未来值，
	//    让百度搜索扩展不再弹"更改搜索服务提供商是您的本意吗？"。
	if ensureBaiduQuiet(profileDir) {
		logf("已确保扩展接管静默（Preferences 时间戳预置/残留清理完成）")
	} else {
		logf("Preferences 接管静默处理跳过或失败（不影响主流程）")
	}

	// 组装启动参数
	args := []string{
		fmt.Sprintf("--user-data-dir=%s", profileDir),
		"--no-first-run",
		"--no-default-browser-check",
		// 每次启动都以最大化窗口打开（写死，不受首次运行限制约束）。
		"--start-maximized",
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
		// 关闭"自动恢复上次标签页"：不添加任何会话恢复开关（如 --restore-last-session、
		// --session-restore=*），Chromium 默认每次全新打开默认页。
		// --disable-session-crashed-bubble 进一步禁用异常退出后弹出的"恢复页面？"
		// 气泡，避免用户误点恢复出上次会话（配合上方每次启动清理 Sessions 双保险）。
		"--disable-session-crashed-bubble",
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

	// 启动地址：defaultUrl 留空 → 内置主页（course-thru/index.html，随程序分发、
	// 相对路径自包含）；填相对路径 → 解析为 file:// URL；填完整网址 → 原样打开。
	startURL := resolveStartURL(exeDir, cfg.DefaultURL)
	logf("启动地址: %s", startURL)
	args = append(args, startURL)

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
	// 启动前确保 CfT 专用企业策略已写入（关闭谷歌登录/同步、禁用后台运行等）。
	// 策略常驻注册表、退出不删除，卸载时由安装器统一清理。
	if applyCftPolicies() {
		logf("已确保 CfT 企业策略生效（缺失或值不对时写入，退出不删除）")
	} else {
		logf("写入 CfT 企业策略失败（不影响主流程）")
	}
	cmd := exec.Command(chromePath, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		fatal("启动浏览器失败: " + err.Error())
		return
	}
	logf("已启动 Chromium（PID %d，首次运行: %v）", cmd.Process.Pid, firstRun)
	if firstRun {
		// 首次运行标记只决定"下次是否再开调试端口"，与欢迎页清理结果无关，立即写入。
		_ = os.WriteFile(markerFile, []byte("Course-Thru first run completed: "+time.Now().Format("2006-01-02 15:04:05")+"\n"), 0644)
		logf("首次运行完成，已写入 first_run.flag")
		// 欢迎页清理是纯兜底（构建期已在扩展源码屏蔽该逻辑），放后台 goroutine：
		// 浏览器可能很快退出，同步等待会白白阻塞启动器最长约 20 秒（8 秒等端口 +
		// 12 秒轮询），且清理失败无副作用。goroutine 随进程退出自然终止。
		go closeScriptCatWelcome(profileDir)
	}
	// 保持启动器存活直到浏览器退出（GUI 子系统下不产生可见控制台）。
	_ = cmd.Wait()
	if cmd.ProcessState != nil {
		logf("浏览器进程退出，退出码: %d", cmd.ProcessState.ExitCode())
	}
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
	// scriptcat 是预置 OCS 脚本数据的载体扩展：移除它会导致首启丢失全部预置
	// 脚本（profile_seed 中的 OCS 数据按该扩展 ID 存储）。因此即使用户在
	// config.json 里自定义了扩展列表，也强制保留 scriptcat（幂等去重）。
	if !contains(cfg.Extensions, "extensions/scriptcat") {
		cfg.Extensions = append(cfg.Extensions, "extensions/scriptcat")
	}
	return cfg
}

// contains 判断字符串切片是否包含指定元素。
func contains(list []string, s string) bool {
	for _, e := range list {
		if e == s {
			return true
		}
	}
	return false
}

// resolveStartURL 决定启动时打开的第一个地址：
//   - 留空：使用内置主页 course-thru/index.html；
//   - 相对路径（如 homepage/index.html）：解析为程序目录下的绝对路径并转成
//     file:// URL（Windows 形如 file:///D:/xxx/homepage/index.html，空格与
//     中文由 net/url 自动转义，页面必须用相对路径引用资源才能自包含）；
//   - 完整网址（http/https/file 等）：原样返回。
func resolveStartURL(exeDir, s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		s = filepath.Join("course-thru", "index.html")
	}
	// 已带协议或浏览器内置协议前缀的字符串按网址处理，其余按本地路径处理
	if strings.Contains(s, "://") || strings.HasPrefix(s, "about:") ||
		strings.HasPrefix(s, "chrome:") || strings.HasPrefix(s, "edge:") ||
		strings.HasPrefix(s, "data:") {
		return s
	}
	p := filepath.FromSlash(s)
	if !filepath.IsAbs(p) {
		p = filepath.Join(exeDir, p)
	}
	if abs, err := filepath.Abs(p); err == nil {
		p = abs
	}
	u := &url.URL{Scheme: "file", Path: "/" + filepath.ToSlash(p)}
	return u.String()
}

// silentOverrideTimestamp 是 2099-01-01 对应的 Chrome base::Time 时间戳
// （自 1601-01-01 起的微秒数）。Chrome 对"简单接管"扩展（如只改默认搜索）有
// 静默机制：该字段达到此值即视为旧安装，不再弹"更改搜索服务提供商是您的本意吗？"。
const silentOverrideTimestamp = int64(15715382400000000)

// ensureBaiduQuiet 在启动浏览器前修正 profile 的 Default/Preferences：
//  1. 删除 extensions.chrome_url_overrides 残留。旧版曾用该字段接管新标签页，
//     Chrome 启动校验只清理"扩展已不存在"的记录，不会清理"扩展还在但已不再
//     声明接管"的残留；当前内置扩展都不再声明接管，整字段删除是安全的。
//  2. 把 extensions.simple_override_begin_confirmation_timestamp 预置为未来
//     时间戳（缺失或小于目标值时写入）。
//
// 解析用 json.Decoder + UseNumber（而非默认 float64）：Preferences 里除本字段外
// 还可能有其他超大整数（如各种时间戳、随机种子），默认解析会把它们全部变成
// float64 并在写回时丢精度/改写为科学计数法。UseNumber 让数字以原始文本
// json.Number 保留，写回时逐字节原样输出，不动无关字段的精度。
//
// 返回 false 表示文件缺失/解析失败等（正常跳过，不阻塞主流程）。
func ensureBaiduQuiet(profileDir string) bool {
	prefsPath := filepath.Join(profileDir, "Default", "Preferences")
	data, err := os.ReadFile(prefsPath)
	if err != nil {
		return false
	}
	var root map[string]interface{}
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.UseNumber()
	if dec.Decode(&root) != nil {
		return false
	}
	ext, _ := root["extensions"].(map[string]interface{})
	if ext == nil {
		ext = make(map[string]interface{})
		root["extensions"] = ext
	}
	changed := false
	if _, ok := ext["chrome_url_overrides"]; ok {
		delete(ext, "chrome_url_overrides")
		changed = true
	}
	// Chrome 可能把该字段改写为科学计数法（如 1.57153824e+16）或保留为整数；
	// 统一经 json.Number.String() 取原文后再比较数值大小。
	if cur, ok := ext["simple_override_begin_confirmation_timestamp"].(json.Number); !ok ||
		lessThan(cur, silentOverrideTimestamp) {
		// 以 json.Number 写入整数原文，避免 Marshal 时被写成科学计数法。
		ext["simple_override_begin_confirmation_timestamp"] = json.Number(strconv.FormatInt(silentOverrideTimestamp, 10))
		changed = true
	}
	if !changed {
		return true
	}
	out, err := json.Marshal(root)
	if err != nil {
		return false
	}
	// 先写临时文件再原子替换，避免写到一半的 Preferences 被 Chrome 读坏
	tmp := prefsPath + ".launcher.tmp"
	if err := os.WriteFile(tmp, out, 0644); err != nil {
		return false
	}
	if err := os.Rename(tmp, prefsPath); err != nil {
		_ = os.Remove(tmp)
		return false
	}
	return true
}

// lessThan 判断 json.Number 表示的数值是否小于 threshold（int64）。
// json.Number 是字符串，可能为整数原文或科学计数法，统一按 float64 比较。
func lessThan(num json.Number, threshold int64) bool {
	f, err := num.Float64()
	if err != nil {
		return true
	}
	return f < float64(threshold)
}

// copyDir 递归复制目录内容。
// profile_seed 约 200 个文件 / 14MB：4 个大文件占 ~10MB，其余是海量小文件
// （LevelDB 分段），单线程顺序复制在机械硬盘上小文件寻道开销大、首启出窗慢。
// 这里分两遍处理：第一遍同步遍历建目录（保证后续并发写文件时父目录已存在），
// 第二遍用固定 worker 池并发复制文件。任一文件失败即停止派发并返回首个错误，
// 与旧的顺序实现在"复制失败走 fatal"的行为上等价。
func copyDir(src, dst string) error {
	// 第一遍：遍历收集待复制文件（记录源路径 + 相对路径）+ 同步建目录。
	// 相对路径在第一遍就用 filepath.Rel 计算好并随任务携带：worker 直接复用，
	// 不在并发循环里二次调用 Rel（避免重复计算，也避免不同环境下的路径规范化差异）。
	var files []struct{ src, rel string }
	err := filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		if info.IsDir() {
			return os.MkdirAll(filepath.Join(dst, rel), 0755)
		}
		files = append(files, struct{ src, rel string }{path, rel})
		return nil
	})
	if err != nil {
		return err
	}

	const workers = 8
	jobs := make(chan struct{ src, rel string }, len(files)) // 缓冲容量=任务总数，发送永不阻塞
	var (
		wg    sync.WaitGroup
		mu    sync.Mutex
		first error
	)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for job := range jobs {
				if err := copyFile(job.src, filepath.Join(dst, job.rel)); err != nil {
					mu.Lock()
					if first == nil {
						first = err
					}
					mu.Unlock()
					return
				}
			}
		}()
	}

	// 第二遍：派发任务。发送/关闭都在独立 goroutine；有 worker 报错后不再派发。
	go func() {
		defer close(jobs)
		for _, job := range files {
			mu.Lock()
			stopped := first != nil
			mu.Unlock()
			if stopped {
				return
			}
			jobs <- job
		}
	}()

	wg.Wait()
	return first
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
	// 用 1MB 缓冲替代 io.Copy 默认的 32KB：profile_seed 里 4 个大文件占 ~10MB，
	// 大缓冲显著减少 read/write 系统调用次数（32KB 需要 ~320 次，1MB 仅 ~10 次）。
	// 每个 copyFile 调用创建自己的 buffer，并发 worker 之间无共享、无数据竞争。
	if _, err := io.CopyBuffer(out, in, make([]byte, 1<<20)); err != nil {
		return err
	}
	return nil
}

// hideConsole 让子进程不创建/不显示控制台窗口。
// GUI 子系统启动器拉起 reg.exe 等控制台程序时，Windows 默认会给子进程分配
// 新的控制台窗口（一闪而过的 cmd 黑框）；加 CREATE_NO_WINDOW 后子进程
// 不创建可见控制台，彻底消除弹窗。
func hideConsole(cmd *exec.Cmd) *exec.Cmd {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000} // CREATE_NO_WINDOW
	return cmd
}

// cftPolicyKey 是 Chrome for Testing 的企业策略注册表路径。CfT 与普通 Chrome 的策略
// 路径不同（普通 Chrome 为 Software\Policies\Google\Chrome），因此这里写入的策略
// 只影响本程序的浏览器，不会波及用户日常使用的 Chrome。
const cftPolicyKey = `HKCU\Software\Policies\Google\Chrome for Testing`

// cftPolicies 启动时确保生效的用户级策略（全部为 REG_DWORD）：
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

// applyCftPolicies 确保 CfT 企业策略已写入。每次 reg.exe 子进程都是一次完整的
// spawn 往返（约 10-50ms），因此先整键查询一次（reg query 不带 /v 会列出该键下
// 全部值），而不是逐条 query。整键输出与单值输出格式一致，parseRegValue 可复用。
// 键已存在时逐条比对已有值，缺失或值不对才补写；键不存在时整键写入全部策略。
// 策略常驻注册表、退出不删除；卸载时由 installer.iss 负责清理。
func applyCftPolicies() bool {
	out, err := hideConsole(exec.Command("reg", "query", cftPolicyKey)).CombinedOutput()
	// 键不存在（查询失败）：整键写入全部策略。
	if err != nil {
		return addCftPoliciesParallel(cftPolicies)
	}
	// 键存在：从整键输出中逐条提取已有值，缺失或值不对才补写（兼容未来新增策略）。
	var need []struct{ name, value string }
	for _, p := range cftPolicies {
		old := parseRegValue(string(out), p.name)
		if old != "" && regValueEquals(old, p.value) {
			continue
		}
		need = append(need, p)
	}
	if len(need) == 0 {
		return true
	}
	return addCftPoliciesParallel(need)
}

// addCftPoliciesParallel 并行写入多条 CfT 策略。每条策略写入注册表键下各自独立的
// 值（互不覆盖），Windows 注册表对不同值名的并发写没有冲突，可安全并行；把首启
// 时 9 次串行 reg add（每次 spawn reg.exe 约 10-50ms）压缩到约一次往返的开销。
// 返回全部成功与否。
func addCftPoliciesParallel(policies []struct{ name, value string }) bool {
	var wg sync.WaitGroup
	results := make(chan bool, len(policies))
	for _, p := range policies {
		wg.Add(1)
		go func(p struct{ name, value string }) {
			defer wg.Done()
			err := hideConsole(exec.Command("reg", "add", cftPolicyKey, "/v", p.name, "/t", "REG_DWORD", "/d", p.value, "/f")).Run()
			results <- err == nil
		}(p)
	}
	wg.Wait()
	close(results)
	for ok := range results {
		if !ok {
			return false
		}
	}
	return true
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

// regValueEquals 比较 reg 查询出的值（如 "REG_DWORD 0x0"）与目标值 target 是否等价。
// reg.exe 输出的 REG_DWORD 值固定为十六进制（如 0x0、0x10），cftPolicies 里的
// target 是十进制字符串（如 "0"、"2"）。统一解析为无符号整数再比较，避免十六进制
// 字符串直接比较造成的误判（例如 0x10 会与 "10" 混淆）。
func regValueEquals(typeVal, target string) bool {
	fields := strings.Fields(typeVal)
	if len(fields) < 2 {
		return false
	}
	got, err := strconv.ParseUint(strings.TrimPrefix(fields[1], "0x"), 16, 32)
	if err != nil {
		return false
	}
	want, err := strconv.ParseUint(target, 10, 32)
	if err != nil {
		return false
	}
	return got == want
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

// bundleLogs 把启动器日志与版本信息打包成 zip，存到程序目录的 crash-logs 子文件夹。
// 返回 zip 绝对路径；任何一步失败都返回空字符串（不阻塞主流程）。
func bundleLogs(exeDir, reason string) string {
	logDir := filepath.Join(exeDir, "crash-logs")
	if err := os.MkdirAll(logDir, 0755); err != nil {
		return ""
	}
	zipPath := filepath.Join(logDir, "Course-Thru-crash-"+time.Now().Format("20060102-150405")+".zip")
	zf, err := os.Create(zipPath)
	if err != nil {
		return ""
	}
	defer zf.Close()
	zw := zip.NewWriter(zf)
	// 收集：启动器日志（含轮转旧日志）+ 版本信息；缺文件自动跳过。
	files := map[string]string{
		"coursethru.log":     filepath.Join(exeDir, "coursethru.log"),
		"coursethru.old.log": filepath.Join(exeDir, "coursethru.old.log"),
		"version.txt":        filepath.Join(exeDir, "version.txt"),
	}
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		data, err := os.ReadFile(files[name])
		if err != nil {
			continue
		}
		w, err := zw.Create(name)
		if err != nil {
			continue
		}
		_, _ = w.Write(data)
	}
	if err := zw.Close(); err != nil {
		return ""
	}
	_ = zf.Close()
	return zipPath
}

// fatal 记录错误、把日志打包成 zip 并打开所在文件夹，然后显示错误消息框。
// GUI 子系统下没有控制台可见，错误与日志位置都通过消息框告知用户。
func fatal(msg string) {
	exeDir, err := os.Executable()
	if err == nil {
		exeDir = filepath.Dir(exeDir)
		logf("严重错误: %s", msg)
		if zipPath := bundleLogs(exeDir, msg); zipPath != "" {
			logf("已打包日志: %s", zipPath)
			// 打开文件夹并定位 zip 文件（explorer 立即返回，不等待）
			_ = exec.Command("explorer.exe", "/select,"+zipPath).Start()
			msg = msg + "\n\n错误详情已打包，请在打开的文件夹中把以下 zip 发送给开发者：\n" + zipPath
		}
	}
	user32 := syscall.NewLazyDLL("user32.dll")
	mb := user32.NewProc("MessageBoxW")
	title, _ := syscall.UTF16PtrFromString("Course-Thru")
	text, _ := syscall.UTF16PtrFromString(msg)
	mb.Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x10 /* MB_ICONERROR */)
}
