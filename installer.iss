; BrowserForLazy 安装脚本 (Inno Setup)
; 编译: ISCC.exe "/DDIST=<dist目录绝对路径>" installer.iss
; 产出: <项目根>\dist-installer\BrowserForLazySetup.exe

#ifndef DIST
  #define DIST "dist"
#endif

#define MyAppName "BrowserForLazy"
#define MyAppVersion "1.0.0"
#define MyAppExeName "BrowserForLazy.exe"

[Setup]
AppId={{F8E1B0C4-9A6D-4E2B-8C3F-5D7A1B9C2E4A}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=BrowserForLazy
DefaultDirName={localappdata}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist-installer
OutputBaseFilename=BrowserForLazySetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}
Uninstallable=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式(&D)"; GroupDescription: "附加任务:"; Flags: unchecked

[Files]
Source: "{#DIST}\chrome\*"; DestDir: "{app}\chrome"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#DIST}\extensions\*"; DestDir: "{app}\extensions"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#DIST}\profile_seed\*"; DestDir: "{app}\profile_seed"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#DIST}\BrowserForLazy.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#DIST}\config.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "stop-browser.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "立即启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent

; 卸载前关闭本程序启动的浏览器进程（调用随包分发的 stop-browser.ps1，按路径过滤，不影响用户的 Google Chrome）
[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\stop-browser.ps1"""; Flags: runhidden

; 卸载时删除整个应用目录（含用户数据）
[UninstallDelete]
Type: filesandordirs; Name: "{app}"
