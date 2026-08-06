# build.ps1 — Course-Thru（课速通）一键构建脚本（Windows）
# 流程：下载组件(Chromium/ScriptCat/OCS) → 注入固定 key → 编译启动器 → 生成预置 profile → 组装 dist 发布目录
# 用法: powershell -ExecutionPolicy Bypass -File build.ps1 [-SkipProfile] [-NoNsis]
param(
    [switch]$SkipProfile,  # 跳过 profile 生成（复用已有 dist\profile_seed）
    [switch]$NoNsis        # 跳过 NSIS 安装包
)
$ErrorActionPreference = "Stop"

$Root    = $PSScriptRoot  # 项目根（脚本本身位于根目录）
$Tools   = Join-Path $Root ".tools"
$Dist    = Join-Path $Root "dist"
$KeysDir = Join-Path $Root "keys"

# ------- 组件版本（固定以保证可复现） -------
$ChromeVersion = "152.0.7977.13"
$ScriptCatTag  = "v1.4.0"
$OcsTag        = "4.15.3"

$ChromeUrl     = "https://registry.npmmirror.com/-/binary/chrome-for-testing/$ChromeVersion/win64/chrome-win64.zip"
$ScriptCatUrl  = "https://github.com/scriptscat/scriptcat/releases/download/$ScriptCatTag/scriptcat-$ScriptCatTag-chrome.zip"
# OCS 脚本已随仓库维护（extensions\ocs.user.js），不再从 GitHub Release 下载；
# $OcsTag 仅作为本地文件的版本一致性校验参考。

function Info($m)   { Write-Host "[build] $m" -ForegroundColor Cyan }
function Warn($m)   { Write-Host "[build] 警告: $m" -ForegroundColor Yellow }
function Fail($m)   { Write-Host "[build] 错误: $m" -ForegroundColor Red; exit 1 }

# 读取系统代理（curl.exe 不读 WinINET 设置，需要显式传入）
function Get-SystemProxy {
    $s = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($s.ProxyEnable -eq 1 -and $s.ProxyServer) { return $s.ProxyServer }
    return $null
}

# 幂等下载：已有文件则跳过（开发迭代加速）。
# 直连失败时自动回退到系统代理（兼容国内网络/代理环境）。
function Download($url, $out) {
    if (Test-Path $out) { Info "已存在，跳过下载: $out"; return }
    Info "下载: $url"
    & curl.exe -L --max-time 500 -o $out $url
    if ($LASTEXITCODE -ne 0) {
        $proxy = Get-SystemProxy
        if ($proxy) {
            Warn "直连失败（exit $LASTEXITCODE），改用系统代理 $proxy 重试"
            Remove-Item $out -Force -ErrorAction SilentlyContinue
            & curl.exe -L --max-time 500 --proxy "http://$proxy" -o $out $url
        }
    }
    if ($LASTEXITCODE -ne 0) { Fail "下载失败: $url" }
}

# 解压 zip（优先用系统 tar，支持 zip）
function Unzip($zip, $dest) {
    if (Test-Path $dest) { Info "已存在，跳过解压: $dest"; return }
    New-Item -ItemType Directory -Force $dest | Out-Null
    & "$env:SystemRoot\System32\tar.exe" -xf $zip -C $dest
    if ($LASTEXITCODE -ne 0) { Fail "解压失败: $zip" }
}

# ============ 1. 准备 / 注入固定扩展 key ============
New-Item -ItemType Directory -Force $Tools, $KeysDir | Out-Null
$keyFile = Join-Path $KeysDir "scriptcat.key"
# 扩展 ID 由公钥唯一决定（=> hodgdaljmnbiliahlpcjcpiphnkbmfff）。
# 公钥缺失时禁止自动生成新密钥对：换 key = 换 ID，会让所有已有用户
# profile 里的脚本数据失效。必须通过 git 恢复该文件，而不是重新生成。
if (-not (Test-Path $keyFile)) {
    Fail "缺少 keys\scriptcat.key！扩展 ID 由此公钥决定，删除/丢失会改变 ID 并使既有用户数据失效。请用 git restore 恢复该文件后重试。"
}
$ScriptCatKey = (Get-Content $keyFile -Raw).Trim()
if (-not $ScriptCatKey) {
    Fail "keys\scriptcat.key 内容为空，请通过 git 恢复该文件。"
}
Info "复用固定 key（扩展 ID 恒定）: $($ScriptCatKey.Substring(0,32))..."

