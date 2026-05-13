#Requires -Version 5.1
# ================================================================
#  VM Metrics Reporter -Windows PowerShell Edition
#  Compatible with: Windows 10 / Windows 11 / Windows Server 2019 / Windows Server 2022
#
#  DISK alert tiers (checked per drive):
#    >= 90% -> every 1h   -> Telegram
#    >= 80% -> every 6h   -> Email
#    >= 70% -> every 12h  -> Email
#    >= 60% -> every 24h  -> Email
#    <  60% -> no alert
#
#  RAM alert:
#    > 80% (used/total) -> every 24h -> Email
#
#  QUICK START (run as Administrator):
#    PowerShell -ExecutionPolicy Bypass -File vm_metrics_reporter_windows.ps1 --install
# ================================================================

# ================================================================
#  USER DIRECTORY -edit this list to add/remove users
#  Format: "Full Name:email@domain.com"
# ================================================================
$USERS = @(
    "Ammar Alessa:ammar.aleessa@alkafeelomnnea.com",
    "Ahmed Al-Fadhul:ahmed.m.alfadhel@alkafeelomnnea.com",
    "Ali Alaa:ali.a.abbas@alkafeelomnnea.com",
    "Qasim:qasim.l.ghalib@alkafeelomnnea.com",
    "Ali Yami:ali.m.mahdi@alkafeelomnnea.com",
    "Abbas Mohammad:abbas.m.hamza@alkafeelomnnea.com",
    "Abdullah Raheem:abdullah.r.farhan@alkafeelomnnea.com",
    "mohammed albaqir:mohammed.albaqir.mahdi@alkafeelomnnea.com",
    "Mohamad Ali:mohammed.a.rahim@alkafeelomnnea.com",
    "Hussein Adnan:hussain.adnan.a@alkafeelomnnea.com",
    "Muhammad Nadhum:muhammad.n.hashim@alkafeelomnnea.com",
    "Huda Kareem:huda.k.rasool@alkafeelomnnea.com"
)

# ================================================================
#  CONFIGURATION -populated by --install wizard, do not edit manually
# ================================================================
$N8N_WEBHOOK_URL = "http://192.168.199.107:5678/webhook/508afee7-c80d-44b7-8bd2-6a9acecfb4ab"
$VM_NAME         = ""
$LOCATION        = ""
$NETWORK_VERSION = ""    # "old" | "new" | "Old & New Network"
$OWNER_NAME      = ""
$OWNER_EMAIL     = ""
$CC_EMAILS       = ""

# ================================================================
#  DISK ALERT TIERS -"THRESHOLD:INTERVAL_HOURS" (highest first)
# ================================================================
$DISK_TIERS = "90:1 80:6 70:12 60:24"

# ================================================================
#  RAM ALERT -single threshold
# ================================================================
$RAM_ALERT_THRESHOLD = 80
$RAM_ALERT_INTERVAL  = 24

# ================================================================
#  INTERNAL
# ================================================================
$INSTALL_DIR         = "C:\Program Files\vm-metrics"
$STATE_DIR           = "C:\ProgramData\vm-metrics\state"
$LOG_FILE            = "C:\ProgramData\vm-metrics\vm_metrics.log"
$LOCK_FILE           = "C:\ProgramData\vm-metrics\run.lock"
$SCRIPT_PATH         = "C:\Program Files\vm-metrics\vm_metrics_reporter_windows.ps1"
$DAILY_REPORT_TIME   = "0759"  # 24h format HHmm - time of day to send daily report (if no issues or skipped intervals)
$SKIP_INTERVAL_CHECK = $false

# ================================================================
#  LOGGING
# ================================================================
function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    $logDir = Split-Path $LOG_FILE
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($Host.Name -ne 'Default Host') { Write-Host $line }
}

# ================================================================
#  HELPERS
# ================================================================
function Get-Timestamp {
    try {
        $tz  = [System.TimeZoneInfo]::FindSystemTimeZoneById("Arabian Standard Time")
        $now = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz)
        return $now.ToString("yyyy-MM-dd hh:mm:ss tt")
    } catch {
        return (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    }
}

function Get-PrimaryIP {
    try {
        # Best pick: adapter that is Up AND has a default gateway (= real active connection)
        $cfg = Get-NetIPConfiguration | Where-Object {
            $_.NetAdapter.Status -eq 'Up' -and
            $_.IPv4DefaultGateway -ne $null
        } | Sort-Object { $_.IPv4DefaultGateway.RouteMetric + $_.NetIPv4Interface.InterfaceMetric }

        foreach ($iface in $cfg) {
            $addr = $iface.IPv4Address | Where-Object {
                $_.IPAddress -notmatch '^127\.' -and
                $_.IPAddress -notmatch '^169\.254\.'
            } | Select-Object -First 1
            if ($addr) { return $addr.IPAddress }
        }

        # Fallback: any non-loopback, non-link-local IPv4 (excludes virtual/TAP by gateway logic above)
        $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
            $_.IPAddress -notmatch '^127\.' -and
            $_.IPAddress -notmatch '^169\.254\.' -and
            $_.PrefixOrigin -ne 'WellKnown'
        } | Sort-Object InterfaceIndex | Select-Object -First 1).IPAddress
        if ($ip) { return $ip } else { return "unknown" }
    } catch { return "unknown" }
}

