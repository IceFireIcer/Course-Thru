# 课速通 Logo 替换指南（开放版维护交接）

本文档写给接手开放版课速通的 AI / 维护者：完整说明本仓库“浏览器 logo 全链路替换”
的实现方式、验证方法，以及本次实测踩过的坑。配套代码：
`generate-assets.py`、`patch-logo.py`、`patch-icons.py`、`build.ps1`
（第 3.6 / 3.7 / 4.3 / 5 节）、`installer.iss`、`assets/` 目录。

---

## 1. 背景：为什么 logo 必须构建期替换

Chromium（Chrome for Testing，简称 CfT）的“品牌 logo”不是命令行参数、CDP 或
企业策略能改的，它编译在三个地方：

| 位置 | 承载内容 | 影响面 |
| --- | --- | --- |
| `chrome_100_percent.pak` / `chrome_200_percent.pak` / `resources.pak` | PNG 图片资源（Chrome 产品 logo，16~256px 多尺寸） | 新标签页 favicon、关于页 logo、部分窗口/界面图标 |
| `chrome.exe` / `chrome.dll` / `chrome_pwa_launcher.exe` | PE 图标资源（RT_GROUP_ICON / RT_ICON） | 任务栏、窗口标题栏、文件关联、快捷方式图标 |
| `dist\extensions\scriptcat\assets\logo*.png` | 扩展自身图标（manifest 引用 + 弹窗/选项页头部 `<img>`） | 浏览器工具栏 ScriptCat 图标、扩展面板 |

另外安装包（Inno Setup）的图标与安装向导图是编译期素材，属于第四条链路。

结论：**唯一可靠的方案是构建期就地改写**——解压 Chromium 后、打包前，把上述资源
全部替换成自有 logo。这套机制与 `BRANDING-PATCH.md`（文字品牌替换）互补：
那份文档管“Chrome for Testing 字样”，本文档管“Chrome 图标/logo 图片”。

---

## 2. 资源组织与生成

### 2.1 目录结构

```text
logo/logo.png                  ← 唯一源文件（632×631 RGBA，带透明边角）
assets/
  logo-16/24/32/48/64/128/256.png   ← pak 产品 logo 替换用，按像素尺寸一一对应
  app.ico                          ← 多尺寸 ICO（16~256），exe/dll/安装包图标
  wizard-image.bmp                 ← Inno Setup 大向导图（164×314）
  wizard-small-image.bmp           ← Inno Setup 小向导图（55×58）
  scriptcat/logo.png               ← ScriptCat 128px 彩图（manifest 主图标）
  scriptcat/logo-32.png            ← 32px 彩图
  scriptcat/logo-gray.png          ← 128px 灰度图（停用/暗色态）
  scriptcat/logo-gray-32.png       ← 32px 灰度图
```

### 2.2 生成方式

```powershell
python generate-assets.py
```

从 `logo/logo.png` 一键重新生成全部 `assets/`。脚本要点：

- 各尺寸用 `LANCZOS` 重采样，保留 alpha 透明通道；
- `app.ico` 必须用 `Image.save(path, format="ICO", sizes=[(s,s) for s in ...])`
  写法（见 6.2 的坑）；
- ScriptCat 灰度图用 `ImageOps.colorize` 做中灰渐变，保留透明；
- 向导图白底 + 居中 logo（大图 110px、小图 36px），24-bit BMP。

---

## 3. 四条替换链路

### 3.1 pak 图片资源（`patch-logo.py`）

原理：`.pak` 是 grit data_pack v5（12 字节头 + 6 字节/条目的资源表），解析后遍历
每个资源，只处理 PNG 字节（`\x89PNG\r\n\x1a\n` 魔数开头），识别 Chrome 产品 logo
后整块替换。

识别启发式（不硬编码资源 ID，靠内容识别，天然适配版本升级）：

```text
条件：正方形 PNG，边长 ∈ {16,24,32,48,64,96,128,256}
统计不透明像素到 Chrome 四色（蓝#4285F4 红#EA4335 黄#FBBC05 绿#34A853）的占比
命中：至少 3 个品牌色占比 ≥5%，且蓝色占比 <35%
```

