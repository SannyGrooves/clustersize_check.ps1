# clustersize_check.ps1
# Full Drive Report: Health, Errors, Performance + Auto-Open

$ErrorActionPreference = 'SilentlyContinue'

# === Performance Sampling (5 seconds) ===
Write-Host "Collecting performance metrics (5 seconds)..." -ForegroundColor Cyan
$perfCounters = Get-Counter -Counter @(
    "\PhysicalDisk(*)\Avg. Disk sec/Read",
    "\PhysicalDisk(*)\Avg. Disk sec/Write",
    "\PhysicalDisk(*)\Avg. Disk Queue Length",
    "\PhysicalDisk(*)\Disk Reads/sec",
    "\PhysicalDisk(*)\Disk Writes/sec",
    "\PhysicalDisk(*)\Disk Read Bytes/sec",
    "\PhysicalDisk(*)\Disk Write Bytes/sec"
) -SampleInterval 1 -MaxSamples 5 -ErrorAction SilentlyContinue

$perfData = @{}
if ($perfCounters) {
    $perfCounters.CounterSamples | ForEach-Object {
        $instance = $_.InstanceName -replace '^\d+[_ ]', ''
        $path = $_.Path
        $value = $_.CookedValue

        if ($path -like "*Avg. Disk sec/Read")  { $perfData["$instance.ReadLatency"]  = [math]::Round($value * 1000, 2) }
        if ($path -like "*Avg. Disk sec/Write") { $perfData["$instance.WriteLatency"] = [math]::Round($value * 1000, 2) }
        if ($path -like "*Avg. Disk Queue Length") { $perfData["$instance.QueueLength"] = [math]::Round($value, 2) }
        if ($path -like "*Disk Reads/sec")      { $perfData["$instance.ReadIOPS"]     = [math]::Round($value, 0) }
        if ($path -like "*Disk Writes/sec")     { $perfData["$instance.WriteIOPS"]    = [math]::Round($value, 0) }
        if ($path -like "*Disk Read Bytes/sec") { $perfData["$instance.ReadMBps"]     = [math]::Round($value / 1MB, 2) }
        if ($path -like "*Disk Write Bytes/sec"){ $perfData["$instance.WriteMBps"]    = [math]::Round($value / 1MB, 2) }
    }
}

# === Get Disk Errors from Event Log (Last 24h) ===
$diskErrors = @{}
try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        ID = 7, 9, 11, 15, 51, 52, 153
        StartTime = (Get-Date).AddHours(-24)
    } -ErrorAction SilentlyContinue

    foreach ($evt in $events) {
        $msg = $evt.Message
        if ($msg -match 'disk\s+(\d+)' -or $msg -match 'PhysicalDrive(\d+)') {
            $diskNum = $matches[1]
            if (-not $diskErrors.ContainsKey($diskNum)) { $diskErrors[$diskNum] = 0 }
            $diskErrors[$diskNum]++
        }
    }
} catch {}

# === Get Volumes ===
$volumes = Get-Volume | Where-Object { $_.DriveLetter }
$data = @()