function Get-AllIPs {
    try {
        # Only include IPs from adapters that are Up (skip disconnected VPN/TAP/VMware)
        $ips = Get-NetIPConfiguration | Where-Object {
            $_.NetAdapter.Status -eq 'Up'
        } | ForEach-Object { $_.IPv4Address } | Where-Object {
            $_ -ne $null -and
            $_.IPAddress -notmatch '^127\.' -and
            $_.IPAddress -notmatch '^169\.254\.'
        } | ForEach-Object { $_.IPAddress }
        if ($ips) { return ($ips -join ",") } else { return "unknown" }
    } catch { return "unknown" }
}

# ================================================================
#  LOCK
# ================================================================
function Acquire-Lock {
    try {
        $null = New-Item -Path $LOCK_FILE -ItemType File -ErrorAction Stop
        return $true
    } catch {
        if (Test-Path $LOCK_FILE) {
            $age = (Get-Date) - (Get-Item $LOCK_FILE).CreationTime
            if ($age.TotalMinutes -gt 2) {
                Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue
                try { $null = New-Item -Path $LOCK_FILE -ItemType File -ErrorAction Stop; return $true }
                catch { return $false }
            }
        }
        return $false
    }
}

function Release-Lock {
    Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue
}

# ================================================================
#  DISK TIER LOGIC
# ================================================================
function Get-DiskTierInterval {
    param([int]$Pct)
    foreach ($tier in $DISK_TIERS.Split(' ')) {
        $parts = $tier.Split(':')
        if ($Pct -ge [int]$parts[0]) { return [int]$parts[1] }
    }
    return -1  # below all tiers
}

function Get-DiskTierLabel {
    param([int]$Pct)
    foreach ($tier in $DISK_TIERS.Split(' ')) {
        $t = [int]$tier.Split(':')[0]
        if ($Pct -ge $t) { return ">=${t}%" }
    }
    return "normal"
}

function Should-SendDiskAlert {
    param([int]$Pct, [string]$DriveLabel)

    if ($SKIP_INTERVAL_CHECK) { return $true }

    $interval = Get-DiskTierInterval $Pct
    if ($interval -eq -1) {
        Get-ChildItem $STATE_DIR -Filter "disk_*_$DriveLabel" -ErrorAction SilentlyContinue | Remove-Item -Force
        return $false
    }

    $activeThreshold = 0
    foreach ($tier in $DISK_TIERS.Split(' ')) {
        $t = [int]$tier.Split(':')[0]
        if ($Pct -ge $t) { $activeThreshold = $t; break }
    }

    # Clear state files for other tiers on this drive
    foreach ($tier in $DISK_TIERS.Split(' ')) {
        $t = [int]$tier.Split(':')[0]
        if ($t -ne $activeThreshold) {
            Remove-Item (Join-Path $STATE_DIR "disk_tier_${t}_${DriveLabel}") -Force -ErrorAction SilentlyContinue
        }
    }

    $stateFile = Join-Path $STATE_DIR "disk_tier_${activeThreshold}_${DriveLabel}"
    $nowEpoch  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    if (-not (Test-Path $stateFile)) {
        New-Item -Path $STATE_DIR -ItemType Directory -Force | Out-Null
        Set-Content $stateFile $nowEpoch -Encoding UTF8
        return $true
    }

    $lastSent = [long](Get-Content $stateFile -ErrorAction SilentlyContinue)
    if (-not $lastSent) { $lastSent = 0 }

    if ($interval -eq 0) {
        Set-Content $stateFile $nowEpoch -Encoding UTF8
        return $true
    }

    $elapsedH = [math]::Floor(($nowEpoch - $lastSent) / 3600)
    if ($elapsedH -ge $interval) {
        Set-Content $stateFile $nowEpoch -Encoding UTF8
        return $true
    }

    $nextIn = $interval - $elapsedH
    Write-Log "⏭  Drive ${DriveLabel}: at ${Pct}% (tier: >=${activeThreshold}%, every ${interval}h) -next alert in ~${nextIn}h"
    return $false
}

function Should-SendRamAlert {
    param([int]$Pct)

    if ($SKIP_INTERVAL_CHECK) { return $true }

    if ($Pct -le $RAM_ALERT_THRESHOLD) {
        Remove-Item (Join-Path $STATE_DIR "ram_alert") -Force -ErrorAction SilentlyContinue
        return $false
    }

    $stateFile = Join-Path $STATE_DIR "ram_alert"
    $nowEpoch  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    if (-not (Test-Path $stateFile)) {
        New-Item -Path $STATE_DIR -ItemType Directory -Force | Out-Null
        Set-Content $stateFile $nowEpoch -Encoding UTF8
        return $true
    }

    $lastSent = [long](Get-Content $stateFile -ErrorAction SilentlyContinue)
    if (-not $lastSent) { $lastSent = 0 }

    $elapsedH = [math]::Floor(($nowEpoch - $lastSent) / 3600)
    if ($elapsedH -ge $RAM_ALERT_INTERVAL) {
        Set-Content $stateFile $nowEpoch -Encoding UTF8
        return $true
    }

    $nextIn = $RAM_ALERT_INTERVAL - $elapsedH
    Write-Log "⏭  RAM ${Pct}% (>${RAM_ALERT_THRESHOLD}%, every ${RAM_ALERT_INTERVAL}h) -next alert in ~${nextIn}h"
    return $false
}

