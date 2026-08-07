# build.ps1 — Course-Thru（课速通）一键构建脚本（Windows）
# 流程：下载组件(Chromium/ScriptCat/OCS) → 注入固定 key → 编译启动器 → 生成预置 profile → 组装 dist 发布目录
# 用法: powershell -ExecutionPolicy Bypass -File build.ps1 [-SkipProfile] [-NoNsis] [-Version x.y.z]
param(
    [switch]$SkipProfile,  # 跳过 profile 生成（复用已有 dist\profile_seed）
    [switch]$NoNsis,       # 跳过安装包（只产出便携版 dist，不递增版本号）
    [string]$Version       # 手动指定本次构建版本（如 1.1.0），完整构建时写回 version.txt
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
# 自动更新：脚本自带官方「更新模块」，且 gen-profile.mjs 预置时开启 ScriptCat 自动更新
# （checkUpdate: true，更新源为 GitHub 最新 Release 资产，见 gen-profile.mjs 的 origin）。

# ------- 语言裁剪（只保留中英繁三语，减小发布体积） -------
# Chromium locales：只保留 en-US / zh-CN / zh-TW（含 FEMININE/MASCULINE/NEUTER
# 变体文件）。Chrome 找不到首选语言包时会自动回退到 en-US，不会报错。
# ScriptCat 扩展 _locales：只保留 en / zh_CN / zh_TW，其 manifest 声明
# default_locale=en，浏览器语言被裁剪时扩展文案自动回退英文。
$KeepChromeLocales = @("en-US", "zh-CN", "zh-TW")
$KeepExtLocales    = @("en", "zh_CN", "zh_TW")

function Info($m)   { Write-Host "[build] $m" -ForegroundColor Cyan }
function Warn($m)   { Write-Host "[build] 警告: $m" -ForegroundColor Yellow }
function Fail($m)   { Write-Host "[build] 错误: $m" -ForegroundColor Red; exit 1 }

# ------- 应用版本（单一来源 version.txt，完整方案见 VERSION.md） -------
# 版本格式 x.y.z。默认完整构建（产出安装包）patch 自动 +1 并写回 version.txt；
# -NoNsis 便携调试构建复用当前版本、不递增不写回；-Version 手动覆盖（里程碑版本用）。
$VersionFile = Join-Path $Root "version.txt"
$AppVersion  = "1.0.0"
if (Test-Path -LiteralPath $VersionFile) {
    $v = (Get-Content -LiteralPath $VersionFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($v -match '^\d+\.\d+\.\d+$') { $AppVersion = $v }
    else { Warn "version.txt 内容不合法（应为 x.y.z）: '$v'，使用默认 1.0.0" }
}
if ($Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { Fail "参数 -Version 格式应为 x.y.z，收到: $Version" }
    $AppVersion = $Version
    $versionWhy = "手动指定 -Version"
} elseif ($NoNsis) {
    $versionWhy = "-NoNsis 便携调试，复用版本号"
} else {
    $vp = $AppVersion.Split('.')
    $vp[2] = [string]([int]$vp[2] + 1)
    $AppVersion = $vp -join '.'
    $versionWhy = "完整构建自动递增"
}
if (-not $NoNsis) {
    [IO.File]::WriteAllText($VersionFile, $AppVersion, [System.Text.UTF8Encoding]::new($false))
}
Info "应用版本: $AppVersion（$versionWhy）"

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

# 语言包裁剪（幂等：已有 dist 也会在下次构建时补齐裁剪）
$localesDir = Join-Path $distChrome "locales"
if (Test-Path $localesDir) {
    $keepPattern = "^($(($KeepChromeLocales | ForEach-Object { [regex]::Escape($_) }) -join '|'))(_(FEMININE|MASCULINE|NEUTER))?\.pak$"
    $removedLocales = @(Get-ChildItem $localesDir -Filter "*.pak" -File | Where-Object { $_.Name -notmatch $keepPattern })
    foreach ($f in $removedLocales) { Remove-Item -LiteralPath $f.FullName -Force }
    if ($removedLocales.Count -gt 0) {
        Info "已裁剪 Chromium 语言包：删除 $($removedLocales.Count) 个，保留 $($KeepChromeLocales -join ' / ')"
    }
}

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

# ============ 3.55 关于页版权署名替换（构建期）============
# Chromium 自带的 ABOUT 文件固定写着 "Copyright 2026 Google LLC"，全新解压后
# 会恢复原文，因此在这里幂等替换为自有署名；已替换过的产物保持不变。
$aboutFile = Join-Path $distChrome "ABOUT"
$aboutFrom = "Copyright 2026 Google LLC. All rights reserved."
$aboutTo   = "Copyright 2026 IceFire_Icer. All rights reserved."
if (Test-Path $aboutFile) {
    $aboutText = [System.IO.File]::ReadAllText($aboutFile, [System.Text.Encoding]::ASCII)
    if ($aboutText.Contains($aboutFrom)) {
        $aboutText = $aboutText.Replace($aboutFrom, $aboutTo)
        [System.IO.File]::WriteAllText($aboutFile, $aboutText, [System.Text.Encoding]::ASCII)
        Info "已替换关于页版权署名（Google LLC -> IceFire_Icer）"
    } elseif ($aboutText.Contains($aboutTo)) {
        Info "关于页版权署名已替换（复用已有 dist\chrome，无需重复）"
    } else {
        Warn "ABOUT 中未找到 '$aboutFrom'，请检查 Chromium 版本是否更新了版权文案"
    }
} else {
    Warn "未找到 $aboutFile，跳过关于页版权署名替换"
}

# ============ 3.6 品牌 logo 图片资源替换（构建期）============
# 用 logo\logo.png 生成全套图标资产到 assets\（app.ico / 安装向导图 /
# pak 内嵌 PNG / ScriptCat 扩展图标），再把 Chromium 三个 pak 里的
# Chrome 产品 logo 图片按“四色品牌色占比”启发式替换为自有 logo。
# 方案与验证见 LOGO-REPLACEMENT.md；脚本均幂等，可重复执行。
$assetsDir     = Join-Path $Root "assets"
$logoGenScript = Join-Path $Root "generate-assets.py"
$logoPatchScript = Join-Path $Root "patch-logo.py"
$iconPatchScript = Join-Path $Root "patch-icons.py"
$logoPng        = Join-Path $Root "logo\logo.png"
foreach ($s in @($logoGenScript, $logoPatchScript, $iconPatchScript)) {
    if (-not (Test-Path $s)) { Fail "缺少 logo 构建脚本 $s" }
}
if (-not (Test-Path $logoPng)) { Fail "缺少 logo 源文件 $logoPng（请放入 logo\logo.png）" }
Info "生成 logo 资产（assets\app.ico / 向导图 / pak 内嵌 PNG / ScriptCat 图标）..."
& python $logoGenScript
if ($LASTEXITCODE -ne 0) { Fail "logo 资产生成失败（需要 Pillow：python -m pip install Pillow）" }
Info "替换 Chromium 产品 logo 图片资源（三个 pak）..."
& python $logoPatchScript `
    $assetsDir `
    (Join-Path $distChrome "resources.pak") `
    (Join-Path $distChrome "chrome_100_percent.pak") `
    (Join-Path $distChrome "chrome_200_percent.pak")
if ($LASTEXITCODE -ne 0) { Fail "pak 产品 logo 替换失败" }

# ============ 3.7 浏览器 PE 图标替换（构建期）============
# chrome.exe 主图标组是命名资源 IDR_MAINFRAME、chrome.dll 是数值组 101，
# rcedit 只会新增未命名组而无法替换它们，故用 patch-icons.py 直接重建
# 资源段（幂等）。chrome_pwa_launcher.exe 的组为数值 1，一并替换。
Info "替换浏览器 PE 图标（chrome.exe / chrome.dll / chrome_pwa_launcher.exe）..."
& python $iconPatchScript (Join-Path $distChrome "chrome.exe") --logo $logoPng --groups IDR_MAINFRAME,IDR_X001_APP_LIST
if ($LASTEXITCODE -ne 0) { Fail "chrome.exe 图标替换失败" }
& python $iconPatchScript (Join-Path $distChrome "chrome.dll") --logo $logoPng --groups 101
if ($LASTEXITCODE -ne 0) { Fail "chrome.dll 图标替换失败" }
& python $iconPatchScript (Join-Path $distChrome "chrome_pwa_launcher.exe") --logo $logoPng --groups 1
if ($LASTEXITCODE -ne 0) { Fail "chrome_pwa_launcher.exe 图标替换失败" }

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
# 语言包裁剪：ScriptCat _locales 只保留中英繁三语（幂等）
$extLocalesDir = Join-Path $extDir "_locales"
if (Test-Path $extLocalesDir) {
    $removedExtLocales = @(Get-ChildItem $extLocalesDir -Directory | Where-Object { $_.Name -notin $KeepExtLocales })
    foreach ($d in $removedExtLocales) { Remove-Item -LiteralPath $d.FullName -Recurse -Force }
    if ($removedExtLocales.Count -gt 0) {
        Info "已裁剪 ScriptCat 语言包：删除 $($removedExtLocales.Count) 个，保留 $($KeepExtLocales -join ' / ')"
    }
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

# ============ 4.3 替换 ScriptCat 扩展图标 ============
# manifest 的 action.default_icon / icons 与弹窗/选项页头部 <img> 都引用
# assets\logo*.png，覆盖同名文件即全链路生效；profile_seed 无扩展文件副本，
# 不需要重新生成 profile。
$scLogoDir = Join-Path $extDir "assets"
if (Test-Path $scLogoDir) {
    Info "替换 ScriptCat 扩展图标（assets\scriptcat\* -> $scLogoDir）..."
    Copy-Item -Path (Join-Path $assetsDir "scriptcat\*") -Destination $scLogoDir -Force
} else {
    Warn "未找到 ScriptCat assets 目录 $scLogoDir，跳过扩展图标替换"
}

# ============ 4.5 打包本地 OCS 脚本到产物 ============
# OCS 已随仓库维护，直接复制进便携版/安装版（用户可在脚本猫中手动重新导入；
# 预置 profile 中的安装由 gen-profile.mjs 完成）。
$ocsDist = Join-Path (Split-Path $extDir -Parent) "ocs.user.js"
Copy-Item -LiteralPath $ocsFile -Destination $ocsDist -Force

# 打包百度默认搜索引擎扩展（chrome_settings_overrides 把默认搜索引擎设为百度，
# 这是未托管机器上唯一可靠的方式：DefaultSearchProvider* 策略在未加入域的机器上会被忽略）。
$baiduExt = Join-Path $Root "extensions\baidu-search"
if (-not (Test-Path (Join-Path $baiduExt "manifest.json"))) {
    Fail "缺少默认搜索引擎扩展 $baiduExt\manifest.json"
}
$baiduDist = Join-Path $Dist "extensions\baidu-search"
# 目标目录存在时先删除再整体复制：直接 Copy-Item -Recurse 到已存在目录会
# 嵌套成 baidu-search\baidu-search\...，旧 manifest 残留导致产物不是最新。
if (Test-Path $baiduDist) { Remove-Item $baiduDist -Recurse -Force }
Copy-Item -LiteralPath $baiduExt -Destination $baiduDist -Recurse -Force

# 打包内置主页（course-thru\ -> dist\course-thru）：启动器 defaultUrl 留空时以
# file:// 打开该页面。页面内资源全部相对路径引用，随程序分发即可自包含。
$homepageSrc = Join-Path $Root "course-thru"
if (-not (Test-Path (Join-Path $homepageSrc "index.html"))) {
    Fail "缺少内置主页 $homepageSrc\index.html（course-thru 文件夹是浏览器主页，不能删除）"
}
$homepageDist = Join-Path $Dist "course-thru"
if (Test-Path $homepageDist) { Remove-Item $homepageDist -Recurse -Force }
Copy-Item -LiteralPath $homepageSrc -Destination $homepageDist -Recurse -Force
Info "已打包内置主页: $homepageSrc -> $homepageDist"

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

# 启动器图标：Go 编译产物默认无图标资源，构建后把 logo 图标注入新资源段
& python $iconPatchScript (Join-Path $Dist "Course-Thru.exe") --logo $logoPng --add-main-icon
if ($LASTEXITCODE -ne 0) { Fail "启动器图标注入失败" }

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
    extensions = @("extensions/scriptcat", "extensions/baidu-search")
} | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $Dist "config.json"), $config)
# 产物内版本文件（为将来 UI 显示版本 / 自动更新比较预留）
[IO.File]::WriteAllText((Join-Path $Dist "version.txt"), "$AppVersion`r`n", [System.Text.UTF8Encoding]::new($false))

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
        Info "编译 Inno Setup 安装程序（版本 $AppVersion）..."
        & $iscc "/DDIST=$Dist" "/DMyAppVersion=$AppVersion" (Join-Path $Root "installer.iss")
        if ($LASTEXITCODE -ne 0) { Warn "安装包编译失败" }
    } else {
        Warn "Inno Setup 不可用，跳过安装包。dist 目录已可手动使用。"
    }
}

Info "构建完成！发布目录: $Dist（版本 $AppVersion）"
if (-not $NoNsis) { Info "安装包: $(Join-Path $Root "dist-installer\Course-Thru-$AppVersion-Setup.exe")" }
Info "启动方式: 双击 $Dist\Course-Thru.exe"