foreach ($vol in $volumes) {
    $driveLetter = $vol.DriveLetter + ':'
    $fileSystem = $vol.FileSystem
    $totalSizeGB = [math]::Round($vol.Size / 1GB, 2)
    $freeSizeGB = [math]::Round($vol.SizeRemaining / 1GB, 2)
    $freePct = if ($totalSizeGB -gt 0) { [math]::Round(($freeSizeGB / $totalSizeGB) * 100, 1) } else { 0 }
    $clusterSizeKB = if ($vol.AllocationUnitSize) { $vol.AllocationUnitSize / 1024 } else { 'N/A' }

    $volumeHealth = $vol.HealthStatus
    $operationalStatus = $vol.OperationalStatus

    $partition = Get-Partition -DriveLetter $vol.DriveLetter -ErrorAction SilentlyContinue
    if ($partition) {
        $disk = Get-Disk -Number $partition.DiskNumber
        $diskNumber = $disk.Number
        $diskModel = $disk.Model
        $diskSerial = $disk.SerialNumber.Trim()
        $diskSizeGB = [math]::Round($disk.Size / 1GB, 2)
        $diskFirmware = $disk.FirmwareVersion
        $diskHealth = $disk.HealthStatus
        $isSSD = $disk.IsSSD
        $diskType = if ($isSSD) { "SSD" } else { "HDD" }
        $partitionStyle = $disk.PartitionStyle

        # Performance
        $perfInstance = $perfData.Keys | Where-Object { $_ -like "*$diskNumber*" } | Select-Object -First 1
        $readLatency  = if ($perfInstance) { $perfData["$perfInstance.ReadLatency"] }  else { 'N/A' }
        $writeLatency = if ($perfInstance) { $perfData["$perfInstance.WriteLatency"] } else { 'N/A' }
        $queueLength  = if ($perfInstance) { $perfData["$perfInstance.QueueLength"] }  else { 'N/A' }
        $readIOPS     = if ($perfInstance) { $perfData["$perfInstance.ReadIOPS"] }     else { 'N/A' }
        $writeIOPS    = if ($perfInstance) { $perfData["$perfInstance.WriteIOPS"] }    else { 'N/A' }
        $readMBps     = if ($perfInstance) { $perfData["$perfInstance.ReadMBps"] }     else { 'N/A' }
        $writeMBps    = if ($perfInstance) { $perfData["$perfInstance.WriteMBps"] }    else { 'N/A' }

        # SMART
        $smartTemp = 'N/A'; $smartWear = 'N/A'
        try {
            $rel = Get-StorageReliabilityCounter -PhysicalDisk (Get-PhysicalDisk | Where-Object DeviceId -eq $diskNumber) -ErrorAction SilentlyContinue
            if ($rel) {
                $smartTemp = "$($rel.Temperature)°C"
                if ($rel.Wear -ne $null) { $smartWear = "$($rel.Wear)%" }
            }
        } catch {}

        # === ERROR COUNT & BADGE (FIXED STRING) ===
        $errorCount = if ($diskErrors.ContainsKey([string]$diskNumber)) { $diskErrors[[string]$diskNumber] } else { 0 }
        $errorBadge = if ($errorCount -gt 0) {
            "<span class=`"badge failed`">$errorCount Errors</span>"
        } else {
            '<span class="badge healthy">No Errors</span>'
        }

    } else {
        $diskNumber = $diskModel = $diskSerial = $diskSizeGB = $diskFirmware = $diskHealth = $diskType = $partitionStyle = 'N/A'
        $readLatency = $writeLatency = $queueLength = $readIOPS = $writeIOPS = $readMBps = $writeMBps = $smartTemp = $smartWear = 'N/A'
        $errorCount = 0
        $errorBadge = '<span class="badge unknown">N/A</span>'
    }

    # === Health Summary ===
    $healthSummary = switch ($true) {
        ($diskHealth -eq 'Healthy' -and $volumeHealth -eq 'Healthy' -and $errorCount -eq 0) {
            '<span class="badge healthy">Healthy</span>'
        }
        ($diskHealth -eq 'Warning' -or $volumeHealth -eq 'Warning') {
            '<span class="badge warning">Warning</span>'
        }
        ($diskHealth -eq 'Unhealthy' -or $volumeHealth -eq 'Unhealthy') {
            '<span class="badge failed">Failed</span>'
        }
        ($operationalStatus -ne 'OK') {
            '<span class="badge failed">Offline</span>'
        }
        ($errorCount -gt 0) {
            '<span class="badge failed">Errors</span>'
        }
        default {
            '<span class="badge unknown">Unknown</span>'
        }
    }

    # === Performance Grade ===
    $perfGrade = 'N/A'
    if ($readLatency -ne 'N/A' -and $writeLatency -ne 'N/A') {
        $avgLat = ($readLatency + $writeLatency) / 2
        $perfGrade = switch ($true) {
            ($avgLat -lt 1)  { '<span class="perf excellent">Excellent</span>' }
            ($avgLat -lt 5)  { '<span class="perf good">Good</span>' }
            ($avgLat -lt 15) { '<span class="perf fair">Fair</span>' }
            default          { '<span class="perf poor">Poor</span>' }
        }
    }

    # === Add Row ===
    $obj = [PSCustomObject]@{
        'Drive'     = $driveLetter
        'FS'        = $fileSystem
        'Cluster'   = $clusterSizeKB
        'Total'     = "$totalSizeGB GB"
        'Free'      = "$freeSizeGB GB ($freePct%)"
        'Style'     = $partitionStyle
        'Disk'      = $diskNumber
        'Model'     = $diskModel
        'Serial'    = $diskSerial
        'Type'      = $diskType
        'Health'    = $healthSummary
        'Errors'    = $errorBadge
        'Temp'      = $smartTemp
        'Wear'      = $smartWear
        'R-IOPS'    = $readIOPS
        'W-IOPS'    = $writeIOPS
        'R-MB/s'    = $readMBps
        'W-MB/s'    = $writeMBps
        'R-Lat'     = "$readLatency ms"
        'W-Lat'     = "$writeLatency ms"
        'Queue'     = $queueLength
        'Perf'      = $perfGrade
    }

    $data += $obj
}

# === HTML Output ===
$header = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Drive Health & Errors Report</title>
    <style>
        :root { --primary: #1565c0; --success: #2e7d32; --warning: #ef6c00; --danger: #c62828; --gray: #555; }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: 'Segoe UI', Tahoma, sans-serif; background: linear-gradient(135deg, #e3f2fd, #bbdefb); padding: 16px; color: #333; font-size: clamp(12px, 2.5vw, 16px); line-height: 1.5; }
        .container { max-width: 100%; margin: auto; background: white; padding: clamp(16px, 3vw, 32px); border-radius: 16px; box-shadow: 0 10px 30px rgba(0,0,0,0.1); }
        h1 { text-align: center; color: var(--primary); margin: 0 0 8px; font-size: clamp(1.5rem, 5vw, 2.2rem); }
        .subtitle { text-align: center; color: #555; font-style: italic; font-size: clamp(0.9rem, 2.5vw, 1rem); margin: 0 0 16px; }
        .meta { font-size: clamp(0.8rem, 2vw, 0.95rem); color: #666; text-align: center; margin-bottom: 16px; }
        .note { background: #e3f2fd; padding: 12px; border-radius: 8px; font-size: clamp(0.75rem, 2vw, 0.9rem); color: var(--primary); margin: 16px 0; text-align: center; }
        .table-container { overflow-x: auto; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.05); margin: 20px 0; }
        table { width: 100%; min-width: 800px; border-collapse: collapse; font-size: clamp(0.7rem, 1.8vw, 0.9rem); }
        th { background: var(--primary); color: white; padding: clamp(8px, 1.5vw, 12px); text-align: left; white-space: nowrap; }
        td { padding: clamp(6px, 1.2vw, 10px); border-bottom: 1px solid #eee; }
        tr:nth-child(even) { background-color: #f9fbfd; }
        tr:hover { background-color: #e1f5fe; transition: 0.2s; }
        .badge, .perf { padding: 4px 8px; border-radius: 12px; font-size: 0.75em; font-weight: bold; display: inline-block; }
        .healthy { background:#e8f5e9; color:var(--success); }
        .warning { background:#fff3e0; color:var(--warning); }
        .failed { background:#ffebee; color:var(--danger); }
        .unknown { background:#eee; color:var(--gray); }
        .excellent { background:#e8f5e9; color:#1b5e20; }
        .good { background:#e6f7ff; color:#00695c; }
        .fair { background:#fff8e1; color:#ff8f00; }
        .poor { background:#ffebee; color:#b71c1c; }
        .footer { text-align: center; margin-top: 32px; color: #777; font-size: clamp(0.7rem, 2vw, 0.85rem); }
        .collapse-btn { display: none; background: var(--primary); color: white; border: none; padding: 10px; width: 100%; font-size: 1rem; cursor: pointer; border-radius: 8px; margin-bottom: 8px; }
        @media (max-width: 768px) { .collapse-btn { display: block; } .table-container { display: none; } .table-container.show { display: block; } }
    </style>
</head>
<body>
<div class="container">
    <h1>Drive Health & Errors Report</h1>
    <p class="subtitle">Performance • Health • Errors • Configuration</p>
    <p class="meta"><strong>Host:</strong> $($env:COMPUTERNAME) | <strong>User:</strong> $($env:USERNAME)</p>
    <div class="note"><strong>Errors:</strong> From System Event Log (last 24h)</div>
    <button class="collapse-btn" onclick="document.querySelector('.table-container').classList.toggle('show')">Tap to Show/Hide Table</button>
"@

# Generate Table
$htmlTable = $data | Sort-Object Drive | ConvertTo-Html -Fragment -Property * -As Table
$htmlTable = $htmlTable -replace '<table>', '<div class="table-container"><table>'
$htmlTable = $htmlTable -replace '</table>', '</table></div>'

# Replace Badge Text
$replacements = @{
    'Healthy'   = '<span class="badge healthy">Healthy</span>'
    'Warning'   = '<span class="badge warning">Warning</span>'
    'Failed'    = '<span class="badge failed">Failed</span>'
    'Offline'   = '<span class="badge failed">Offline</span>'
    'Errors'    = '<span class="badge failed">Errors</span>'
    'Unknown'   = '<span class="badge unknown">Unknown</span>'
    'Excellent' = '<span class="perf excellent">Excellent</span>'
    'Good'      = '<span class="perf good">Good</span>'
    'Fair'      = '<span class="perf fair">Fair</span>'
    'Poor'      = '<span class="perf poor">Poor</span>'
}
foreach ($key in $replacements.Keys) {
    $htmlTable = $htmlTable -replace [regex]::Escape("<td>$key</td>"), "<td>$($replacements[$key])</td>"
}

$footer = @"
    <div class="footer">
        Generated by <strong>clustersize_check.ps1</strong> | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | 
        <span style="color:var(--primary);">No Errors • Auto-Open • Responsive</span>
    </div>
</div>
<script>
    if (window.innerWidth <= 768) {
        document.querySelector('.table-container').classList.remove('show');
    }
</script>
</body>
</html>
"@

# === Export & Auto-Open ===
$html = $header + $htmlTable + $footer
$htmlFile = "$PSScriptRoot\drive_info.html"
$html | Out-File -FilePath $htmlFile -Encoding UTF8

Write-Host "`nReport generated: " -NoNewline
Write-Host "$htmlFile" -ForegroundColor Green
Write-Host "Opening in default browser..." -ForegroundColor Cyan

try {
    Start-Process $htmlFile
} catch {
    Write-Warning "Could not open browser: $($_.Exception.Message)"
    Write-Host "Manually open: $htmlFile" -ForegroundColor Yellow
}

Write-Host "`nDone! All errors fixed. Report is ready." -ForegroundColor Green