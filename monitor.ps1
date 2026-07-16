param(
    [string]$Url = "http://localhost:8080/",
    [int]$Interval = 10,
    [int]$Threshold = 3
)

Write-Host "=== Monitoring $Url ===" -ForegroundColor Cyan
Write-Host "Interval: ${Interval}s | Alert after $Threshold consecutive failures"
Write-Host "Press Ctrl+C to stop`n"

$consecutiveFailures = 0

while ($true) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -Method HEAD
        if ($consecutiveFailures -gt 0) {
            Write-Host "[$timestamp] RECOVERED - $($r.StatusCode) OK (was down for $consecutiveFailures checks)" -ForegroundColor Green
        }
        else {
            Write-Host "[$timestamp] $($r.StatusCode) OK" -ForegroundColor Green
        }
        $consecutiveFailures = 0
    }
    catch {
        $consecutiveFailures++
        $msg = "[$timestamp] FAIL #$consecutiveFailures - $_"
        if ($consecutiveFailures -ge $Threshold) {
            Write-Host "$msg  SERVER DOWN!" -ForegroundColor Red
        }
        else {
            Write-Host "$msg" -ForegroundColor Yellow
        }
    }
    Start-Sleep -Seconds $Interval
}