# ================================================================
#  SEND METRICS
# ================================================================
function Send-Metrics {
    param(
        [switch]$IsSimulate,
        [int]$SimDiskPct = 0,
        [int]$SimRamPct  = 0,
        [switch]$IsDaily
    )

    $timestamp    = Get-Timestamp
    $resolvedName = if ($VM_NAME) { $VM_NAME } else { $env:COMPUTERNAME }
    $primaryIP    = Get-PrimaryIP
    $allIPs       = Get-AllIPs
    $resolvedLoc  = if ($LOCATION) { $LOCATION } else { "not set" }
    $isDaily      = $IsDaily.IsPresent -or $SKIP_INTERVAL_CHECK

    # ── RAM ──────────────────────────────────────────────────────
    $os          = Get-CimInstance Win32_OperatingSystem
    $ramTotalMB  = [math]::Round($os.TotalVisibleMemorySize / 1024)
    $ramFreeMB   = [math]::Round($os.FreePhysicalMemory / 1024)
    $ramUsedMB   = $ramTotalMB - $ramFreeMB
    $ramInt      = [math]::Floor(($ramUsedMB / $ramTotalMB) * 100)
    $ramUsagePct = [math]::Round(($ramUsedMB / $ramTotalMB) * 100, 1)
    $ramTotalGB  = [math]::Round($ramTotalMB / 1024, 2)
    $ramUsedGB   = [math]::Round($ramUsedMB / 1024, 2)
    $ramFreeGB   = [math]::Round($ramFreeMB / 1024, 2)

    if ($IsSimulate) { $ramInt = $SimRamPct; $ramUsagePct = $SimRamPct }

    # ── Disks ─────────────────────────────────────────────────────
    $allMounts  = [System.Collections.Generic.List[object]]::new()
    $issuesList = [System.Collections.Generic.List[object]]::new()
    $hasIssues  = $false
    $maxPct     = 0
    $rootDisk   = $null

    if ($IsSimulate) {
        # Scan all real drives — override C: with the simulated percentage, keep others real
        $volumes = Get-Volume | Where-Object {
            $_.DriveType -ne 'CD-ROM' -and
            $_.DriveLetter -ne $null -and
            $_.Size -gt 0
        }
        foreach ($vol in $volumes) {
            $dl      = "$($vol.DriveLetter):"
            $totalGB = [math]::Round($vol.Size / 1GB, 2)
            if ($vol.DriveLetter -eq 'C') {
                # Use simulated values for C:
                $usedGB  = [math]::Round($SimDiskPct * $totalGB / 100, 2)
                $freeGB  = [math]::Round($totalGB - $usedGB, 2)
                $usePct  = $SimDiskPct
            } else {
                $freeGB  = [math]::Round($vol.SizeRemaining / 1GB, 2)
                $usedGB  = [math]::Round(($vol.Size - $vol.SizeRemaining) / 1GB, 2)
                $usePct  = if ($totalGB -gt 0) { [math]::Floor(($usedGB / $totalGB) * 100) } else { 0 }
            }
            $mount = [ordered]@{ mount = $dl; total_gb = $totalGB; used_gb = $usedGB; free_gb = $freeGB; usage_pct = $usePct }
            $allMounts.Add($mount)
            if ($vol.DriveLetter -eq 'C') { $rootDisk = $mount }
        }
        if (-not $rootDisk -and $allMounts.Count -gt 0) { $rootDisk = $allMounts[0] }

        # Only raise an issue for the simulated C: drive
        $simMount = $allMounts | Where-Object { $_.mount -eq 'C:' } | Select-Object -First 1
        if (-not $simMount) { $simMount = $allMounts[0] }
        $interval = Get-DiskTierInterval $SimDiskPct
        if ($interval -ge 0) {
            $hasIssues = $true
            $sev = if ($SimDiskPct -ge 90) { "critical" } elseif ($SimDiskPct -ge 80) { "warning" } elseif ($SimDiskPct -ge 70) { "notice" } else { "info" }
            $issuesList.Add([ordered]@{
                type                 = "DISK"
                message              = "Drive C: at ${SimDiskPct}% -$($simMount.free_gb)GB free of $($simMount.total_gb)GB"
                severity             = $sev
                tier                 = (Get-DiskTierLabel $SimDiskPct)
                alert_interval_hours = $interval
                drive                = "C:"
                usage_pct            = $SimDiskPct
            })
            if ($SimDiskPct -gt $maxPct) { $maxPct = $SimDiskPct }
        }
    } else {
        $volumes = Get-Volume | Where-Object {
            $_.DriveType -ne 'CD-ROM' -and
            $_.DriveLetter -ne $null -and
            $_.Size -gt 0
        }

        foreach ($vol in $volumes) {
            $dl      = "$($vol.DriveLetter):"
            $totalGB = [math]::Round($vol.Size / 1GB, 2)
            $freeGB  = [math]::Round($vol.SizeRemaining / 1GB, 2)
            $usedGB  = [math]::Round(($vol.Size - $vol.SizeRemaining) / 1GB, 2)
            $usePct  = if ($totalGB -gt 0) { [math]::Floor(($usedGB / $totalGB) * 100) } else { 0 }

            $mount = [ordered]@{ mount = $dl; total_gb = $totalGB; used_gb = $usedGB; free_gb = $freeGB; usage_pct = $usePct }
            $allMounts.Add($mount)
            if ($vol.DriveLetter -eq 'C') { $rootDisk = $mount }

            if (Should-SendDiskAlert -Pct $usePct -DriveLabel $vol.DriveLetter) {
                $hasIssues = $true
                $sev = if ($usePct -ge 90) { "critical" } elseif ($usePct -ge 80) { "warning" } elseif ($usePct -ge 70) { "notice" } else { "info" }
                $issuesList.Add([ordered]@{
                    type                 = "DISK"
                    message              = "Drive ${dl} at ${usePct}% -${freeGB}GB free of ${totalGB}GB"
                    severity             = $sev
                    tier                 = (Get-DiskTierLabel $usePct)
                    alert_interval_hours = (Get-DiskTierInterval $usePct)
                    drive                = $dl
                    usage_pct            = $usePct
                })
                if ($usePct -gt $maxPct) { $maxPct = $usePct }
            }
        }

        if (-not $rootDisk -and $allMounts.Count -gt 0) { $rootDisk = $allMounts[0] }
    }

    # ── RAM alert ────────────────────────────────────────────────
    $sendRam = if ($IsSimulate) { $SimRamPct -gt $RAM_ALERT_THRESHOLD } else { Should-SendRamAlert -Pct $ramInt }
    if ($isDaily) { $sendRam = $true }

    if ($sendRam) {
        $ramSev = if ($ramInt -gt $RAM_ALERT_THRESHOLD) { "warning" } else { "ok" }
        if ($ramInt -gt $RAM_ALERT_THRESHOLD) { $hasIssues = $true }
        $issuesList.Add([ordered]@{
            type                 = "RAM"
            message              = "RAM at ${ramUsagePct}% -${ramFreeGB}GB free of ${ramTotalGB}GB (${ramUsedMB}MB used / ${ramTotalMB}MB total)"
            severity             = $ramSev
            tier                 = ">80%"
            alert_interval_hours = $RAM_ALERT_INTERVAL
        })
        if ($ramInt -gt $maxPct) { $maxPct = $ramInt }
    }

    if (-not $hasIssues -and -not $isDaily) { return }

    # ── Severity ─────────────────────────────────────────────────
    $severityLabel = if ($maxPct -ge 90) { "🔴 CRITICAL" } elseif ($maxPct -ge 80) { "🟠 WARNING" } elseif ($maxPct -ge 70) { "🟡 NOTICE" } else { "🔵 INFO" }

    # ── Build payload ─────────────────────────────────────────────
    $payload = [ordered]@{
        vm_name         = $resolvedName
        ip              = [ordered]@{ primary = $primaryIP; all = $allIPs }
        os_type         = "windows"
        location        = $resolvedLoc
        timestamp       = $timestamp
        is_daily        = ($isDaily -eq $true)
        has_issues      = $hasIssues
        severity        = $severityLabel
        network_version = $NETWORK_VERSION
        owner           = [ordered]@{ name = $OWNER_NAME; email = $OWNER_EMAIL }
        cc_emails       = $CC_EMAILS
        resource_issues = $issuesList.ToArray()
        ram             = [ordered]@{
            total_gb  = $ramTotalGB
            used_gb   = $ramUsedGB
            free_gb   = $ramFreeGB
            total_mb  = $ramTotalMB
            used_mb   = $ramUsedMB
            free_mb   = $ramFreeMB
            usage_pct = $ramUsagePct
        }
        disk            = [ordered]@{
            root       = if ($rootDisk) { $rootDisk } else { [ordered]@{ total_gb = 0; used_gb = 0; free_gb = 0; usage_pct = 0 } }
            all_mounts = $allMounts.ToArray()
        }
    }

    $json = $payload | ConvertTo-Json -Depth 6 -Compress

    # Log line
    $diskIssues = $issuesList | Where-Object { $_.type -eq 'DISK' }
    if ($diskIssues) {
        $firstDisk = @($diskIssues)[0]
        Write-Log "🚨 Alert: $resolvedName | $($firstDisk.drive) Disk: $($firstDisk.usage_pct)% | RAM: ${ramUsagePct}% | Net: $NETWORK_VERSION | Owner: $OWNER_NAME | $severityLabel"
    } else {
        Write-Log "🚨 Alert: $resolvedName | RAM: ${ramUsagePct}% | Net: $NETWORK_VERSION | Owner: $OWNER_NAME | $severityLabel"
    }

    # POST to n8n
    try {
        $null = Invoke-RestMethod -Uri $N8N_WEBHOOK_URL -Method Post `
            -ContentType "application/json; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
            -TimeoutSec 30 -ErrorAction Stop
        Write-Log "✅ Alert sent"
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Log "❌ Failed (HTTP ${code}): $($_.Exception.Message)"
        exit 1
    }
}

# ================================================================
#  INSTALL WIZARD
# ================================================================
function Invoke-Wizard-Network {
    Write-Host ""
    Write-Host "  +======================================+"
    Write-Host "  |      Step 1 - Network Version        |"
    Write-Host "  +======================================+"
    Write-Host ""
    Write-Host "    1) Old Network"
    Write-Host "    2) New Network"
    Write-Host "    3) Old & New Network"
    Write-Host ""
    while ($true) {
        $choice = Read-Host "  Select [1-3]"
        switch ($choice.Trim()) {
            "1" { $script:NETWORK_VERSION = "old";              Write-Host "  OK Old Network selected";           return }
            "2" { $script:NETWORK_VERSION = "new";              Write-Host "  OK New Network selected";           return }
            "3" { $script:NETWORK_VERSION = "Old & New Network"; Write-Host "  OK Old & New Network selected";    return }
            default { Write-Host "  Please enter 1, 2, or 3" }
        }
    }
}

function Invoke-Wizard-Owner {
    Write-Host ""
    Write-Host "  +======================================+"
    Write-Host "  |    Step 2 - VM Owner (To: email)     |"
    Write-Host "  +======================================+"
    Write-Host ""
    $i = 1
    foreach ($entry in $USERS) {
        $parts  = $entry.Split(':', 2)
        $uname  = $parts[0].Trim()
        $uemail = $parts[1].Trim()
        Write-Host ("    {0,2})  {1,-24} <{2}>" -f $i, $uname, $uemail)
        $i++
    }
    Write-Host ""
    while ($true) {
        $choice = Read-Host "  Select owner [1-$($USERS.Count)]"
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $USERS.Count) {
            $parts  = $USERS[[int]$choice - 1].Split(':', 2)
            $script:OWNER_NAME  = $parts[0].Trim()
            $script:OWNER_EMAIL = $parts[1].Trim()
            Write-Host "  OK Owner -> $script:OWNER_NAME <$script:OWNER_EMAIL>"
            return
        }
        Write-Host "  Invalid - enter a number between 1 and $($USERS.Count)"
    }
}

function Invoke-Wizard-CC {
    Write-Host ""
    Write-Host "  +======================================+"
    Write-Host "  |      Step 3 - CC Recipients          |"
    Write-Host "  +======================================+"
    Write-Host "  (Enter numbers separated by spaces, or press Enter to skip)"
    Write-Host ""
    $i = 1
    foreach ($entry in $USERS) {
        $parts  = $entry.Split(':', 2)
        $uname  = $parts[0].Trim()
        $uemail = $parts[1].Trim()
        if ($uemail -eq $script:OWNER_EMAIL) {
            Write-Host ("    {0,2})  {1,-24} <{2}>  <- owner" -f $i, $uname, $uemail)
        } else {
            Write-Host ("    {0,2})  {1,-24} <{2}>" -f $i, $uname, $uemail)
        }
        $i++
    }
    Write-Host ""
    $script:CC_EMAILS = ""
    while ($true) {
        $raw = Read-Host "  Select CC users [e.g. 2 3 5] or Enter to skip"
        if (-not $raw.Trim()) { Write-Host "  OK No CC recipients selected"; return }
        $tokens = $raw.Trim().Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
        $valid  = $true
        $selectedEmails = @()
        $selectedNames  = @()
        foreach ($tok in $tokens) {
            if ($tok -match '^\d+$' -and [int]$tok -ge 1 -and [int]$tok -le $USERS.Count) {
                $parts = $USERS[[int]$tok - 1].Split(':', 2)
                $selectedEmails += $parts[1].Trim()
                $selectedNames  += $parts[0].Trim()
            } else {
                Write-Host "  Invalid number: $tok -try again"
                $valid = $false; break
            }
        }
        if ($valid) {
            $script:CC_EMAILS = $selectedEmails -join ","
            if ($selectedNames) { Write-Host "  OK CC -> $($selectedNames -join ', ')" }
            return
        }
    }
}

function Patch-Var {
    param([string]$VarName, [string]$Value, [string]$FilePath)
    $content = Get-Content $FilePath -Raw -Encoding UTF8
    $escaped = [regex]::Escape($Value)
    $content = $content -replace "(\`$$VarName\s*=\s*)""[^""]*""", "`${1}`"$Value`""
    Set-Content $FilePath $content -Encoding UTF8 -NoNewline
}

# ================================================================
#  INSTALL
# ================================================================
function Install-Script {
    Write-Host ""
    Write-Host "  +============================================+"
    Write-Host "  |  VM Metrics Reporter - Install (Windows)   |"
    Write-Host "  +============================================+"
    Write-Host "  OS: $([System.Environment]::OSVersion.VersionString)"
    Write-Host ""

    if ($N8N_WEBHOOK_URL -eq "http://YOUR_SERVER_IP:5678/webhook/YOUR_WEBHOOK_ID") {
        Write-Host "  WARNING: N8N_WEBHOOK_URL is still the default placeholder!"
        $confirm = Read-Host "  Continue anyway? (y/N)"
        if ($confirm -notmatch '^[Yy]$') { exit 1 }
    }

    Invoke-Wizard-Network
    Invoke-Wizard-Owner
    Invoke-Wizard-CC

    # Step 4 -VM Identity
    Write-Host ""
    Write-Host "  +======================================+"
    Write-Host "  |      Step 4 - VM Identity            |"
    Write-Host "  +======================================+"
    Write-Host ""
    $defaultHostname    = $env:COMPUTERNAME
    $inputName          = Read-Host "  VM Name [default: $defaultHostname]"
    $script:VM_NAME     = if ($inputName.Trim()) { $inputName.Trim() } else { $defaultHostname }
    $inputLoc           = Read-Host "  Location (e.g. Rack-A Hilla DC1)"
    $script:LOCATION    = if ($inputLoc.Trim())  { $inputLoc.Trim()  } else { "not set" }

    # Create directories
    foreach ($dir in @($INSTALL_DIR, $STATE_DIR, (Split-Path $LOG_FILE))) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $LOG_FILE)) { New-Item -Path $LOG_FILE -ItemType File | Out-Null }

    # Copy script and patch variables
    Copy-Item $PSCommandPath $SCRIPT_PATH -Force
    Patch-Var "VM_NAME"         $script:VM_NAME         $SCRIPT_PATH
    Patch-Var "LOCATION"        $script:LOCATION        $SCRIPT_PATH
    Patch-Var "NETWORK_VERSION" $script:NETWORK_VERSION $SCRIPT_PATH
    Patch-Var "OWNER_NAME"      $script:OWNER_NAME      $SCRIPT_PATH
    Patch-Var "OWNER_EMAIL"     $script:OWNER_EMAIL     $SCRIPT_PATH
    Patch-Var "CC_EMAILS"       $script:CC_EMAILS       $SCRIPT_PATH

    # Task Scheduler
    $psExe    = "PowerShell.exe"
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    # Every-minute task
    $actionRun  = New-ScheduledTaskAction -Execute $psExe -Argument "-ExecutionPolicy Bypass -NonInteractive -File `"$SCRIPT_PATH`" --run"
    $triggerRun = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 1) -Once -At (Get-Date).Date
    Register-ScheduledTask -TaskName "VM-Metrics-Run" -Action $actionRun -Trigger $triggerRun -Settings $settings -Principal $principal -Force | Out-Null

    # Daily task
    $dH           = [int]$DAILY_REPORT_TIME.Substring(0, 2)
    $dM           = [int]$DAILY_REPORT_TIME.Substring(2, 2)
    $dailyAt      = (Get-Date).Date.AddHours($dH).AddMinutes($dM)
    $actionDaily  = New-ScheduledTaskAction -Execute $psExe -Argument "-ExecutionPolicy Bypass -NonInteractive -File `"$SCRIPT_PATH`" --daily"
    $triggerDaily = New-ScheduledTaskTrigger -Daily -At $dailyAt
    Register-ScheduledTask -TaskName "VM-Metrics-Daily" -Action $actionDaily -Trigger $triggerDaily -Settings $settings -Principal $principal -Force | Out-Null

    # Summary
    Write-Host ""
    Write-Host "  +============================================+"
    Write-Host "  |              Install Summary               |"
    Write-Host "  +============================================+"
    Write-Host ""
    Write-Host "  OK Script:      $SCRIPT_PATH"
    Write-Host "  OK Task:        VM-Metrics-Run  (every minute)"
    Write-Host "  OK Task:        VM-Metrics-Daily (daily at 7:59 AM)"
    Write-Host "  OK Log:         $LOG_FILE"
    Write-Host "  OK State dir:   $STATE_DIR"
    Write-Host ""
    Write-Host "  Configuration:"
    Write-Host "     VM Name:     $script:VM_NAME"
    Write-Host "     Location:    $script:LOCATION"
    Write-Host "     Network:     $script:NETWORK_VERSION"
    Write-Host "     Owner (To:): $script:OWNER_NAME <$script:OWNER_EMAIL>"
    if ($script:CC_EMAILS) { Write-Host "     CC:          $script:CC_EMAILS" } else { Write-Host "     CC:          (none)" }
    Write-Host ""
    Write-Host "  Alert tiers (per drive):"
    Write-Host "     Disk >= 90%  -> every 1h   -> Telegram"
    Write-Host "     Disk >= 80%  -> every 6h   -> Email"
    Write-Host "     Disk >= 70%  -> every 12h  -> Email"
    Write-Host "     Disk >= 60%  -> every 24h  -> Email"
    Write-Host "     Disk <  60%  -> no alert"
    Write-Host "     RAM  >  ${RAM_ALERT_THRESHOLD}%   -> every ${RAM_ALERT_INTERVAL}h   -> Email"
    Write-Host "     Daily report -> 7:59 AM    -> always sends"
    Write-Host ""
}

