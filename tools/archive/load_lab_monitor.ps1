#Requires -Version 5.1
<#
.SYNOPSIS
  Aurora Load Lab live monitor — connect to log WebSocket and time page loads.

.DESCRIPTION
  Connects to Aurora's embedded log server WebSocket (default ws://127.0.0.1:8080/ws)
  and reports page-load durations with the current Load Lab flag state.

  Prerequisites (device):
    adb reverse tcp:8080 tcp:8080
    # or: adb forward tcp:8080 tcp:8080  (if using device-side bind)

.PARAMETER Url
  WebSocket URL. Default: ws://127.0.0.1:8080/ws

.PARAMETER ResultsLog
  Path to append session results. Default: tools/load_lab_results.log next to this script.

.EXAMPLE
  .\tools\load_lab_monitor.ps1
  .\tools\load_lab_monitor.ps1 -Url ws://127.0.0.1:8080/ws
#>
[CmdletBinding()]
param(
    [string]$Url = 'ws://127.0.0.1:8080/ws',
    [string]$ResultsLog = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

if ([string]::IsNullOrWhiteSpace($ResultsLog)) {
    $ResultsLog = Join-Path $PSScriptRoot 'load_lab_results.log'
}

# --- state -------------------------------------------------------------------
$script:LabState = 'intercept=on enrich=on guard=on'  # production defaults
$script:PendingStart = $null  # @{ Time = [datetime]; Url = [string] }
$script:Loads = [System.Collections.Generic.List[object]]::new()
$script:StopRequested = $false
$script:LastReportedKey = $null
$script:LastReportedAt = [datetime]::MinValue
$script:ConnectedAt = $null

function Write-Bright([string]$Text, [ConsoleColor]$Color = 'Cyan') {
    Write-Host $Text -ForegroundColor $Color
}

function Parse-LogTimestamp([string]$Line) {
    # [yyyy-mm-dd HH:mm:ss.mmm] ...
    if ($Line -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\]') {
        try {
            return [datetime]::ParseExact(
                $Matches[1],
                'yyyy-MM-dd HH:mm:ss.fff',
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        } catch {
            return $null
        }
    }
    return $null
}

function Extract-UrlFromPageLine([string]$Message, [string]$Prefix) {
    # "Page started: https://..." or after LOAD_METRIC url=
    $idx = $Message.IndexOf($Prefix)
    if ($idx -lt 0) { return $null }
    return $Message.Substring($idx + $Prefix.Length).Trim()
}

function Extract-LoadMetricUrl([string]$Message) {
    if ($Message -match 'url=(\S+)') {
        return $Matches[1]
    }
    return $null
}

function Extract-DurationMs([string]$Message) {
    if ($Message -match 'duration_ms=(\d+)') {
        return [int]$Matches[1]
    }
    return $null
}

function Write-LoadResult {
    param(
        [int]$DurationMs,
        [string]$Url,
        [string]$Lab,
        [datetime]$At
    )

    $sep = ('=' * 54)
    $block = @"
$sep
LOAD  $DurationMs ms  |  lab: $Lab
URL   $Url
$sep
"@
    Write-Host ''
    Write-Host $sep -ForegroundColor Green
    Write-Host ("LOAD  {0} ms  |  lab: {1}" -f $DurationMs, $Lab) -ForegroundColor Green
    Write-Host ("URL   {0}" -f $Url) -ForegroundColor White
    Write-Host $sep -ForegroundColor Green

    $entry = [pscustomobject]@{
        At          = $At
        DurationMs  = $DurationMs
        Url         = $Url
        Lab         = $Lab
    }
    $script:Loads.Add($entry) | Out-Null

    # Session summary table
    Write-Host ''
    Write-Host 'Session loads:' -ForegroundColor DarkCyan
    $i = 0
    foreach ($row in $script:Loads) {
        $i++
        $shortUrl = $row.Url
        if ($shortUrl.Length -gt 60) { $shortUrl = $shortUrl.Substring(0, 57) + '...' }
        Write-Host ("  #{0,-3} {1,6} ms  | {2,-40} | {3}" -f $i, $row.DurationMs, $row.Lab, $shortUrl)
    }
    Write-Host ''

    # Append to results log
    try {
        $logLine = "[{0:yyyy-MM-dd HH:mm:ss.fff}] LOAD {1} ms | lab: {2} | {3}" -f $At, $DurationMs, $Lab, $Url
        Add-Content -Path $ResultsLog -Value $logLine -Encoding UTF8
    } catch {
        Write-Host "[warn] could not write results log: $_" -ForegroundColor Yellow
    }
}

function Clean-Url([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return '?' }
    # Strip AuroraLog repeat suffix: " [x2, 0s]" and trailing junk
    $u = $Url -replace '\s*\[x\d+,\s*\d+s\]\s*$', ''
    $u = $u.Trim()
    if ($u.Length -eq 0) { return '?' }
    return $u
}

function Handle-Message([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return }

    $ts = Parse-LogTimestamp $Line
    if (-not $ts) { $ts = Get-Date }

    # Skip history replay from the server's last-100 dump: only accept events
    # whose log timestamp is within ~2 minutes of wall clock (live session).
    # LOAD_LAB state lines are always accepted so toggles still show up.
    $isLabLine = $Line -match 'LOAD_LAB\s+'
    if (-not $isLabLine -and $script:ConnectedAt) {
        $ageSec = ([datetime]::Now - $ts).TotalSeconds
        # Allow small clock skew / future; reject deep history.
        if ($ageSec -gt 120 -or $ageSec -lt -30) {
            return
        }
    }

    # --- LOAD_LAB -----------------------------------------------------------
    if ($Line -match 'LOAD_LAB\s+(intercept=\S+\s+enrich=\S+\s+guard=\S+)') {
        $script:LabState = $Matches[1].Trim()
        Write-Bright ("LAB STATE: {0}" -f $script:LabState) 'Magenta'
        return
    }
    if ($Line -match 'LOAD_LAB\s+(.+)$') {
        $script:LabState = $Matches[1].Trim()
        Write-Bright ("LAB STATE: {0}" -f $script:LabState) 'Magenta'
        return
    }

    # --- START: only LOAD_METRIC (avoids double Page started + metric) ------
    if ($Line -match 'LOAD_METRIC\s+event=start') {
        $url = Clean-Url (Extract-LoadMetricUrl $Line)
        $script:PendingStart = @{ Time = $ts; Url = $url; Wall = [datetime]::Now }
        Write-Host ("[start] {0}" -f $url) -ForegroundColor DarkGray
        return
    }

    # --- FINISH: only LOAD_METRIC with duration_ms (authoritative) ---------
    if ($Line -match 'LOAD_METRIC\s+event=finish') {
        $url = Clean-Url (Extract-LoadMetricUrl $Line)
        $durationMs = Extract-DurationMs $Line
        if ($null -eq $durationMs -and $script:PendingStart) {
            $delta = ($ts - [datetime]$script:PendingStart.Time).TotalMilliseconds
            if ($delta -ge 0 -and $delta -lt 180000) {
                $durationMs = [int][math]::Round($delta)
            }
        }
        $script:PendingStart = $null
        if ($null -eq $durationMs) {
            Write-Host ("[finish] no duration for {0}" -f $url) -ForegroundColor Yellow
            return
        }
        # Sanity: ignore absurd values (history mis-pair / clock issues)
        if ($durationMs -lt 0 -or $durationMs -gt 180000) {
            Write-Host ("[finish] ignore outlier {0} ms for {1}" -f $durationMs, $url) -ForegroundColor DarkYellow
            return
        }
        Report-LoadOnce -DurationMs $durationMs -Url $url -At $ts
        return
    }
}

function Report-LoadOnce {
    param([int]$DurationMs, [string]$Url, [datetime]$At)
    $key = "{0}|{1}" -f $Url, $DurationMs
    if ($script:LastReportedKey -and
        $script:LastReportedKey.StartsWith("$Url|") -and
        ($At - $script:LastReportedAt).TotalSeconds -lt 2) {
        return
    }
    $script:LastReportedKey = $key
    $script:LastReportedAt = $At
    Write-LoadResult -DurationMs $DurationMs -Url $Url -Lab $script:LabState -At $At
}

function Connect-AndListen {
    param([string]$WsUrl)

    $uri = [Uri]$WsUrl
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $cts = [System.Threading.CancellationTokenSource]::new()

    Write-Host ("Connecting to {0} ..." -f $WsUrl) -ForegroundColor Cyan
    $connectTask = $ws.ConnectAsync($uri, $cts.Token)
    if (-not $connectTask.Wait(15000)) {
        $cts.Cancel()
        $ws.Dispose()
        throw "Connect timed out after 15s"
    }
    if ($connectTask.IsFaulted) {
        $ex = $connectTask.Exception.GetBaseException()
        $ws.Dispose()
        throw $ex
    }

    Write-Bright ("CONNECTED  {0}" -f $WsUrl) 'Green'
    Write-Host ("Results log: {0}" -f $ResultsLog) -ForegroundColor DarkGray
    Write-Host 'Waiting for live LOAD_LAB / LOAD_METRIC (history dump ignored) ...' -ForegroundColor DarkGray
    Write-Host 'Ctrl+C to exit' -ForegroundColor DarkGray
    Write-Host ''
    $script:ConnectedAt = [datetime]::Now
    $script:PendingStart = $null
    $script:BackoffSec = 1

    $buffer = [byte[]]::new(8192)
    $segment = [ArraySegment[byte]]::new($buffer)
    $sb = [System.Text.StringBuilder]::new()

    try {
        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open -and -not $script:StopRequested) {
            $sb.Clear() | Out-Null
            $result = $null
            do {
                $recvTask = $ws.ReceiveAsync($segment, $cts.Token)
                # Poll so Ctrl+C can be handled between frames
                while (-not $recvTask.IsCompleted) {
                    if ($script:StopRequested) { break }
                    Start-Sleep -Milliseconds 50
                }
                if ($script:StopRequested) { break }
                if ($recvTask.IsFaulted) {
                    throw $recvTask.Exception.GetBaseException()
                }
                $result = $recvTask.Result
                if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    break
                }
                $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
                [void]$sb.Append($text)
            } while (-not $result.EndOfMessage -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open)

            if ($script:StopRequested) { break }
            if ($null -eq $result) { break }
            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }

            $payload = $sb.ToString()
            # Server may batch multiple lines; split defensively
            foreach ($line in ($payload -split "`r?`n")) {
                if ($line.Length -gt 0) {
                    try { Handle-Message $line } catch {
                        Write-Host "[handler] $_" -ForegroundColor Yellow
                    }
                }
            }
        }
    } finally {
        try {
            if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $closeTask = $ws.CloseAsync(
                    [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                    'bye',
                    [System.Threading.CancellationToken]::None
                )
                $closeTask.Wait(2000) | Out-Null
            }
        } catch { }
        $ws.Dispose()
        $cts.Dispose()
    }
}

