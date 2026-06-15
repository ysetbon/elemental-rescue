# scripts/nettest.ps1 — headless netcode QA: a REAL authoritative host + guest talking over
# a latency-injected copy of the production relay (server.js), driving a scripted chase and
# streaming smoothness/skew/catch telemetry to the host terminal.
#
#   pwsh scripts/nettest.ps1 -Latency 60 -Jitter 20 -Seconds 24
#
# What to read in the output:
#   [netlog] guest#N  skew A/B u ...      A = mean, B = worst gap between where the guest
#                                         predicts itself and where the host authoritatively
#                                         has it. The catch pad (NET_CATCH_PAD) must clear B.
#   ... seen-min X u | host-auth-min Y u  X = closest the guest *drew* itself to a ghost;
#                                         Y = closest the host got authoritatively. Y-X ≈ how
#                                         much catch tolerance a "looks dead-on" hit needs.
#   ... extrap %, underrun, buf           ghost interpolation health (underrun = a real stall).
#   ... snaps                             own-avatar corrections that exceeded RECONCILE_EPS
#                                         (what the old hard-snap code would have JOLTED).
param(
  [int]$Latency = 60,      # one-way ms injected by the relay (RTT ≈ 2x)
  [int]$Jitter  = 20,      # extra 0..Jitter ms per message
  [int]$Seconds = 24,      # match run length
  [int]$Port    = 8917,    # relay port (off the 8910 default so it won't clash with a real one)
  [string]$Godot = $env:GODOT
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
if (-not $Godot) { $Godot = "C:\Users\YonatanSetbon\Downloads\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe" }
if (-not (Test-Path $Godot)) { throw "Godot binary not found at '$Godot' — pass -Godot <path> or set `$env:GODOT." }

$logs = Join-Path $root "scripts\nettest_logs"
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$hostLog = Join-Path $logs "host.log"; $guestLog = Join-Path $logs "guest.log"; $relayLog = Join-Path $logs "relay.log"

Write-Host "[nettest] relay :$Port   one-way ${Latency}ms +${Jitter}ms jitter (RTT ~$([int](2*$Latency+$Jitter))ms)   run ${Seconds}s"

# 1) relay with latency injection
$env:PORT = "$Port"; $env:RELAY_LATENCY_MS = "$Latency"; $env:RELAY_JITTER_MS = "$Jitter"
$relay = Start-Process node -ArgumentList "server.js" -WorkingDirectory $root -PassThru -NoNewWindow `
  -RedirectStandardOutput $relayLog -RedirectStandardError "$relayLog.err"
Start-Sleep -Milliseconds 700

# 2) the two game processes (they self-quit after NETTEST_SECS)
$env:TEST_PORT = "$Port"; $env:NETTEST_SECS = "$Seconds"; $env:NET_LOG = "1"; $env:NO_COLOR = "1"
$args = @("--headless", "--path", $root, "--", "nettest")
$hostP  = Start-Process $Godot -ArgumentList $args            -WorkingDirectory $root -PassThru -NoNewWindow `
  -RedirectStandardOutput $hostLog  -RedirectStandardError "$hostLog.err"
Start-Sleep -Milliseconds 900
$guestP = Start-Process $Godot -ArgumentList ($args + "join") -WorkingDirectory $root -PassThru -NoNewWindow `
  -RedirectStandardOutput $guestLog -RedirectStandardError "$guestLog.err"

# 3) wait for the run to finish, then make sure everything is down
[void]$hostP.WaitForExit(($Seconds + 15) * 1000)
Start-Sleep -Milliseconds 800
foreach ($p in @($guestP, $hostP, $relay)) { if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} } }

Write-Host "`n===================== HOST terminal (unified telemetry) ====================="
if (Test-Path $hostLog)  { Get-Content $hostLog  | Select-String -Pattern "netlog|HOST|match|Caught|Hit|ended|SCRIPT ERROR|Parse Error|Cannot|nil" }
Write-Host "`n===================== GUEST (own-side prints, tail) ========================="
if (Test-Path $guestLog) { Get-Content $guestLog | Select-String -Pattern "netlog g|GUEST|SCRIPT ERROR|Parse Error|Cannot|nil" | Select-Object -Last 16 }
Write-Host "`n(full logs in $logs)"