# ================================================================
#  UNINSTALL
# ================================================================
function Uninstall-Script {
    Write-Host "Uninstalling VM Metrics Reporter (Windows)..."
    Unregister-ScheduledTask -TaskName "VM-Metrics-Run"   -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "VM-Metrics-Daily" -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $LOCK_FILE   -Force   -ErrorAction SilentlyContinue
    Remove-Item $SCRIPT_PATH -Force   -ErrorAction SilentlyContinue
    Remove-Item $STATE_DIR   -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $LOG_FILE    -Force   -ErrorAction SilentlyContinue
    Remove-Item $INSTALL_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "OK Uninstalled. Everything removed:"
    Write-Host "   - Task: VM-Metrics-Run"
    Write-Host "   - Task: VM-Metrics-Daily"
    Write-Host "   - $SCRIPT_PATH"
    Write-Host "   - $STATE_DIR"
    Write-Host "   - $LOG_FILE"
}

# ================================================================
#  STATUS
# ================================================================
function Show-Status {
    Write-Host "========================================================"
    Write-Host "  VM Metrics Reporter - Status (Windows)"
    Write-Host "========================================================"
    $scriptOk  = Test-Path $SCRIPT_PATH
    $taskRun   = Get-ScheduledTask -TaskName "VM-Metrics-Run"   -ErrorAction SilentlyContinue
    $taskDaily = Get-ScheduledTask -TaskName "VM-Metrics-Daily" -ErrorAction SilentlyContinue
    Write-Host "  Script:       $(if ($scriptOk)  { "OK $SCRIPT_PATH" }    else { "NOT INSTALLED" })"
    Write-Host "  Task (run):   $(if ($taskRun)   { "OK Active" }           else { "NOT FOUND" })"
    Write-Host "  Task (daily): $(if ($taskDaily) { "OK Active" }           else { "NOT FOUND" })"
    Write-Host "  Webhook:      $N8N_WEBHOOK_URL"
    Write-Host ""
    Write-Host "  Configuration:"
    Write-Host "    VM Name:     $(if ($VM_NAME)         { $VM_NAME }         else { "not set" })"
    Write-Host "    Location:    $(if ($LOCATION)        { $LOCATION }        else { "not set" })"
    Write-Host "    Network:     $(if ($NETWORK_VERSION) { $NETWORK_VERSION } else { "not set" })"
    Write-Host "    Owner (To:): $(if ($OWNER_NAME)      { "$OWNER_NAME <$OWNER_EMAIL>" } else { "not set" })"
    Write-Host "    CC:          $(if ($CC_EMAILS)        { $CC_EMAILS }       else { "(none)" })"
    Write-Host ""

    # Live snapshot
    $os       = Get-CimInstance Win32_OperatingSystem
    $rTotalMB = [math]::Round($os.TotalVisibleMemorySize / 1024)
    $rFreeMB  = [math]::Round($os.FreePhysicalMemory / 1024)
    $rUsedMB  = $rTotalMB - $rFreeMB
    $rPct     = [math]::Round(($rUsedMB / $rTotalMB) * 100, 1)
    $rInt     = [math]::Floor(($rUsedMB / $rTotalMB) * 100)
    $rTotalGB = [math]::Round($rTotalMB / 1024, 2)
    $rUsedGB  = [math]::Round($rUsedMB / 1024, 2)
    $rFreeGB  = [math]::Round($rFreeMB / 1024, 2)

    Write-Host "  --- Live Snapshot ---"
    Write-Host "    VM Name: $(if ($VM_NAME) { $VM_NAME } else { $env:COMPUTERNAME })"
    Write-Host "    IP:      $(Get-PrimaryIP)"
    Write-Host "    RAM:     ${rPct}% | ${rUsedGB}GB used / ${rTotalGB}GB total / ${rFreeGB}GB free"
    if ($rInt -gt $RAM_ALERT_THRESHOLD) {
        Write-Host "    RAM Alert: ACTIVE (>${RAM_ALERT_THRESHOLD}%) -> every ${RAM_ALERT_INTERVAL}h"
    } else {
        Write-Host "    RAM Alert: OK (<=${RAM_ALERT_THRESHOLD}% - no alert)"
    }
    Write-Host ""
    Write-Host "    Drives:"
    $volumes = Get-Volume | Where-Object { $_.DriveType -ne 'CD-ROM' -and $_.DriveLetter -ne $null -and $_.Size -gt 0 }
    foreach ($vol in $volumes) {
        $dl      = "$($vol.DriveLetter):"
        $tGB     = [math]::Round($vol.Size / 1GB, 2)
        $fGB     = [math]::Round($vol.SizeRemaining / 1GB, 2)
        $uGB     = [math]::Round(($vol.Size - $vol.SizeRemaining) / 1GB, 2)
        $pct     = if ($tGB -gt 0) { [math]::Floor(($uGB / $tGB) * 100) } else { 0 }
        $intv    = Get-DiskTierInterval $pct
        $tierStr = if ($intv -ge 0) { "$(Get-DiskTierLabel $pct) -> every $(if ($intv -eq 0) { "1 min" } else { "${intv}h" })" } else { "OK (< 60% - no alert)" }
        Write-Host "    $dl  ${pct}% used | ${uGB}GB used / ${tGB}GB total | $tierStr"
    }
    Write-Host ""
    Write-Host "  --- Last Alert Times ---"
    $stateFiles = Get-ChildItem $STATE_DIR -ErrorAction SilentlyContinue
    if ($stateFiles) {
        foreach ($f in $stateFiles) {
            $epoch = [long](Get-Content $f.FullName -ErrorAction SilentlyContinue)
            if ($epoch) {
                $human = [DateTimeOffset]::FromUnixTimeSeconds($epoch).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss")
                Write-Host "    $($f.Name): last sent $human"
            }
        }
    } else {
        Write-Host "    (no alerts sent yet)"
    }
    Write-Host ""
    Write-Host "  --- Last 20 Log Entries ---"
    if (Test-Path $LOG_FILE) { Get-Content $LOG_FILE -Tail 20 } else { Write-Host "  (no logs yet)" }
}

