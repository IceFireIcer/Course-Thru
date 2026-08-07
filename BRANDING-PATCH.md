# 去品牌化复现指南：把 “Chrome for Testing” 字样替换为 Course-Thru

适用于基于 Chromium for Testing（Chrome for Testing，简称 CfT）的课速通私人版。
目标：让新标签页的“自定义 Chrome for Testing”按钮、设置里的“关于 Chrome for Testing”、
窗口标题模板等不再出现 Chrome for Testing 字样。

## 1. 原理

- 这些字样不是命令行/策略/扩展能改的：
  - CDP 的 `Browser` 域只有窗口位置/大小/状态（`getWindowBounds` / `setWindowBounds`），
    没有设置窗口标题的接口；`document.title` 只能改当前标签页，且普通窗口模式标题仍带
    “- Chrome for Testing” 后缀。
  - Chrome 企业策略（`HKCU\Software\Policies\Google\Chrome for Testing`）没有
    “窗口标题 / 品牌名”相关策略。
- 这些字符串编译在语言包资源里：`chrome\locales\*.pak`（如 `zh-CN.pak`、`en-US.pak`），
  `chrome\resources.pak` 里没有品牌字符串（本次 152 实测）。
- `.pak` 是 grit data_pack v5 格式：
  - 头部 12 字节：`version u4`（=5）、`encoding u1`（1=UTF-8，2=UTF-16LE）、
    3 字节填充、`num_resources u2`、`num_aliases u2`；
  - 之后 `(num_resources+1)` 条 6 字节条目：`id u2` + `offset u4`（**绝对文件偏移**）；
    末尾一条 `id=0` 的哨兵条目指向数据区结束位置；
  - 之后是别名表（`num_aliases` 条 × 4 字节）；
  - 最后是数据区。资源长度 = 下一条目 offset − 本条 offset。
- 做法：解析 pak → 对每个文本资源做字符串替换 → 重新计算偏移表并重写文件。
  无匹配的文件保持原样（幂等，可重复执行）。

## 2. 涉及的字符串（zh-CN / en-US 实测）

| 资源内容 | 出现位置 |
| --- | --- |
| `Google Chrome for Testing` | 关于页产品名、菜单“关于…”等 |
| `Chrome for Testing` | 各类品牌文案 |
| `$1 - Google Chrome for Testing` | 窗口标题模板 |
| `自定义 Chrome for Testing` / `Customize Chrome for Testing` | 新标签页右下角按钮 |
| `关于 Chrome for Testing` / `About Chrome for Testing` | 设置侧栏、页面标题 |
| `获取 Chrome for Testing 方面的帮助` | 关于页帮助链接 |

替换规则（先长后短，避免子串被先改掉）：

```text
Google Chrome for Testing  ->  Course-Thru 课速通
Chrome for Testing         ->  Course-Thru
```

## 3. 新增文件：`patch-branding.py`（放在仓库根目录）

