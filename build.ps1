# build.ps1 — BrowserForLazy 一键构建脚本（Windows）
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
$OcsUrl        = "https://github.com/ocsjs/ocsjs/releases/download/$OcsTag/ocs.user.js"

function Info($m)   { Write-Host "[build] $m" -ForegroundColor Cyan }
function Warn($m)   { Write-Host "[build] 警告: $m" -ForegroundColor Yellow }
function Fail($m)   { Write-Host "[build] 错误: $m" -ForegroundColor Red; exit 1 }

# 幂等下载：已有文件则跳过（开发迭代加速）
function Download($url, $out) {
    if (Test-Path $out) { Info "已存在，跳过下载: $out"; return }
    Info "下载: $url"
    & curl.exe -L --max-time 500 -o $out $url
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
if (-not (Test-Path $keyFile)) {
    Info "生成固定扩展 key（扩展 ID 由此确定，请勿删除）..."
    # 用 node 生成（兼容 .NET Framework 下的 PowerShell 5.1）
    $keyJson = node -e "const {generateKeyPairSync}=require('crypto');const {publicKey,privateKey}=generateKeyPairSync('rsa',{modulusLength:4096});process.stdout.write(JSON.stringify({pub:publicKey.export({type:'spki',format:'der'}).toString('base64'),priv:privateKey.export({type:'pkcs8',format:'der'}).toString('base64')}))"
    if ($LASTEXITCODE -ne 0 -or -not $keyJson) { Fail "node 生成 key 失败" }
    $keys = $keyJson | ConvertFrom-Json
    [IO.File]::WriteAllText($keyFile, $keys.pub)
    $privPem = "-----BEGIN PRIVATE KEY-----`n" +
               ([regex]::Replace($keys.priv, '(.{64})', "`$1`n")) + "`n-----END PRIVATE KEY-----"
    [IO.File]::WriteAllText((Join-Path $KeysDir "scriptcat_private.pem"), $privPem)
    Info "已生成 key: $($keys.pub.Substring(0,32))..."
} else {
    $existingKey = (Get-Content $keyFile -Raw).Trim()
    Info "复用已有 key: $($existingKey.Substring(0,32))..."
}
$ScriptCatKey = (Get-Content $keyFile -Raw).Trim()

# ============ 2. 下载组件 ============
$chromeZip   = Join-Path $Tools "chrome-win64.zip"
$scriptcatZip = Join-Path $Tools "scriptcat.zip"
$ocsFile     = Join-Path $Tools "ocs.user.js"
Download $ChromeUrl $chromeZip
Download $ScriptCatUrl $scriptcatZip
Download $OcsUrl $ocsFile

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
$mf = Get-Content $mfPath -Raw | ConvertFrom-Json
if (-not $mf.key -or $mf.key -ne $ScriptCatKey) {
    Info "注入固定 key 到 ScriptCat manifest..."
    $mf | Add-Member -NotePropertyName "key" -NotePropertyValue $ScriptCatKey -Force
    $json = $mf | ConvertTo-Json -Depth 20 -Compress
    [IO.File]::WriteAllText($mfPath, $json)
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
    Unzip $goZip $Tools
    # go.zip 解压出 go/ 目录
    if (-not (Test-Path $goExe)) { Fail "Go SDK 解压失败" }
}
Info "编译启动器..."
& $goExe -C $Root build -ldflags "-H=windowsgui" -o (Join-Path $Dist "BrowserForLazy.exe")
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
    Remove-Item $tempProfile -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Info "跳过 profile 生成（或已有 profile_seed）"
}
if (-not (Test-Path (Join-Path $profileSeed "Default"))) { Warn "profile_seed 不存在，用户首次启动时不会自动带脚本" }

# ============ 7. 生成 config.json ============
$config = @{
    defaultUrl = ""
    extraArgs  = @()
    appName    = "BrowserForLazy"
    extensions = @("extensions/scriptcat")
} | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $Dist "config.json"), $config)

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
        & curl.exe -sL --max-time 30 -o $zhLang "https://raw.githubusercontent.com/jrsoftware/issrc/main/Files/Languages/ChineseSimplified.isl"
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
Info "启动方式: 双击 $Dist\BrowserForLazy.exe"
