; Clamshell Windows host installer.
; Packages the self-contained single-file ClamshellServer.exe (produced by
; `dotnet publish`, see .github/workflows/release.yml) into a standard
; Windows installer. MyAppVersion is passed in via /DMyAppVersion=<version>;
; without it this can still be compiled locally for testing.

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#define MyAppName "Clamshell"
#define MyAppPublisher "frindle"
#define MyAppExeName "ClamshellServer.exe"
#define PublishDir "..\publish"

[Setup]
AppId={{B36F1E1A-6C3E-4B7B-9F0B-6B9C7B1D9E11}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=Clamshell-Setup-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

; Unchecked by default: the host is still experimental (see README) and
; hasn't run on real Windows hardware yet, so auto-starting it isn't the
; right default until that changes.
[Tasks]
Name: "startatlogin"; Description: "Start Clamshell automatically when you sign in"; Flags: unchecked

[Files]
Source: "{#PublishDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Clamshell"; ValueData: """{app}\{#MyAppExeName}"""; Tasks: startatlogin; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch Clamshell now"; Flags: postinstall nowait skipifsilent unchecked
