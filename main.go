// BrowserForLazy 启动器
// 职责：读取 config.json → 首次部署预置 profile → 启动 Chromium 并加载预置扩展。
// 只面向 Windows 平台，编译为 GUI 子系统（无控制台窗口），错误通过消息框提示。
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
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
	}
	for _, ext := range cfg.Extensions {
		extPath := filepath.Join(exeDir, filepath.FromSlash(ext))
		// 仅使用 --load-extension 加载 unpacked 扩展。
		// 注意不要加 --disable-extensions-except：它会触发 Chromium
		// "先禁用全部扩展再重启进程"的流程，首次启动会弹出
		// "加载扩展程序时候出错"的错误提示。
		args = append(args, "--load-extension="+extPath)
	}
	args = append(args, cfg.ExtraArgs...)

	url := cfg.DefaultURL
	if url == "" {
		url = "about:blank"
	}
	args = append(args, url)

	// 启动浏览器。Chromium 对同一 user-data-dir 的二次启动会自行转发给已运行实例，
	// 因此这里不需要额外的单实例锁。
	cmd := exec.Command(chromePath, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		fatal("启动浏览器失败: " + err.Error())
		return
	}
	// 保持启动器存活直到浏览器退出（GUI 子系统下不产生可见控制台）。
	_ = cmd.Wait()
}

// loadConfig 读取 exe 同目录下的 config.json，缺省使用内置默认值。
func loadConfig(exeDir string) Config {
	cfg := Config{
		AppName:    "BrowserForLazy",
		DefaultURL: "",
		Extensions: []string{"extensions/scriptcat"},
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

// fatal 显示错误消息框（GUI 子系统下没有控制台可见）。
func fatal(msg string) {
	user32 := syscall.NewLazyDLL("user32.dll")
	mb := user32.NewProc("MessageBoxW")
	title, _ := syscall.UTF16PtrFromString("BrowserForLazy")
	text, _ := syscall.UTF16PtrFromString(msg)
	mb.Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x10 /* MB_ICONERROR */)
}