- 蓝 <35% 是为了排除 Google G 之类以蓝为主的高蓝图标；
- 单色/双色工具图标（满蓝、满黄等）天然不命中；
- **追加 CfT 浅蓝“C”型检测**：Chrome for Testing 的新标签页/关于页产品 logo
  是浅蓝 C 环（四色占比法抓不到），按“透明底 + 蓝色占比 0.2~0.6 + 几乎无暖色 +
  蓝色像素为浅蓝”识别（`is_cft_blue_logo`），实测命中 chrome_*.pak 的
  14469/14470/14471/14472/14460（100%/200% 各一份）；
- 幂等：目标资源字节已等于 `assets/logo-<size>.png` 时跳过，可重复执行。

Chrome 152 实测命中（供参考，勿硬编码）：

```text
chrome_100_percent.pak : 677(16) 14321(32) 14323(16) 39824(16)
chrome_200_percent.pak : 677(32) 14321(32) 14323(16) 39824(32)
resources.pak          : 14151(128) 14152(256) 14183(16) 14184(24) 14185(64)
另：chrome_100/200_percent.pak 的 14460/14469/14470/14471/14472（CfT 浅蓝 C 家族）
```

用法：

```powershell
python patch-logo.py <assets目录> <pak文件...>
```

### 3.2 PE 图标（patch-icons.py）

`chrome.exe` / `chrome.dll` / `chrome_pwa_launcher.exe` / Go 启动器
`Course-Thru.exe` 的图标用 `patch-icons.py` 重建资源段替换：

```powershell
python patch-icons.py "<目标exe/dll>" --logo logo\logo.png --groups <组名/组ID>
# 启动器（无资源段）：python patch-icons.py dist\Course-Thru.exe --logo logo\logo.png --add-main-icon
```

- 目标组：`chrome.exe` 是命名组 `IDR_MAINFRAME`（窗口/任务栏图标）与
  `IDR_X001_APP_LIST`；`chrome.dll` 是数值组 `101`；`chrome_pwa_launcher.exe`
  是数值组 `1`；
- 原理：解析旧资源树 → 完整拷贝 → 把目标组的 RT_ICON 图像与组描述换成
  `assets\logo-<尺寸>.png` → 序列化后作为新节（`.rsrc2`）追加到文件末尾并
  重指资源目录。只追加不重写，297MB 的 `chrome.dll` 实测约 10s；
- **为什么不用 rcedit**：rcedit 只会新增一个未命名图标组（id 0），而 Chrome
  的主图标组是命名资源，替换后窗口/任务栏仍显示旧 Chrome 图标（实测
  `ExtractIconEx` 返回的仍是原图标），达不到替换目的，详见 6.8；
- **副作用**：改写 PE 资源会使 Google 的 Authenticode 签名失效（CfT 本身未签名，
  私人版无影响，Windows 可能显示“未知发布者”）；
- 该步骤放入 `build.ps1` 第 3.7 节（chrome 三个二进制）与第 5 节（启动器）。

### 3.3 ScriptCat 扩展图标