```python
"""把 .pak 资源里的 “Chrome for Testing” 品牌字样替换为 “Course-Thru 课速通”。

构建期脚本，由 build.ps1 在 Chromium 解压后调用。Chrome for Testing 的
品牌字符串（窗口标题模板、新标签页“自定义”按钮、设置“关于”页等）编译在
语言包资源里，CDP 与企业策略都无法修改，只能在构建期替换资源文本。

支持 grit data_pack v5（Chrome 152 实际格式：12 字节头 + 6 字节条目，
offset 为绝对文件偏移，UTF-8/UTF-16 文本资源）。仅在字符串出现变化时重写文件；
无匹配时文件保持不变（幂等，可重复执行）。用法：
    python patch-branding.py path/to/resources.pak [more.pak ...]
"""
import struct
import sys
from pathlib import Path

# 先替换长的，避免把 “Google Chrome for Testing” 里的子串先改掉。
REPLACEMENTS = [
    ("Google Chrome for Testing", "Course-Thru \u8bfe\u901f\u901a"),
    ("Chrome for Testing", "Course-Thru"),
]


def parse_pak(data):
    """返回 (encoding, entries, aliases)；非 v5 格式返回 None。"""
    if len(data) < 16:
        return None
    version, = struct.unpack_from("<I", data, 0)
    if version != 5:
        return None
    encoding = data[4]
    num_res, = struct.unpack_from("<H", data, 8)
    num_alias, = struct.unpack_from("<H", data, 10)
    header_len = 12
    entries = [
        struct.unpack_from("<HI", data, header_len + 6 * i)
        for i in range(num_res + 1)
    ]
    aliases = [
        struct.unpack_from("<HH", data, header_len + 6 * (num_res + 1) + 4 * i)
        for i in range(num_alias)
    ]
    return encoding, entries, aliases


def patch_pak(data):
    """返回重写后的 pak 字节；无匹配时返回 None。"""
    parsed = parse_pak(data)
    if parsed is None:
        raise ValueError("仅支持 data_pack v5")
    encoding, entries, aliases = parsed
    for _, ofs in entries:
        if ofs > len(data):
            raise ValueError("pak 结构异常（偏移越界）")

    def decode(raw):
        if encoding == 2:
            return raw.decode("utf-16-le")
        return raw.decode("utf-8")

    def encode(text):
        if encoding == 2:
            return text.encode("utf-16-le")
        return text.encode("utf-8")

    bodies = []
    changed = 0
    for i in range(len(entries) - 1):
        _, ofs = entries[i]
        _, next_ofs = entries[i + 1]
        raw = data[ofs:next_ofs]
        new_raw = raw
        try:
            text = decode(raw)
            for old, new in REPLACEMENTS:
                if old in text:
                    text = text.replace(old, new)
            new_raw = encode(text)
        except (UnicodeDecodeError, UnicodeEncodeError):
            # 二进制资源（图片、HTML 等）不做文本替换。
            pass
        if new_raw != raw:
            changed += 1
        bodies.append(new_raw)

    if changed == 0:
        return None

    offsets = []
    pos = 0
    for b in bodies:
        offsets.append(pos)
        pos += len(b)
    offsets.append(pos)

    # v5 头部：version u4 + encoding u1 + pad3 + num_res u2 + num_alias u2
    num_res = len(entries) - 1
    head = (
        struct.pack("<I", 5)
        + bytes([encoding])
        + b"\x00\x00\x00"
        + struct.pack("<HH", num_res, len(aliases))
    )
    alias_bytes = b"".join(struct.pack("<HH", a, b) for a, b in aliases)
    table_len = 6 * len(entries)
    data_start = len(head) + table_len + len(alias_bytes)
    table = b"".join(
        struct.pack("<HI", rid, data_start + ofs)
        for (rid, _), ofs in zip(entries, offsets)
    )
    return head + table + alias_bytes + b"".join(bodies)


def main():
    for arg in sys.argv[1:]:
        p = Path(arg)
        data = p.read_bytes()
        out = patch_pak(data)
        if out is None:
            print(f"[unchanged] {p}")
            continue
        p.write_bytes(out)
        print(f"[patched] {p} ({len(data)} -> {len(out)} bytes)")


if __name__ == "__main__":
    main()
```

## 4. 修改 `build.ps1`：增加品牌替换步骤

在“3. 准备 Chromium”的 `if (-not (Test-Path (Join-Path $distChrome "chrome.exe"))) { ... }`
代码块**之后**、第 4 步“准备 ScriptCat 扩展”**之前**插入：

```powershell
# ============ 3.5 品牌字符串替换（构建期）============
# Chrome for Testing 的“Chrome for Testing”品牌字样编译在语言包资源
# （locales\*.pak、resources.pak）里，CDP 与企业策略都无法修改，只能在
# 构建期替换。脚本幂等：无匹配的文件保持原样，可重复执行。
$brandScript = Join-Path $Root "patch-branding.py"
if (-not (Test-Path $brandScript)) {
    Fail "缺少品牌替换脚本 $brandScript"
}
$pakFiles = @(Get-ChildItem (Join-Path $distChrome "locales\*.pak") -File)
$pakFiles += Join-Path $distChrome "resources.pak"
Info "替换品牌字符串（Chrome for Testing -> Course-Thru）..."
& python $brandScript $pakFiles
if ($LASTEXITCODE -ne 0) { Fail "品牌字符串替换失败" }
```

说明：
- `$Root` / `$Dist` / `$distChrome` / `Info` / `Fail` 是 `build.ps1` 里已有的变量和函数，直接复用；
- 需要构建机上有 `python`（在 PATH 中）；本机 `D:\Code\PythonEvm312\python.exe` 可用；
- 该步骤每次构建都执行，但幂等：已替换过的文件显示 `[unchanged]`，不会重复改动。

## 5. 构建与验证