# --- main loop with reconnect backoff ----------------------------------------
Write-Host '=== Aurora Load Lab Monitor ===' -ForegroundColor Cyan
Write-Host ("URL: {0}" -f $Url)
Write-Host ("Log: {0}" -f $ResultsLog)
Write-Host ''

# Ctrl+C: set stop flag instead of hard-killing mid-frame when possible.
# TreatControlCAsInput fails in non-interactive / piped hosts — ignore that.
try { [Console]::TreatControlCAsInput = $false } catch { }
$null = Register-EngineEvent -SourceIdentifier Console_CancelKeyPress -Action {
    $script:StopRequested = $true
    Write-Host "`nStopping..." -ForegroundColor Yellow
} -ErrorAction SilentlyContinue

# Also trap via try so Ctrl+C in Wait throws PipelineStopped / OperationCanceled
$script:BackoffSec = 1
$maxBackoff = 30

try {
    while (-not $script:StopRequested) {
        try {
            Connect-AndListen -WsUrl $Url
            if ($script:StopRequested) { break }
            Write-Host 'Disconnected from WebSocket.' -ForegroundColor Yellow
        } catch {
            if ($script:StopRequested) { break }
            Write-Host ("Connection error: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }

        if ($script:StopRequested) { break }
        Write-Host ("Reconnecting in {0}s ..." -f $script:BackoffSec) -ForegroundColor DarkYellow
        Start-Sleep -Seconds $script:BackoffSec
        $script:BackoffSec = [math]::Min($maxBackoff, $script:BackoffSec * 2)
    }
} finally {
    # no soft-finish flush — only authoritative LOAD_METRIC reports
    Write-Host ''
    Write-Host ("Session complete. {0} load(s) recorded." -f $script:Loads.Count) -ForegroundColor Cyan
    if ($script:Loads.Count -gt 0) {
        Write-Host ("Results appended to: {0}" -f $ResultsLog)
    }
}