# 私钥不参与构建（unpacked 扩展加载无需签名校验），仅在将来需要
# CRX 签名 / 商店上架时才有用。它已被 .gitignore 排除，请自行在安全位置
# 备份；缺失不阻塞构建，仅提示。
$privKeyFile = Join-Path $KeysDir "scriptcat_private.pem"
if (-not (Test-Path $privKeyFile)) {
    Warn "keys\scriptcat_private.pem 不存在（构建不依赖它）。如将来需要 CRX 签名/商店上架，请确保该私钥有安全备份。"
}

# ============ 2. 下载组件 ============
$chromeZip   = Join-Path $Tools "chrome-win64.zip"
$scriptcatZip = Join-Path $Tools "scriptcat.zip"
$ocsFile     = Join-Path $Root "extensions\ocs.user.js"
Download $ChromeUrl $chromeZip
Download $ScriptCatUrl $scriptcatZip

# OCS 脚本本地化：必须随仓库存在，缺失即报错（避免静默使用旧缓存）
if (-not (Test-Path $ocsFile)) {
    Fail "缺少本地 OCS 脚本 $ocsFile。请从 https://github.com/ocsjs/ocsjs/releases/download/$OcsTag/ocs.user.js 下载后放入 extensions\ 目录。"
}
$ocsVersion = Select-String -Path $ocsFile -Pattern '@version\s+([0-9.]+)' | Select-Object -First 1
if ($ocsVersion -and $ocsVersion.Matches[0].Groups[1].Value -ne $OcsTag) {
    Warn "本地 OCS 脚本版本 $($ocsVersion.Matches[0].Groups[1].Value) 与期望 $OcsTag 不一致，请确认是否需要升级并更新 $OcsTag"
}

