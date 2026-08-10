; Course-Thru（课速通）安装脚本 (Inno Setup)
; 编译: ISCC.exe "/DDIST=<dist目录绝对路径>" ["/DMyAppVersion=<x.y.z>"] installer.iss
; 产出: <项目根>\dist-installer\Course-Thru-<版本>-Setup.exe
; 版本号由 build.ps1 注入（方案见 VERSION.md），未注入时默认 1.0.0

#ifndef DIST
  #define DIST "dist"
#endif
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#define MyAppName "Course-Thru"
#define MyAppExeName "Course-Thru.exe"

[Setup]
AppId={{F8E1B0C4-9A6D-4E2B-8C3F-5D7A1B9C2E4A}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=Course-Thru
DefaultDirName={localappdata}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist-installer
OutputBaseFilename=Course-Thru-{#MyAppVersion}-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; 品牌：安装包图标与向导图（assets\ 目录由 generate-assets.py 从 logo\logo.png 生成）
SetupIconFile=assets\app.ico
WizardImageFile=assets\wizard-image.bmp
WizardSmallImageFile=assets\wizard-small-image.bmp
UninstallDisplayIcon={app}\{#MyAppExeName}
Uninstallable=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
; 桌面图标任务不加 Flags: unchecked —— 缺省即默认勾选，安装完成桌面直接出现快捷方式
Name: "desktopicon"; Description: "创建桌面快捷方式(&D)"; GroupDescription: "附加任务:"

[Files]
Source: "{#DIST}\chrome\*"; DestDir: "{app}\chrome"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#DIST}\extensions\*"; DestDir: "{app}\extensions"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#DIST}\course-thru\*"; DestDir: "{app}\course-thru"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#DIST}\profile_seed\*"; DestDir: "{app}\profile_seed"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#DIST}\Course-Thru.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#DIST}\config.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#DIST}\version.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "stop-browser.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; 快捷方式名称用中文品牌名「课速通」（用户可见，安装目录/进程名仍为 Course-Thru）
Name: "{autoprograms}\课速通"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\课速通"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "立即启动 课速通"; Flags: nowait postinstall skipifsilent

; 卸载前关闭本程序启动的浏览器进程（调用随包分发的 stop-browser.ps1，按路径过滤，不影响用户的 Google Chrome）
[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\stop-browser.ps1"""; Flags: runhidden

; 卸载时删除整个应用目录（含用户数据）
[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
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

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    DeleteCftPolicies();
end;
