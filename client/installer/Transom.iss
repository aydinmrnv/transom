; Transom per-user Windows installer.
; Build with:
;   ISCC.exe /DAppVersion=0.2.0 client\installer\Transom.iss

#ifndef AppVersion
  #define AppVersion "0.4.2"
#endif

#define AppName "Transom"
#define AppPublisher "Transom"
#define AppExeName "transom-client.exe"

[Setup]
AppId={{D6C3D6F7-0D1B-49B7-9B3F-2C32B48E1B3E}
AppName={#AppName}
AppPublisher={#AppPublisher}
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\Transom
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=TransomSetup-v{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\resources\transom.ico
Uninstallable=yes
UninstallDisplayIcon={app}\{#AppExeName}
CloseApplications=yes
RestartApplications=no
UsePreviousAppDir=yes
AllowNoIcons=no
SetupLogging=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "..\target\release\transom-client.exe"; DestDir: "{app}"; Flags: ignoreversion restartreplace
Source: "..\target\release\transom-updater.exe"; DestDir: "{app}"; Flags: ignoreversion restartreplace
Source: "..\README.md"; DestDir: "{app}"; DestName: "README-Windows.md"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\README.md"; DestDir: "{app}"; DestName: "Artwork-notices.md"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Parameters: "run"; WorkingDir: "{app}"
Name: "{autoprograms}\{#AppName}\Check for updates"; Filename: "{app}\transom-updater.exe"; Parameters: "--check --current-version {#AppVersion}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Parameters: "run"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Parameters: "run"; WorkingDir: "{app}"; Description: "Launch Transom"; Flags: nowait postinstall skipifsilent