`build.ps1` 第 4.3 节：解压并注入 key 之后，把 `assets\scriptcat\` 四个文件
覆盖到 `$extDir\assets\` 同名文件。

- manifest 的 `action.default_icon` / `icons` 指向 `assets/logo.png`，不用改 manifest；
- 弹窗/选项页头部 `<img src="/assets/logo.png">` 引用同一文件，覆盖即生效；
- `profile_seed` 里没有扩展文件副本（unpacked 扩展按路径加载），**不用**处理
  profile_seed，也不用重新生成 profile。

### 3.4 Inno Setup 安装包

`installer.iss` 的 `[Setup]` 段新增三行（路径相对 `.iss` 所在的项目根）：

```text
SetupIconFile=assets\app.ico
WizardImageFile=assets\wizard-image.bmp
WizardSmallImageFile=assets\wizard-small-image.bmp
```

- 大向导图固定 164×314，小向导图 55×58（Inno Setup 6 标准尺寸）；
- 卸载器图标走 `UninstallDisplayIcon={app}\{#MyAppExeName}`，随 exe 图标自动生效。

---

## 4. build.ps1 集成点速查

| 节号 | 内容 |
| --- | --- |
| 3.6 | 调 `patch-logo.py` 替换三个 pak 的产品 logo |
| 3.7 | 调 `patch-icons.py` 替换 chrome.exe / chrome.dll / chrome_pwa_launcher.exe 图标（幂等） |
| 4.3 | 覆盖 ScriptCat 扩展的 4 个 logo 文件 |
| 5 | Go 编译后对 `dist\Course-Thru.exe` 注入图标 |

所有步骤都设计成幂等：复用已有 `dist\chrome` 时不会重复报错或重复改动。

---

## 5. 验证清单（接手后必须照做）

### 5.1 pak 无残留

自包含校验脚本（与 `patch-logo.py` 同一启发式，三个 pak 的“剩余 logo id 列表”
应全部为空）：

```powershell
@'
import io, struct
from PIL import Image
BRAND={"blue":(0x42,0x85,0xF4),"red":(0xEA,0x43,0x35),"yellow":(0xFB,0xBC,0x05),"green":(0x34,0xA8,0x53)}
def left(path):
    d=open(path,"rb").read(); n=struct.unpack_from("<H",d,8)[0]; out=[]
    for i in range(n):
        rid,ofs=struct.unpack_from("<HI",d,12+6*i); _,nofs=struct.unpack_from("<HI",d,12+6*(i+1))
        raw=d[ofs:nofs]
        if not raw.startswith(b"\x89PNG\r\n\x1a\n"): continue
        im=Image.open(io.BytesIO(raw)).convert("RGBA"); w,h=im.size
        if w!=h or w not in (16,24,32,48,64,96,128,256): continue
        px=im.load(); c={k:0 for k in BRAND}; op=0
        for y in range(h):
            for x in range(w):
                r,g,b,a=px[x,y]
                if a<32: continue
                op+=1
                k=min(BRAND,key=lambda q:abs(r-BRAND[q][0])+abs(g-BRAND[q][1])+abs(b-BRAND[q][2]))
                if abs(r-BRAND[k][0])+abs(g-BRAND[k][1])+abs(b-BRAND[k][2])<120: c[k]+=1
        if op==0: continue
        f={k:c[k]/op for k in BRAND}
        if sum(1 for k in BRAND if f[k]>=0.05)>=3 and f["blue"]<0.35: out.append(rid)
    return out
for p in [r".\dist\chrome\chrome_100_percent.pak",r".\dist\chrome\chrome_200_percent.pak",r".\dist\chrome\resources.pak"]:
    print(p, left(p))
'@ | python -
```

### 5.2 图标与源 logo 像素一致

```powershell
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class IconEx { [DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr ExtractIcon(IntPtr hInst, string lpszExeFileName, int nIconIndex); }'
$h = [IconEx]::ExtractIcon([IntPtr]::Zero, '.\dist\Course-Thru.exe', 0)
$ico = [System.Drawing.Icon]::FromHandle($h); $bmp = $ico.ToBitmap()
$bmp.Save('.\icon-check.png', [System.Drawing.Imaging.ImageFormat]::Png)
```

然后与 `assets\logo-32.png` 逐像素比对（容差内 0 差异）。`chrome.exe`、
`chrome.dll`、安装包 exe 同样抽查。

### 5.3 冒烟测试（注意 6.3 的坑）

不要用 `chrome.exe --version` 验证（CfT 会拉起完整浏览器而不是打印版本）。正确
姿势：独立临时 profile + headless + CDP 探活：

```powershell
$prof = "$env:TEMP\ct-smoke"
Start-Process ".\dist\chrome\chrome.exe" -ArgumentList @("--headless=new","--no-first-run","--disable-gpu","--user-data-dir=$prof","--remote-debugging-port=9339","about:blank")
# 轮询 http://127.0.0.1:9339/json/version 直到有响应即说明二进制完好
```

验证完用 `Get-CimInstance Win32_Process` 按临时 profile 路径精确杀进程（见 6.5）。

---

## 6. 踩坑与经验（重点）

### 6.1 GitHub 直连失败 → 走系统代理

本机直连 `github.com:443` 不通，rcedit 下载必须带代理（与 `build.ps1` 的
`Download` 函数同款回退逻辑）：

```powershell
$s = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
curl.exe -L --proxy "http://$($s.ProxyServer)" -o .\.tools\rcedit-x64.exe <url>
```

### 6.2 PIL 写 ICO 的坑

`Image.save(path, format="ICO", append_images=[...])` 实测只写入第一帧
（16×16）！正确写法是：

```python
im.save(path, format="ICO", sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
```

验证 ICO 帧数不能靠 `Image.open(...).seek()`（PIL 对 ICO 只暴露一帧），要解析
ICO 头部 `count` 字段；且 PIL 写入的 ICO 帧就是 PNG 字节，可直接与
`logo-<size>.png` 做字节级比对。

### 6.3 CfT 的 `--version` 会拉起完整浏览器

实测 `chrome.exe --version` 不打印版本，而是**启动完整浏览器**（用默认
`Chrome for Testing User Data` profile），会弹窗口、挂起等待、干扰后续测试。
千万别拿它做冒烟验证；也注意别让它在用户桌面上开窗口。

### 6.4 运行中替换文件的特性

浏览器运行期间替换 `chrome.exe` / `chrome.dll` 不会报错（Windows 允许），但
**已运行的进程仍使用旧的内存映射**，要重启浏览器才能看到新 logo。这也意味着：
改完 logo 后用户当前开着的会话不会立刻变化，属正常现象。

### 6.5 清理测试进程：先看 CommandLine 再杀

用唯一 profile 路径过滤后逐个确认再 `Stop-Process`，不要按进程名批量杀：

```powershell
Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
  Where-Object { $_.CommandLine -match '<你的临时profile唯一标记>' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

本次实操中曾因清理测试进程连带关掉了用户开着的浏览器会话（profile 数据无损，
重启即可），开放版务必避免。另：`Remove-Item -Recurse` 在部分策略下会被拦，
可用 `[System.IO.Directory]::Delete($path, $true)` 兜底。

### 6.6 升级 Chromium 版本时要复查的点

- `.pak` 仍是 data_pack v5 时脚本可直接复用；若谷歌改格式需同步改 `patch-logo.py`；
- 产品 logo 的尺寸集合/四色启发式若在新版本失配，先跑一次分析脚本（枚举所有
  正方形 PNG + 品牌色占比），人工确认命中集合再微调阈值；
- 资源 ID 会变，但脚本靠内容识别，不依赖 ID，通常无需改；
- `BRANDING-PATCH.md` 的文本替换与本文档的图片替换互不干扰，顺序无所谓。

### 6.7 其它经验

- 产品 logo 尺寸覆盖 16/24/32/64/128/256（100% 与 200% pak 各有一份），
  48/96 在本次版本中未出现，无需硬凑；
- 安装包文件名带版本（`dist-installer\Course-Thru-<版本>-Setup.exe`），旧版本
  安装包不会自动删除，发布时留意区分；
- `dist\chrome\First Run` 等无关残留不影响 logo 流程，不要顺手“修复”。

### 6.8 rcedit 无法替换 Chrome 的命名图标组

曾按常规做法用 rcedit `--set-icon` 替换 chrome.exe / chrome.dll 图标，实测
**不生效**：rcedit 只会在资源树末尾新增一个未命名组（id 0），Chrome 的
主图标组 `IDR_MAINFRAME`（chrome.exe）与数值组 `101`（chrome.dll）原样保留，
窗口/任务栏/文件图标仍是旧 Chrome logo（`ExtractIconEx` 验证）。因此 PE 图标
统一改用 `patch-icons.py`（重建资源段、直接替换目标组），不要再回退到 rcedit。

### 6.9 新标签页顶部 logo 是编译进二进制的 Google 字标（无法替换）

`chrome://newtab` 顶部的 logo 由 `ntp-logo` 组件以
`background-image: url(./icons/google_logo.svg)` 绘制（见 new_tab_page.js），
该 SVG 由浏览器进程从编译进 chrome.dll 的资源表动态提供，不在三个 pak 里，
也无法用补丁脚本定位替换（与 BRANDING-PATCH.md 里「自定义」按钮同理）。
因此 NTP 顶部仍是 Google 字标；本方案覆盖的是任务栏/窗口图标、关于页、
标签页 favicon 等所有 pak/PE 承载的产品 logo。若后续需要接管整个 NTP，
可做 `chrome_url_overrides.newtab` 自定义新标签页扩展（工作量大，未做）。

---

## 7. 开放版快速上手 checklist

```text
[ ] 确认 logo\logo.png 为最终设计稿（正方形、带透明、至少 256px 清晰）
[ ] python generate-assets.py 重新生成 assets\
[ ] 重跑构建：powershell -ExecutionPolicy Bypass -File build.ps1 -NoNsis -SkipProfile
[ ] 编译安装包：ISCC.exe "/DDIST=<dist绝对路径>" "/DMyAppVersion=<版本>" installer.iss
[ ] 5.1 pak 无残留 / 5.2 图标像素一致 / 5.3 headless+CDP 冒烟
[ ] 确认没有 chrome 测试进程残留、用户浏览器已重启再看效果
```
