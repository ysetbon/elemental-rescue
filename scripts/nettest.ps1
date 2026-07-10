# scripts/nettest.ps1 — headless netcode QA: a REAL authoritative host + N guests talking over
# a latency-injected copy of the production relay (server.js), driving a scripted castle-world
# scenario and streaming smoothness/skew/catch telemetry to the host terminal.
#
#   pwsh scripts/nettest.ps1 -Latency 60 -Jitter 20 -Seconds 45            # chase + catch, 1 guest
#   pwsh scripts/nettest.ps1 -Guests 3                                     # 4-player common start
#   pwsh scripts/nettest.ps1 -Guests 2 -Players 2 -Seconds 40              # guest 2 late-joins mid-match
#   pwsh scripts/nettest.ps1 -Rescue -Seconds 24                           # scripted key→cage→homecoming win
#   pwsh scripts/nettest.ps1 -Clan -Seconds 35                             # clan recruit + fetch command
#
# Scenario (default): guest #1 (fire) walks out its gate, over the z=-75 bridge, and circles at
# the wilds rendezvous; the host (water, fire's predator) walks out to meet it and chases until
# a catch fires (guest reports it client-side → host validates → "Caught!" + respawn). Extra
# guests (grass) circle their courtyard as ghost/interp stress.
#
# What to read in the output:
#   [netlog] guest#N  skew A/B u ...      A = mean, B = worst gap between where the guest
#                                         predicts itself and where the host authoritatively
#                                         has it. The catch pad (NET_CATCH_PAD) must clear B.
#   ... seen-min X u | host-auth-min Y u  X = closest the guest *drew* itself to any ghost;
#                                         Y = closest the host got authoritatively to that guest.
#   ... extrap %, underrun, buf           ghost interpolation health (underrun = a real stall).
#   ... snaps                             own-avatar corrections that exceeded RECONCILE_EPS
#                                         (what the old hard-snap code would have JOLTED).
#   Hit! / Caught!                        the chase made contact (catch flow works end-to-end).
param(
  [int]$Latency = 60,      # one-way ms injected by the relay (RTT ≈ 2x)
  [int]$Jitter  = 20,      # extra 0..Jitter ms per message
  [int]$Seconds = 45,      # match run length (the castle chase needs ~35s to make contact)
  [int]$Guests  = 1,       # how many guest processes to launch (relay caps at 6 guests + host)
  [int]$Players = 0,       # lobby size the host waits for before starting (0 = Guests+1, i.e.
                           # a common start; set lower to make later guests exercise late-join)
  [switch]$Rescue,         # scripted rescue beats (key → cage → homecoming win broadcast)
  [switch]$Clan,           # clan recruit + scripted fetch command (NETTEST_CLAN)
  [int]$Port    = 8917,    # relay port (off the 8910 default so it won't clash with a real one)
  [string]$Godot = $env:GODOT
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
if (-not $Godot) { $Godot = "C:\Users\YonatanSetbon\Downloads\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe" }
if (-not (Test-Path $Godot)) { throw "Godot binary not found at '$Godot' — pass -Godot <path> or set `$env:GODOT." }

$logs = Join-Path $root "scripts\nettest_logs"
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$hostLog = Join-Path $logs "host.log"; $relayLog = Join-Path $logs "relay.log"

$mode = if ($Rescue) { "rescue" } elseif ($Clan) { "clan" } else { "chase" }
Write-Host "[nettest] relay :$Port   one-way ${Latency}ms +${Jitter}ms jitter (RTT ~$([int](2*$Latency+$Jitter))ms)   run ${Seconds}s   guests $Guests   scenario $mode"

# 1) relay with latency injection
$env:PORT = "$Port"; $env:RELAY_LATENCY_MS = "$Latency"; $env:RELAY_JITTER_MS = "$Jitter"
$relay = Start-Process node -ArgumentList "server.js" -WorkingDirectory $root -PassThru -NoNewWindow `
  -RedirectStandardOutput $relayLog -RedirectStandardError "$relayLog.err"
Start-Sleep -Milliseconds 700

# 2) the game processes (they self-quit after NETTEST_SECS)
$env:TEST_PORT = "$Port"; $env:NETTEST_SECS = "$Seconds"; $env:NET_LOG = "1"; $env:NO_COLOR = "1"
$needPlayers = if ($Players -gt 0) { $Players } else { $Guests + 1 }
$env:NETTEST_PLAYERS = "$needPlayers"
if ($Rescue) { $env:NETTEST_RESCUE = "1" } else { Remove-Item Env:NETTEST_RESCUE -ErrorAction SilentlyContinue }
if ($Clan)   { $env:NETTEST_CLAN   = "1" } else { Remove-Item Env:NETTEST_CLAN   -ErrorAction SilentlyContinue }
$args = @("--headless", "--path", $root, "--", "nettest")
$env:NETTEST_IDX = "0"
$hostP = Start-Process $Godot -ArgumentList $args -WorkingDirectory $root -PassThru -NoNewWindow `
  -RedirectStandardOutput $hostLog -RedirectStandardError "$hostLog.err"
Start-Sleep -Milliseconds 900
$guestPs = @(); $guestLogs = @()
for ($i = 1; $i -le $Guests; $i++) {
  if ($i -gt ($needPlayers - 1)) { Start-Sleep -Milliseconds 4500 }   # past the common-start quota →
                                                                      # land mid-match (a REAL late join)
  $gl = Join-Path $logs "guest$i.log"
  $guestLogs += $gl
  $env:NETTEST_IDX = "$i"
  $guestPs += Start-Process $Godot -ArgumentList ($args + "join") -WorkingDirectory $root -PassThru -NoNewWindow `
    -RedirectStandardOutput $gl -RedirectStandardError "$gl.err"
  Start-Sleep -Milliseconds 400
}

# 3) wait for the run to finish, then make sure everything is down
[void]$hostP.WaitForExit(($Seconds + 20) * 1000)
Start-Sleep -Milliseconds 800
foreach ($p in ($guestPs + @($hostP, $relay))) { if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} } }

$pattern = "netlog|\[nt |HOST|match|Caught|Hit|ended|rescue|cage|stuck|respawned|SCRIPT ERROR|Parse Error|Cannot|nil"
Write-Host "`n===================== HOST terminal (unified telemetry) ====================="
if (Test-Path $hostLog) { Get-Content $hostLog | Select-String -Pattern $pattern }
for ($i = 1; $i -le $Guests; $i++) {
  Write-Host "`n===================== GUEST $i (own-side prints, tail) ======================"
  $gl = $guestLogs[$i - 1]
  if (Test-Path $gl) { Get-Content $gl | Select-String -Pattern "netlog g|\[nt |GUEST|Caught|Hit|cage|ended|stuck|respawned|SCRIPT ERROR|Parse Error|Cannot|nil" | Select-Object -Last 40 }
  if (Test-Path "$gl.err") { Get-Content "$gl.err" | Select-Object -First 6 }
}
if (Test-Path "$hostLog.err") { Write-Host "`n--- host stderr (first lines) ---"; Get-Content "$hostLog.err" | Select-Object -First 6 }
Write-Host "`n(full logs in $logs)"