# ============ 3. 准备 Chromium ============
$distChrome = Join-Path $Dist "chrome"
if (-not (Test-Path (Join-Path $distChrome "chrome.exe"))) {
    Info "解压 Chromium..."
    New-Item -ItemType Directory -Force $Dist | Out-Null
    $tmp = Join-Path $Tools "chrome-unpack"
    Unzip $chromeZip $tmp
    Get-ChildItem $tmp -Directory | Where-Object { Test-Path (Join-Path $_.FullName "chrome.exe") } |
        ForEach-Object { Copy-Item $_.FullName $distChrome -Recurse -Force }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ============ 4. 准备 ScriptCat 扩展（注入 key）============
$extDir = Join-Path $Dist "extensions\scriptcat"
if (-not (Test-Path (Join-Path $extDir "manifest.json"))) {
    Info "解压并装配 ScriptCat..."
    $tmp = Join-Path $Tools "scriptcat-unpack"
    Unzip $scriptcatZip $tmp
    $src = Get-ChildItem $tmp -Recurse -Filter manifest.json | Select-Object -First 1 | ForEach-Object { $_.DirectoryName }
    if (-not $src) { Fail "ScriptCat 解压结构异常" }
    Copy-Item $src $extDir -Recurse -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
# 注入 key（每次构建都确保存在）
$mfPath = Join-Path $extDir "manifest.json"
$mf = [System.IO.File]::ReadAllText($mfPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
if (-not $mf.key -or $mf.key -ne $ScriptCatKey) {
    Info "注入固定 key 到 ScriptCat manifest..."
    $mf | Add-Member -NotePropertyName "key" -NotePropertyValue $ScriptCatKey -Force
    $json = $mf | ConvertTo-Json -Depth 20 -Compress
    [System.IO.File]::WriteAllText($mfPath, $json, [System.Text.UTF8Encoding]::new($false))
}

# ============ 4.5 打包本地 OCS 脚本到产物 ============
# OCS 已随仓库维护，直接复制进便携版/安装版（用户可在脚本猫中手动重新导入；
# 预置 profile 中的安装由 gen-profile.mjs 完成）。
$ocsDist = Join-Path (Split-Path $extDir -Parent) "ocs.user.js"
Copy-Item -LiteralPath $ocsFile -Destination $ocsDist -Force

# 屏蔽 ScriptCat 安装成功欢迎页：unpacked 扩展每次启动都会触发
# onInstalled(reason=install)，不屏蔽则每次打开浏览器都会弹出安装完成页。
# 只把条件改为恒 false 以保留代码结构；若未来版本改动该段代码则警告。
$swPath = Join-Path $extDir "src\service_worker.js"
$swFrom = 'if("install"===e.reason)chrome.tabs.create({url:`${q}${af}/docs/use/install_comple`})'
$swTo   = 'if("install"===e.reason&&false)chrome.tabs.create({url:`${q}${af}/docs/use/install_comple`})'
if (-not (Test-Path $swPath)) {
    Warn "未找到 ScriptCat service_worker.js，跳过欢迎页屏蔽"
} else {
    # 必须用 UTF-8 显式读写：PS 5.1 的 Get-Content 默认按 ANSI/GBK 解码，
    # 会把 UTF-8 中文读成乱码再写回，导致扩展脚本语法损坏、无法加载。
    $swText = [System.IO.File]::ReadAllText($swPath, [System.Text.Encoding]::UTF8)
    if ($swText.Contains($swFrom)) {
        $swText = $swText.Replace($swFrom, $swTo)
        [System.IO.File]::WriteAllText($swPath, $swText, [System.Text.UTF8Encoding]::new($false))
        Info "已屏蔽 ScriptCat 安装成功欢迎页（每次启动不再弹出）"
    } elseif ($swText.Contains($swTo)) {
        Info "ScriptCat 欢迎页补丁已存在（复用已有扩展目录，无需重复打补丁）"
    } else {
        Warn "service_worker.js 中未找到欢迎页代码，升级后可能重新弹出；请检查 ScriptCat 版本"
    }
}

# ============ 5. 编译 Go 启动器 ============
$goExe = Join-Path $Tools "go\bin\go.exe"
if (-not (Test-Path $goExe)) {
    Info "未找到 Go SDK，准备下载..."
    $goZip = Join-Path $Tools "go.zip"
    if (-not (Test-Path $goZip)) {
        # 备选源：golang.google.cn / mirrors.aliyun.com
        Download "https://mirrors.aliyun.com/golang/go1.26.5.windows-amd64.zip" $goZip
    }
    # 解压到独立临时目录再移动（不能直接解压到 $Tools：它已存在，
    # 而 Unzip 对已存在的目标会跳过，导致全新环境永远解压不出来）
    $goUnpack = Join-Path $Tools "go-unpack"
    Unzip $goZip $goUnpack
    $goDir = Get-ChildItem $goUnpack -Directory | Select-Object -First 1
    if (-not $goDir -or -not (Test-Path (Join-Path $goDir.FullName "bin\go.exe"))) {
        Fail "Go SDK 解压失败"
    }
    Move-Item $goDir.FullName (Join-Path $Tools "go")
    Remove-Item $goUnpack -Recurse -Force -ErrorAction SilentlyContinue
}
Info "编译启动器..."
& $goExe -C $Root build -ldflags "-H=windowsgui" -o (Join-Path $Dist "Course-Thru.exe")
if ($LASTEXITCODE -ne 0) { Fail "Go 编译失败" }

# ============ 6. 生成预置 profile（开箱即用核心步骤）============
$profileSeed = Join-Path $Dist "profile_seed"
if (-not $SkipProfile -and -not (Test-Path (Join-Path $profileSeed "Default"))) {
    Info "生成预置 profile（自动开启 userScripts 并安装 OCS 脚本）..."
    # 先清空临时 profile
    $tempProfile = Join-Path $Tools "profile-tmp"
    if (Test-Path $tempProfile) { Remove-Item $tempProfile -Recurse -Force -ErrorAction SilentlyContinue }
    node (Join-Path $Root "gen-profile.mjs") `
        --chromium (Join-Path $distChrome "chrome.exe") `
        --ext $extDir `
        --profile $tempProfile `
        --ocs $ocsFile `
        --port 9333
    if ($LASTEXITCODE -ne 0) { Fail "profile 生成失败" }
    # 复制并清理缓存（只保留扩展数据与偏好）
    if (Test-Path $profileSeed) { Remove-Item $profileSeed -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force $profileSeed | Out-Null
    Copy-Item (Join-Path $tempProfile "Local State") $profileSeed -Force
    Copy-Item (Join-Path $tempProfile "Default") (Join-Path $profileSeed "Default") -Recurse -Force
    # 清理会话恢复数据：生成流程打开的标签/窗口不应随种子分发
    foreach ($sd in @("Sessions", "Sessions_Encrypted")) {
        $sp = Join-Path $profileSeed "Default\$sd"
        if (Test-Path $sp) { Remove-Item $sp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item $tempProfile -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Info "跳过 profile 生成（或已有 profile_seed）"
}
if (-not (Test-Path (Join-Path $profileSeed "Default"))) { Warn "profile_seed 不存在，用户首次启动时不会自动带脚本" }

# ============ 7. 生成 config.json ============
$config = @{
    defaultUrl = ""
    extraArgs  = @()
    appName    = "Course-Thru"
    extensions = @("extensions/scriptcat")
} | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $Dist "config.json"), $config)

# ============ 7.5 清理产物内残留（不应进入安装包） ============
# 开发期 gen-profile 曾把临时 profile 写到 dist\chrome\.tools\profile-tmp，
# 这类残留会随安装包一起分发。Chromium 目录内不应存在 .tools，发现即清理。
$chromeTools = Join-Path $Dist "chrome\.tools"
if (Test-Path $chromeTools) {
    Warn "发现 dist\chrome\.tools 残留（开发期临时数据），已清理，避免混入安装包"
    Remove-Item $chromeTools -Recurse -Force
}

# ============ 8. 组装 Inno Setup 安装包 ============
# 注：最初计划用 NSIS，但其官方二进制只托管在 SourceForge（国内不可达），
# 经与用户确认改用 Inno Setup（官网/GitHub 可达，功能等价）。
if (-not $NoNsis) {
    $iscc = Join-Path $Tools "inno\ISCC.exe"
    if (-not (Test-Path $iscc)) {
        Info "未找到 Inno Setup，准备下载并静默安装..."
        $innoInstaller = Join-Path $Tools "innosetup-6.7.3.exe"
        Download "https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe" $innoInstaller
        $ip = Start-Process -FilePath $innoInstaller -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-", "/DIR=$(Join-Path $Tools "inno")") -Wait -PassThru
        if ($ip.ExitCode -ne 0) { Warn "Inno Setup 安装失败（退出码 $($ip.ExitCode)）" }
        $iscc = Join-Path $Tools "inno\ISCC.exe"
    }
    # 中文语言包（Inno Setup 官方包不含中文）
    $zhLang = Join-Path $Tools "inno\Languages\ChineseSimplified.isl"
    if (-not (Test-Path $zhLang)) {
        Info "下载中文语言包..."
        Download "https://raw.githubusercontent.com/jrsoftware/issrc/main/Files/Languages/ChineseSimplified.isl" $zhLang
    }
    if (Test-Path $iscc) {
        Info "编译 Inno Setup 安装程序..."
        & $iscc "/DDIST=$Dist" (Join-Path $Root "installer.iss")
        if ($LASTEXITCODE -ne 0) { Warn "安装包编译失败" }
    } else {
        Warn "Inno Setup 不可用，跳过安装包。dist 目录已可手动使用。"
    }
}

Info "构建完成！发布目录: $Dist"
Info "启动方式: 双击 $Dist\Course-Thru.exe"
