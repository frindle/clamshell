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
; StreamServer binds http://+:PORT/ (wildcard host, so LAN/Tailscale clients
; can reach it) via HttpListener, which needs either an elevated process or a
; pre-reserved URL ACL. The installer already runs elevated (PrivilegesRequired
; defaults to admin for a Program Files install), so reserve the range here
; instead of asking the user to run netsh themselves later or requiring
; ClamshellServer.exe to run as admin — the latter would also break
; "start at sign-in", since Windows never auto-elevates Run-key startup
; entries even for admin accounts. 8 ports covers base port + up to 7 extra
; displays (index 0 = base port); `netsh` exits nonzero on a port that's
; already reserved (e.g. reinstall/repair) but Setup doesn't treat that as
; fatal, so this is safe to re-run.
Filename: "{sys}\netsh.exe"; Parameters: "http add urlacl url=http://+:5903/ user=Everyone"; Flags: runhidden; StatusMsg: "Reserving network ports for Clamshell..."
Filename: "{sys}\netsh.exe"; Parameters: "http add urlacl url=http://+:5904/ user=Everyone"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "http add urlacl url=http://+:5905/ user=Everyone"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "http add urlacl url=http://+:5906/ user=Everyone"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "http add urlacl url=http://+:5907/ user=Everyone"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "http add urlacl url=http://+:5908/ user=Everyone"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "http add urlacl url=http://+:5909/ user=Everyone"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "http add urlacl url=http://+:5910/ user=Everyone"; Flags: runhidden
Filename: "{app}\{#MyAppExeName}"; Description: "Launch Clamshell now"; Flags: postinstall nowait skipifsilent unchecked

[UninstallRun]
; Mirror of the [Run] reservations above — release them on uninstall instead
; of leaving orphaned URL ACLs granting "Everyone" bind rights on this
; machine indefinitely.
Filename: "{sys}\netsh.exe"; Parameters: "http delete urlacl url=http://+:5903/"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "http delete urlacl url=http://+:5904/"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "http delete urlacl url=http://+:5905/"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "http delete urlacl url=http://+:5906/"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "http delete urlacl url=http://+:5907/"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "http delete urlacl url=http://+:5908/"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "http delete urlacl url=http://+:5909/"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "http delete urlacl url=http://+:5910/"; Flags: runhidden
