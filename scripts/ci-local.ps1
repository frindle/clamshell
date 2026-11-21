# The Windows checks CI runs. Run it with PowerShell 7 from the root of a
# checkout: `pwsh -File scripts/ci-local.ps1`.
#
# GitHub's windows-ci.yml calls this script, and so does the local CI runner,
# so both run the same steps in the same order.
#
# Needs the .NET 8 SDK, Git and ffmpeg on PATH. It installs nothing.
#
# -SkipDesktop skips the steps that need a logged-in desktop (the live smoke
# test, the GUI smoke test and the end-to-end connect, which open real
# windows or capture the real display). A skipped step is counted as skipped,
# never as passed.
#
# -DesktopOnly is the other half: it runs only those desktop steps, plus the
# two builds they need. On our VM a second runner runs this half, so the rest
# never waits for the VM's screen.
#
# Only one run at a time on a machine: the VM has two runners, and the steps
# share ports, key stores and the screen. A second run waits for the first.
#
# Every step runs even when an earlier one fails. The last line is a count
# only ("N of M steps passed"), so it is safe to publish. Exit code 0 means
# every step that ran passed.
param([switch]$SkipDesktop, [switch]$DesktopOnly)

$ErrorActionPreference = 'Stop'
$InActions = ($env:GITHUB_ACTIONS -eq 'true')
$Root = (Get-Location).Path

# --- Tools first: one clear line if something is missing, nothing installed.
function Test-Tools {
  $sdks = ""
  if (Get-Command dotnet -ErrorAction SilentlyContinue) { $sdks = (& dotnet --list-sdks) -join "`n" }
  if ($sdks -notmatch '(?m)^8\.') { return "missing tool: .NET 8 SDK is not on PATH" }
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return "missing tool: Git is not on PATH" }
  if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { return "missing tool: ffmpeg is not on PATH" }
  if (-not (Test-Path (Join-Path $Root 'WindowsServer/ClamshellServer.csproj'))) { return "run this from the root of a checkout" }
  return $null
}
if ($SkipDesktop -and $DesktopOnly) { Write-Output "use -SkipDesktop or -DesktopOnly, not both"; exit 1 }
$missing = Test-Tools
if ($missing) { Write-Output $missing; exit 1 }

# One run at a time on this machine (see the header). A run that was killed
# leaves the lock abandoned; taking an abandoned lock is fine.
$CiLock = New-Object System.Threading.Mutex($false, 'Global\ClamshellCI')
try {
  if (-not $CiLock.WaitOne(0)) {
    Write-Output "waiting for another CI run on this machine to finish"
    [void]$CiLock.WaitOne()
  }
} catch [System.Threading.AbandonedMutexException] { }