# ================================================================
#  SIMULATE
# ================================================================
function Invoke-Simulate {
    param([int]$DiskPct = 85, [int]$RamPct = 75)
    Write-Host "Simulating: Disk=${DiskPct}% | RAM=${RamPct}%"
    Send-Metrics -IsSimulate -SimDiskPct $DiskPct -SimRamPct $RamPct
}

function Invoke-SimulateDaily {
    param([int]$DiskPct = 55, [int]$RamPct = 60)
    Write-Host "Simulating DAILY report: Disk=${DiskPct}% | RAM=${RamPct}% | is_daily=true"
    $script:SKIP_INTERVAL_CHECK = $true
    Send-Metrics -IsSimulate -SimDiskPct $DiskPct -SimRamPct $RamPct -IsDaily
    $script:SKIP_INTERVAL_CHECK = $false
}

# ================================================================
#  MAIN
# ================================================================
$arg = if ($args.Count -gt 0) { $args[0] } else { "" }

switch ($arg) {
    "--install"   { Install-Script }
    "--uninstall" { Uninstall-Script }
    "--run" {
        $now = Get-Date -Format "HHmm"
        if ($now -eq $DAILY_REPORT_TIME) { exit 0 }
        if (Acquire-Lock) {
            try   { Send-Metrics }
            finally { Release-Lock }
        }
    }
    "--daily" {
        $script:SKIP_INTERVAL_CHECK = $true
        Write-Log "📅 Daily 7:59 AM report -sending full status..."
        $locked = $false
        for ($i = 0; $i -lt 6; $i++) {
            if (Acquire-Lock) { $locked = $true; break }
            Start-Sleep -Seconds 5
        }
        if ($locked) {
            try   { Send-Metrics -IsDaily }
            finally { Release-Lock }
        } else {
            Write-Log "❌ Daily report failed: could not acquire lock"
        }
    }
    "--force" {
        Remove-Item "$STATE_DIR\disk_tier_*" -Force -ErrorAction SilentlyContinue
        Remove-Item "$STATE_DIR\ram_alert"   -Force -ErrorAction SilentlyContinue
        Write-Log "🔧 Forced: cleared state, sending now..."
        if (Acquire-Lock) {
            try   { Send-Metrics }
            finally { Release-Lock }
        } else {
            Write-Log "❌ Force failed: could not acquire lock"
        }
    }
    "--status" { Show-Status }
    "--simulate" {
        $d = if ($args.Count -gt 1) { [int]$args[1] } else { 85 }
        $r = if ($args.Count -gt 2) { [int]$args[2] } else { 75 }
        Invoke-Simulate -DiskPct $d -RamPct $r
    }
    "--simulate-daily" {
        $d = if ($args.Count -gt 1) { [int]$args[1] } else { 55 }
        $r = if ($args.Count -gt 2) { [int]$args[2] } else { 60 }
        Invoke-SimulateDaily -DiskPct $d -RamPct $r
    }
    default {
        Write-Host ""
        Write-Host "  VM Metrics Reporter (Windows PowerShell)"
        Write-Host "  Compatible: Windows 10 / Windows 11 / Server 2019 / Server 2022"
        Write-Host "  Run as Administrator!"
        Write-Host ""
        Write-Host "  Usage: PowerShell -ExecutionPolicy Bypass -File vm_metrics_reporter_windows.ps1 [OPTION]"
        Write-Host ""
        Write-Host "    --install                  Run setup wizard + install scheduled tasks"
        Write-Host "    --uninstall                Remove everything"
        Write-Host "    --run                      Run check (sends only if interval elapsed)"
        Write-Host "    --daily                    Send full status now (ignores all intervals)"
        Write-Host "    --force                    Send immediately, ignore all timers"
        Write-Host "    --status                   Show config + live snapshot + last alerts"
        Write-Host "    --simulate [D] [R]         Test alert: D=disk%, R=ram% (defaults: 85 75)"
        Write-Host "                                 --simulate 92        (CRITICAL -> Telegram+Email)"
        Write-Host "                                 --simulate 85 85     (WARNING  -> Email)"
        Write-Host "                                 --simulate 65 50     (INFO     -> Email)"
        Write-Host "                                 --simulate 5 50      (nothing sent)"
        Write-Host "    --simulate-daily [D] [R]   Test daily report (is_daily=true)"
        Write-Host "                                 --simulate-daily"
        Write-Host "                                 --simulate-daily 85 70"
        Write-Host "                                 --simulate-daily 92 50"
        Write-Host ""
        Write-Host "  Disk tiers (checked per drive):"
        Write-Host "    >= 90%  ->  every 1h   -> Telegram"
        Write-Host "    >= 80%  ->  every 6h   -> Email"
        Write-Host "    >= 70%  ->  every 12h  -> Email"
        Write-Host "    >= 60%  ->  every 24h  -> Email"
        Write-Host "    <  60%  ->  no alert"
        Write-Host ""
        Write-Host "  RAM: > ${RAM_ALERT_THRESHOLD}% (used/total) -> every ${RAM_ALERT_INTERVAL}h -> Email"
        Write-Host "  Daily: 7:59 AM every day -> always sends full status"
        Write-Host ""
    }
}