### 5.1 完整构建（便携版，跳过 profile 生成）

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1 -NoNsis -SkipProfile
```

构建日志应出现：

```text
[build] 替换品牌字符串（Chrome for Testing -> Course-Thru）...
[patched] ...\dist\chrome\locales\zh-CN.pak (... bytes)
```

（如果 `dist\chrome` 已存在且已替换过，则全部显示 `[unchanged]`，属正常。）

### 5.2 语言包层验证（无需启动浏览器）

```powershell
# 确认 zh-CN.pak 里不再有 “Chrome for Testing” 字样
$b = [System.IO.File]::ReadAllBytes(".\dist\chrome\locales\zh-CN.pak")
[System.Text.Encoding]::UTF8.GetString($b) -match "Chrome for Testing"
# 输出 False 即通过
```

### 5.3 启动验证

```powershell
# 首次启动会生成 profile；窗口标题应显示 “... - Course-Thru 课速通”
.\dist\Course-Thru.exe
Get-Process chrome | Where-Object { $_.MainWindowTitle } | Select-Object MainWindowTitle
```

肉眼检查：
- 新标签页右下角按钮文案：`自定义 Course-Thru`（不再是 `自定义 Chrome for Testing`）；
- 设置 → 左侧菜单：`关于 Course-Thru`；
- 设置 → 关于页：产品名 `Course-Thru 课速通`，帮助链接 `获取 Course-Thru 方面的帮助`；
- 窗口标题后缀：`Course-Thru 课速通`。

### 5.4 （可选）CDP DOM 验证

用 `--remote-debugging-port=9333` 启动后，用 CDP 抓取页面里是否残留
`Chrome for Testing`（含 shadow DOM）：

```powershell
$p = Start-Process .\dist\chrome\chrome.exe -ArgumentList @(
    "--user-data-dir=$env:TEMP\cft-verify",
    "--no-first-run", "--lang=zh-CN", "--remote-debugging-port=9333", "about:blank"
) -PassThru
```

然后（Node ≥ 21，自带 WebSocket）检查 `chrome://newtab` 与 `chrome://settings/help`：

```javascript
const port = 9333;
const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = tabs.find((t) => t.type === "page");
const sock = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r, j) => { sock.onopen = r; sock.onerror = j; });
let id = 0;
const cdp = (method, params = {}) => new Promise((resolve, reject) => {
  const m = ++id;
  const h = (ev) => {
    const d = JSON.parse(ev.data);
    if (d.id === m) { sock.removeEventListener("message", h); d.error ? reject(d.error) : resolve(d.result); }
  };
  sock.addEventListener("message", h);
  sock.send(JSON.stringify({ id: m, method, params }));
});
const collect = `(() => {
  const out = [];
  const walk = (root) => {
    const it = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    let n;
    while ((n = it.nextNode())) {
      const t = (n.innerText || n.textContent || "").trim();
      if (t && /chrome\\s*for\\s*testing/i.test(t)) out.push(t.replace(/\\s+/g, " ").slice(0, 120));
      if (n.shadowRoot) walk(n.shadowRoot);
    }
  };
  walk(document.documentElement);
  return out;
})()`;
for (const url of ["chrome://newtab", "chrome://settings/help"]) {
  await cdp("Page.enable");
  await cdp("Page.navigate", { url });
  await new Promise((r) => setTimeout(r, 2500));
  const { result } = await cdp("Runtime.evaluate", { expression: collect, returnByValue: true });
  console.log(url, "残留:", result.value.length ? result.value : "无");
}
```

输出应全部为“无”。

## 6. 注意事项

- **新标签页“自定义”按钮本身去不掉**：它是内置新标签页的标准按钮，只能改文案；
  要让整个按钮消失，需要做一个自定义新标签页扩展（`chrome_url_overrides.newtab` 接管）。
- **`chrome.exe` / `chrome.dll` 里的版本资源未改**：任务管理器里进程显示名等仍可能是
  “Chrome for Testing”，属于系统级品牌，改动风险大（PE 二进制补丁），本次未处理。
- **升级 Chromium 版本**：`build.ps1` 顶部 `$ChromeVersion` 升级后，新解压的语言包会
  被自动重新替换；若谷歌改了 `.pak` 格式或品牌字符串写法，脚本需相应适配。
- **首次运行约 20 秒退出**：这是既有行为（首次运行的欢迎页清理会关掉最后一个标签页，
  加上 `BackgroundModeEnabled=0` 策略，关最后一个窗口即整体退出），与品牌替换无关；
  二次启动正常。
- 脚本只处理文本资源；图片/HTML 等二进制资源保持原样，不参与替换。