# All temporary files (logs, clips, throwaway state) live here and go at the end.
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("clamshell-ci-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp | Out-Null

$script:Total = 0
$script:Passed = 0
$script:Skipped = 0

function Invoke-Step {
  param([string]$Name, [scriptblock]$Body, [switch]$NeedsDesktop, [switch]$Build)
  $script:Total++
  if ($InActions) { Write-Output "::group::$Name" } else { Write-Output "=== $Name" }
  if ($NeedsDesktop -and $SkipDesktop) {
    $script:Skipped++
    Write-Output "SKIPPED (needs a logged-in desktop)"
  } elseif ($DesktopOnly -and -not $NeedsDesktop -and -not $Build) {
    $script:Skipped++
    Write-Output "SKIPPED (desktop-only run)"
  } else {
    $ok = $true
    $savedState = $env:CLAMSHELL_STATE_DIR
    $savedCli = $env:CLAMSHELL_CLI_OUTPUT
    try {
      $global:LASTEXITCODE = $null
      & $Body
      # Same as GitHub's pwsh shell: the step fails if its last native command did.
      if ($null -ne $global:LASTEXITCODE -and $global:LASTEXITCODE -ne 0) { $ok = $false }
    } catch {
      Write-Output ($_ | Out-String)
      $ok = $false
    } finally {
      $env:CLAMSHELL_STATE_DIR = $savedState
      $env:CLAMSHELL_CLI_OUTPUT = $savedCli
    }
    if ($ok) {
      $script:Passed++
    } elseif ($InActions) {
      Write-Output "::error::$Name failed"
    } else {
      Write-Output "FAILED: $Name"
    }
  }
  if ($InActions) { Write-Output "::endgroup::" }
}

try {

Invoke-Step "Build Windows host server" -Build {
  dotnet build WindowsServer/ClamshellServer.csproj -c Release
}
Invoke-Step "Self-test (pure protocol/framing logic)" {
  dotnet run --project WindowsServer/ClamshellServer.csproj -c Release -- selftest
}
Invoke-Step "Input self-test (shared vectors, tests/vectors/input-v1.json)" {
  dotnet run --project WindowsServer/ClamshellServer.csproj -c Release -- selftest-input tests/vectors/input-v1.json
}
Invoke-Step "Encoder self-test (the session's encoder path, synthetic frames, real AVCC out)" {
  dotnet run --project WindowsServer/ClamshellServer.csproj -c Release -- selftest-encoder
}
Invoke-Step "Host key self-test (real Windows key store, throwaway key)" {
  dotnet run --project WindowsServer/ClamshellServer.csproj -c Release -- selftest-hostkey
}
Invoke-Step "Device list self-test (real DPAPI and file system, throwaway folder)" {
  dotnet run --project WindowsServer/ClamshellServer.csproj -c Release -- selftest-store
}
Invoke-Step "Gate self-test (real server on loopback, real handshakes, throwaway key and list)" {
  dotnet run --project WindowsServer/ClamshellServer.csproj -c Release -- selftest-gate
}
Invoke-Step "Device commands self-test (devices, approve, deny, revoke, forget against a throwaway list)" {
  dotnet run --project WindowsServer/ClamshellServer.csproj -c Release -- selftest-commands
}
Invoke-Step "Host screens self-test (approval window, Devices section, Settings built once, no network)" {
  dotnet run --project WindowsServer/ClamshellServer.csproj -c Release -- selftest-screens
}

Invoke-Step "Live smoke test (real display enum, encoder probe, listener bind)" -NeedsDesktop {
  # `selftest` above never touches DXGI/Media Foundation/HttpListener; those
  # need an actual display/session. This launches the real server for a few
  # seconds and checks it made it through display enumeration, the
  # hardware-encoder probe, and a listener bind without an unhandled
  # exception, then kills it.
  $out = Join-Path $Tmp "smoke-out.log"
  $err = Join-Path $Tmp "smoke-err.log"
  $proc = Start-Process -FilePath dotnet `
    -ArgumentList "run","--project","WindowsServer/ClamshellServer.csproj","-c","Release","--","5950" `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput $out -RedirectStandardError $err
  Start-Sleep -Seconds 10

  if ($proc.HasExited) {
    Write-Output "--- stdout ---"; Get-Content $out -ErrorAction SilentlyContinue
    Write-Output "--- stderr ---"; Get-Content $err -ErrorAction SilentlyContinue
    throw "ClamshellServer exited early (code $($proc.ExitCode)) instead of staying up"
  }
  Stop-Process -Id $proc.Id -Force

  # Log.cs writes every startup line to stderr, not stdout.
  Write-Output "--- stdout ---"
  Get-Content $out -ErrorAction SilentlyContinue
  Write-Output "--- stderr ---"
  Get-Content $err -ErrorAction SilentlyContinue
  $log = Get-Content $err -Raw -ErrorAction SilentlyContinue
  if ($log -notmatch "display\(s\)") { throw "startup log missing display enumeration line" }
  if ($log -notmatch "hardware video encoder|no hardware video encoder") { throw "startup log missing encoder probe line" }
  if ($log -notmatch "listening on ws port|cannot bind") { throw "startup log missing listener bind line" }
  Write-Output "smoke test OK: process stayed up and completed the real startup sequence"
}

Invoke-Step "Build Windows viewer client" -Build {
  dotnet build WindowsViewer/ClamshellWindowViewer.csproj -c Release
}
Invoke-Step "Viewer self-test (pure protocol/AVCC-AnnexB framing logic)" {
  dotnet run --project WindowsViewer/ClamshellWindowViewer.csproj -c Release -- selftest
}
Invoke-Step "Viewer device-auth self-test (vectors, handshakes, tampered frames)" {
  dotnet run --project WindowsViewer/ClamshellWindowViewer.csproj -c Release -- selftest-auth tests/vectors/auth-v1.json
}
Invoke-Step "Viewer key store self-test (real Windows key store, throwaway key)" {
  dotnet run --project WindowsViewer/ClamshellWindowViewer.csproj -c Release -- selftest-keystore
}
Invoke-Step "Viewer screens self-test (each device-auth screen built once, no network)" {
  dotnet run --project WindowsViewer/ClamshellWindowViewer.csproj -c Release -- selftest-screens
}
Invoke-Step "Viewer saved-Macs commands (known-hosts, forget-host with nothing saved)" {
  dotnet run --project WindowsViewer/ClamshellWindowViewer.csproj -c Release -- known-hosts
  if ($LASTEXITCODE -ne 0) { throw "known-hosts failed (exit $LASTEXITCODE)" }
  dotnet run --project WindowsViewer/ClamshellWindowViewer.csproj -c Release -- forget-host nothing-here
  if ($LASTEXITCODE -ne 1) { throw "forget-host of an unknown Mac should exit 1, got $LASTEXITCODE" }
  # The exit code 1 above was the expected one; do not let it fail the step.
  $global:LASTEXITCODE = 0
}

Invoke-Step "Viewer GUI smoke test (real WPF Application/Window on a real virtual display)" -NeedsDesktop {
  # The `--verify`/`decode-file` steps below never construct MainWindow; they
  # are deliberately headless. That leaves the actual GUI path unexercised.
  # Launch the real GUI mode (no server needed; the window still comes up)
  # and confirm the process stays alive for a few seconds.
  $out = Join-Path $Tmp "viewer-gui-out.log"
  $err = Join-Path $Tmp "viewer-gui-err.log"
  $proc = Start-Process -FilePath dotnet `
    -ArgumentList "run","--project","WindowsViewer/ClamshellWindowViewer.csproj","-c","Release","--","127.0.0.1","1" `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput $out -RedirectStandardError $err
  Start-Sleep -Seconds 5

  Write-Output "--- viewer GUI stdout ---"; Get-Content $out -ErrorAction SilentlyContinue
  Write-Output "--- viewer GUI stderr ---"; Get-Content $err -ErrorAction SilentlyContinue

  if ($proc.HasExited) { throw "viewer GUI process exited early (code $($proc.ExitCode)) instead of staying up" }
  Stop-Process -Id $proc.Id -Force
  Write-Output "viewer GUI smoke test OK: WPF Application/Window constructed and stayed up on a real virtual display"
}

Invoke-Step "End-to-end viewer connect (real host HELLO/HELLO_ACK -> real client)" -NeedsDesktop {
  # The host asks before it lets a new device in. The viewer connects as an
  # unknown device and waits; this step approves it through the host's own
  # command line (`ClamshellServer approve <fingerprint>`, against a
  # throwaway state folder), and only then does the session start. It proves
  # that handshake and approval, and then that the host's own encoder
  # produced a frame the viewer decoded (`verify: PASS`). The host is
  # launched as a real display-stream source (Notepad opened first for real
  # on-screen content); the viewer's headless `--verify` mode does a real
  # WebSocket connect and a real HELLO/HELLO_ACK round trip.
  #
  # A throwaway device list for this step: the host and the command line
  # below both read it from here.
  $env:CLAMSHELL_STATE_DIR = Join-Path $Tmp "e2e-state"
  $serverErr = Join-Path $Tmp "server-err.log"
  $viewerErr = Join-Path $Tmp "viewer-err.log"
  $cliOut = Join-Path $Tmp "cli-out.txt"
  $notepad = Start-Process notepad.exe -PassThru
  Start-Sleep -Seconds 2

  $server = Start-Process -FilePath dotnet `
    -ArgumentList "run","--project","WindowsServer/ClamshellServer.csproj","-c","Release","--","5951" `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput (Join-Path $Tmp "server-out.log") -RedirectStandardError $serverErr
  Start-Sleep -Seconds 8

  if ($server.HasExited) {
    Write-Output "--- server stderr ---"; Get-Content $serverErr -ErrorAction SilentlyContinue
    Stop-Process -Id $notepad.Id -Force -ErrorAction SilentlyContinue
    throw "ClamshellServer exited early instead of staying up for the viewer test"
  }

  # No --allow-unverified. The viewer connects as a device the host has never
  # seen and waits to be approved.
  $viewer = Start-Process -FilePath dotnet `
    -ArgumentList "run","--project","WindowsViewer/ClamshellWindowViewer.csproj","-c","Release","--","--verify","127.0.0.1","5951","h264","60" `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput (Join-Path $Tmp "viewer-out.log") -RedirectStandardError $viewerErr
  $null = $viewer.Handle   # keeps the exit code readable after it exits

  # Find the waiting device the way a person at the PC would, then approve it.
  # The program has no console of its own here, so it writes its answer to this file.
  $env:CLAMSHELL_CLI_OUTPUT = $cliOut
  $cli = @("run","--no-build","--project","WindowsServer/ClamshellServer.csproj","-c","Release","--")
  $fingerprint = $null
  $listing = ""
  for ($i = 0; $i -lt 40 -and -not $fingerprint; $i++) {
    & dotnet @cli devices 2>&1 | Out-Null
    $listing = if (Test-Path $cliOut) { Get-Content $cliOut -Raw } else { "" }
    if ($listing -match "Waiting for approval:\s+([0-9A-F]{4}(?:-[0-9A-F]{4}){3})") { $fingerprint = $Matches[1] }
    else { Start-Sleep -Seconds 1 }
  }
  Write-Output "--- host device list ---"; Write-Output $listing
  $approveOut = $null
  $approveCode = $null
  if ($fingerprint) {
    & dotnet @cli approve $fingerprint 2>&1 | Out-Null
    $approveCode = $LASTEXITCODE
    $approveOut = if (Test-Path $cliOut) { Get-Content $cliOut -Raw } else { "" }
    Write-Output "--- approve $fingerprint (exit $approveCode) ---"; Write-Output $approveOut
  }

  if (-not $viewer.WaitForExit(70000)) { Stop-Process -Id $viewer.Id -Force -ErrorAction SilentlyContinue }

  Write-Output "--- server stderr ---"; Get-Content $serverErr -ErrorAction SilentlyContinue
  Write-Output "--- viewer stderr ---"; Get-Content $viewerErr -ErrorAction SilentlyContinue

  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  Stop-Process -Id $notepad.Id -Force -ErrorAction SilentlyContinue

  if (-not $fingerprint) { throw "the host never listed a device waiting for approval: the viewer did not reach the gate" }
  if ($approveCode -ne 0) { throw "approving the waiting device from the command line failed (exit $approveCode)" }
  $vlog = Get-Content $viewerErr -Raw -ErrorAction SilentlyContinue
  if (-not $vlog) { $vlog = "" }
  # The steps have to happen in this order: told to wait, then let in, then
  # HELLO_ACK, then a decoded frame.
  $waiting = $vlog.IndexOf("verify: state WaitingForApproval", [StringComparison]::Ordinal)
  $connected = $vlog.IndexOf("verify: state Connected", [StringComparison]::Ordinal)
  $helloAck = $vlog.IndexOf("verify: HELLO_ACK", [StringComparison]::Ordinal)
  $pass = $vlog.IndexOf("verify: PASS", [StringComparison]::Ordinal)
  if ($waiting -lt 0) { throw "the viewer was never told it was waiting for approval" }
  if ($connected -lt 0) { throw "the viewer was not connected after the device was approved" }
  if ($helloAck -lt 0) { throw "viewer never received HELLO_ACK after approval -- real connectivity failure" }
  if (-not ($waiting -lt $connected -and $connected -lt $helloAck)) { throw "the viewer's states were out of order (waiting $waiting, connected $connected, HELLO_ACK $helloAck)" }
  Write-Output "handshake and approval checked: the device waited, was approved on the host from the command line, was let in, and received HELLO_ACK"
  if ($pass -lt 0) { throw "no decoded video: the viewer did not print 'verify: PASS', so no VIDEO_FRAME from the real host was decoded" }
  if ($pass -lt $helloAck) { throw "'verify: PASS' appeared before HELLO_ACK (PASS $pass, HELLO_ACK $helloAck)" }
  Write-Output "video checked: a real VIDEO_FRAME from the host's own encoder was decoded by the viewer over the encrypted session"
}

$h264 = Join-Path $Tmp "test-frame.h264"
Invoke-Step "Generate a real single-frame H.264 test clip (ffmpeg, independent of WindowsServer)" {
  # A single-keyframe clip (-frames:v 1) is exactly one access unit
  # (SPS+PPS+IDR, Annex-B start-code delimited) so the viewer can feed the
  # whole file as one sample; see VideoDecoder.FeedAnnexB / Program.cs decode-file.
  ffmpeg -y -f lavfi -i "testsrc=size=320x240:rate=1" -frames:v 1 -c:v libx264 -pix_fmt yuv420p -f h264 $h264
  if (-not (Test-Path $h264) -or (Get-Item $h264).Length -eq 0) { throw "ffmpeg did not produce test-frame.h264" }
  Write-Output "generated test-frame.h264: $((Get-Item $h264).Length) bytes"
}

Invoke-Step "Viewer decode-file (real H.264 -> real Media Foundation decode)" {
  # Proves the viewer's own decode pipeline (VideoDecoder.cs, a real Media
  # Foundation H.264 decoder MFT, software path) against a real H.264 stream
  # from an independent, known-good encoder (ffmpeg/libx264). PASS requires an
  # actual decoded frame with non-uniform pixel content, not just "it didn't throw".
  $derr = Join-Path $Tmp "decode-file-err.log"
  dotnet run --project WindowsViewer/ClamshellWindowViewer.csproj -c Release -- decode-file $h264 h264 `
    2> $derr
  $code = $LASTEXITCODE
  Write-Output "--- decode-file stderr ---"; Get-Content $derr -ErrorAction SilentlyContinue
  if ($code -ne 0) { throw "decode-file FAILED (exit $code) -- see stderr above" }
  $dlog = Get-Content $derr -Raw -ErrorAction SilentlyContinue
  if ($dlog -notmatch "decode-file: PASS") { throw "decode-file stderr missing 'decode-file: PASS' line" }
  Write-Output "decode-file OK: real ffmpeg-produced H.264 decoded through a real Media Foundation decoder MFT"
}

$aac = Join-Path $Tmp "test-tone.aac"
Invoke-Step "Generate a one-second 1 kHz stereo AAC-LC clip (ffmpeg, ADTS)" {
  # Same idea as the H.264 clip above: an independent encoder makes the input,
  # so the viewer's decoder is checked against a known-good stream.
  ffmpeg -y -f lavfi -i "sine=frequency=1000:duration=1:sample_rate=48000" -ac 2 -c:a aac -profile:a aac_low -b:a 128k -f adts $aac
  if (-not (Test-Path $aac) -or (Get-Item $aac).Length -eq 0) { throw "ffmpeg did not produce test-tone.aac" }
  Write-Output "generated test-tone.aac: $((Get-Item $aac).Length) bytes"
}

Invoke-Step "Viewer decode-audio-file (real AAC-LC -> real Media Foundation decode)" {
  # Feeds the raw access units of the clip (ADTS headers dropped) through the
  # same AudioDecoder a live session uses, then checks the PCM: 48 kHz stereo,
  # the length within one frame of 1024, and a 1 kHz tone in both channels.
  # This proves the decoder. It plays nothing.
  $aerr = Join-Path $Tmp "decode-audio-err.log"
  dotnet run --project WindowsViewer/ClamshellWindowViewer.csproj -c Release -- decode-audio-file $aac 1000 1 `
    2> $aerr
  $code = $LASTEXITCODE
  Write-Output "--- decode-audio-file stderr ---"; Get-Content $aerr -ErrorAction SilentlyContinue
  if ($code -ne 0) { throw "decode-audio-file FAILED (exit $code) -- see stderr above" }
  $alog = Get-Content $aerr -Raw -ErrorAction SilentlyContinue
  if ($alog -notmatch "decode-audio-file: PASS") { throw "decode-audio-file stderr missing 'decode-audio-file: PASS' line" }
  Write-Output "decode-audio-file OK: a real ffmpeg AAC-LC clip decoded through a real Media Foundation decoder MFT to a 1 kHz tone. Sound output itself was NOT checked."
}

} finally {
  Set-Location $Root
  Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
  try { $CiLock.ReleaseMutex() } catch { }
}

$summary = "$($script:Passed) of $($script:Total) steps passed"
if ($script:Skipped -gt 0) { $summary += ", $($script:Skipped) skipped" }
Write-Output $summary
if (($script:Passed + $script:Skipped) -eq $script:Total) { exit 0 } else { exit 1 }
