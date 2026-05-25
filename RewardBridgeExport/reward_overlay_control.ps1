Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$overlayScript = Join-Path $baseDir "reward_overlay.ps1"
$statusFile = Join-Path $baseDir "reward_overlay.runtime.json"
$logFile = Join-Path $baseDir "reward_overlay.runtime.log"
$pidFile = Join-Path $baseDir "reward_overlay.pid"
$stdoutFile = Join-Path $baseDir "reward_overlay.stdout.log"
$stderrFile = Join-Path $baseDir "reward_overlay.stderr.log"

function Get-OverlayProcesses {
  $result = @()
  try {
    if (Test-Path $pidFile) {
      $rawPid = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
      if ($rawPid) {
        $proc = Get-Process -Id ([int]$rawPid) -ErrorAction SilentlyContinue
        if ($proc) {
          $result += $proc
        }
      }
    }
  } catch {
  }
  return @($result)
}

function Start-OverlayProcess {
  if ((Get-OverlayProcesses).Count -gt 0) {
    return
  }

  foreach ($path in @($stdoutFile, $stderrFile)) {
    try {
      if (Test-Path $path) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
      }
    } catch {
    }
  }

  $quotedScript = '"' + $overlayScript + '"'
  $arguments = "-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $quotedScript"

  $proc = Start-Process powershell.exe -PassThru -ArgumentList $arguments `
    -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

  try {
    Set-Content -Path $pidFile -Value $proc.Id -Encoding ASCII
  } catch {
  }
}

function Stop-OverlayProcess {
  foreach ($proc in Get-OverlayProcesses) {
    try {
      Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    } catch {
    }
  }

  try {
    if (Test-Path $pidFile) {
      Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
  } catch {
  }
}

function Read-StatusText {
  $procs = @(Get-OverlayProcesses)
  if ($procs.Count -eq 0 -and -not (Test-Path $statusFile)) {
    return "State: idle{0}Message: Overlay has not been started yet." -f [Environment]::NewLine
  }

  try {
    if (-not (Test-Path $statusFile)) {
      return "State: starting{0}Message: Waiting for runtime status file..." -f [Environment]::NewLine
    }

    $raw = [System.IO.File]::ReadAllText($statusFile, [System.Text.Encoding]::UTF8)
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) {
      $raw = $raw.Substring(1)
    }
    $obj = $raw | ConvertFrom-Json
    $state = [string]$obj.state
    $message = [string]$obj.message

    if ($procs.Count -eq 0 -and $state -eq "test") {
      $state = "idle"
      $message = "Last recorded state came from test mode. Press Start to launch the real overlay."
    }

    @(
      "State: $state"
      "Message: $message"
      "PID: $($obj.pid)"
      "Timestamp: $($obj.timestamp)"
    ) -join [Environment]::NewLine
  } catch {
    "Failed to read status file: $($_.Exception.Message)"
  }
}

function Read-LogTail {
  $sources = @()
  if (Test-Path $logFile) { $sources += $logFile }
  if (Test-Path $stdoutFile) { $sources += $stdoutFile }
  if (Test-Path $stderrFile) { $sources += $stderrFile }

  if ($sources.Count -eq 0) {
    return "No runtime log yet."
  }

  try {
    $lines = @()
    foreach ($source in $sources) {
      $lines += "===== $([System.IO.Path]::GetFileName($source)) ====="
      $lines += Get-Content $source -ErrorAction SilentlyContinue
    }
    if ($lines.Count -gt 20) {
      $lines = $lines | Select-Object -Last 20
    }
    ($lines -join [Environment]::NewLine)
  } catch {
    "Failed to read runtime log: $($_.Exception.Message)"
  }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Reward Overlay Control"
$form.Size = New-Object System.Drawing.Size(720, 520)
$form.StartPosition = "CenterScreen"
$form.TopMost = $true

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(16, 16)
$statusLabel.Size = New-Object System.Drawing.Size(660, 24)
$statusLabel.Font = New-Object System.Drawing.Font("Malgun Gothic", 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($statusLabel)

$stateBox = New-Object System.Windows.Forms.TextBox
$stateBox.Location = New-Object System.Drawing.Point(16, 48)
$stateBox.Size = New-Object System.Drawing.Size(660, 96)
$stateBox.Multiline = $true
$stateBox.ReadOnly = $true
$stateBox.ScrollBars = "Vertical"
$stateBox.Font = New-Object System.Drawing.Font("Consolas", 10)
$form.Controls.Add($stateBox)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(16, 188)
$logBox.Size = New-Object System.Drawing.Size(660, 240)
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = "Vertical"
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($logBox)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = "Start"
$startButton.Location = New-Object System.Drawing.Point(16, 448)
$startButton.Size = New-Object System.Drawing.Size(90, 32)
$form.Controls.Add($startButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = "Stop"
$stopButton.Location = New-Object System.Drawing.Point(116, 448)
$stopButton.Size = New-Object System.Drawing.Size(90, 32)
$form.Controls.Add($stopButton)

$restartButton = New-Object System.Windows.Forms.Button
$restartButton.Text = "Restart"
$restartButton.Location = New-Object System.Drawing.Point(216, 448)
$restartButton.Size = New-Object System.Drawing.Size(90, 32)
$form.Controls.Add($restartButton)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "Refresh"
$refreshButton.Location = New-Object System.Drawing.Point(316, 448)
$refreshButton.Size = New-Object System.Drawing.Size(90, 32)
$form.Controls.Add($refreshButton)

$openFolderButton = New-Object System.Windows.Forms.Button
$openFolderButton.Text = "Open Folder"
$openFolderButton.Location = New-Object System.Drawing.Point(416, 448)
$openFolderButton.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($openFolderButton)

function Update-Ui {
  $procs = @(Get-OverlayProcesses)
  if ($procs.Count -gt 0) {
    $statusLabel.Text = "Overlay process: RUNNING ($($procs.Count))"
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(34, 197, 94)
  } else {
    $statusLabel.Text = "Overlay process: STOPPED"
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
  }

  $stateBox.Text = Read-StatusText
  $logBox.Text = Read-LogTail
  $logBox.SelectionStart = $logBox.TextLength
  $logBox.ScrollToCaret()
}

$startButton.Add_Click({
  Start-OverlayProcess
  Start-Sleep -Milliseconds 500
  Update-Ui
})

$stopButton.Add_Click({
  Stop-OverlayProcess
  Start-Sleep -Milliseconds 300
  Update-Ui
})

$restartButton.Add_Click({
  Stop-OverlayProcess
  Start-Sleep -Milliseconds 300
  Start-OverlayProcess
  Start-Sleep -Milliseconds 500
  Update-Ui
})

$refreshButton.Add_Click({ Update-Ui })
$openFolderButton.Add_Click({ Start-Process explorer.exe $baseDir })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({ Update-Ui })
$timer.Start()

Update-Ui
Start-OverlayProcess
Start-Sleep -Milliseconds 500
Update-Ui
[void]$form.ShowDialog()
