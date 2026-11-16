<#
.SYNOPSIS
  CleanJunk - find and remove temp files and regenerable caches on Windows 10/11.
.DESCRIPTION
  Default: opens a window where you tick what to clean. Nothing is deleted until you confirm.
  Never touches Downloads, Documents, Desktop, Docker/WSL data, or app logins/settings.
.PARAMETER ScanOnly
  Text mode: list sizes, delete nothing.
.PARAMETER Console
  Text mode: scan, then pick what to clean by typing.
.PARAMETER MinAgeHours
  Only delete files not modified in the last N hours (default 24). Use 0 to delete everything.
#>
param(
  [switch]$ScanOnly,
  [switch]$Console,
  [int]$MinAgeHours = 24,
  [string]$SelfTest         # developer option: save a screenshot of the window to this PNG path and exit
)

$Version = '1.0.0'
$ErrorActionPreference = 'SilentlyContinue'

if ($env:OS -ne 'Windows_NT' -or [Environment]::OSVersion.Version.Major -lt 10) {
  Write-Host 'CleanJunk needs Windows 10 or Windows 11.'
  return
}

$L   = $env:LOCALAPPDATA
$R   = $env:APPDATA
$U   = $env:USERPROFILE
$Win = $env:SystemRoot
$PD  = $env:ProgramData
$SysDrive  = $env:SystemDrive                # e.g. C:
$SysLetter = $SysDrive.TrimEnd(':')
$CH  = "$L\Google\Chrome\User Data"
$ED  = "$L\Microsoft\Edge\User Data"
$script:MinAgeHours = $MinAgeHours

# G = Safe (always regenerates, no downside) | Optional (regenerates, but slower next launch / re-download)
# X = top-level names inside the folder to skip,  D = description shown in the window
$targets = @(
  @{ N='User temp files';               G='Safe';     D='Leftover files from apps and installers';           P=@($env:TEMP) },
  @{ N='Windows temp files';            G='Safe';     D='System temporary files';                            P=@("$Win\Temp") },
  @{ N='Windows Update download cache'; G='Safe';     D='Downloads of updates that are already installed';   P=@("$Win\SoftwareDistribution\Download") },
  @{ N='Windows logs';                  G='Safe';     D='Old system log files';                              P=@("$Win\Logs") },
  @{ N='Crash dumps / error reports';   G='Safe';     D='Crash reports from apps and Windows';               P=@("$L\CrashDumps","$PD\Microsoft\Windows\WER","$L\Microsoft\Windows\WER") },
  @{ N='Explorer thumbnail/icon cache'; G='Safe';     D='Rebuilt automatically by Windows';                  P=@("$L\Microsoft\Windows\Explorer") },
  @{ N='DirectX shader cache';          G='Safe';     D='Game/app shader cache, rebuilt when needed';        P=@("$L\D3DSCache") },
  @{ N='NVIDIA shader cache';           G='Safe';     D='GPU shader cache, rebuilt when needed';             P=@("$L\NVIDIA\DXCache","$L\NVIDIA\GLCache") },
  @{ N='Chrome cache';                  G='Safe';     D='Web page cache (close Chrome first)';               P=@("$CH\*\Cache","$CH\*\Code Cache","$CH\*\GPUCache") },
  @{ N='Edge cache';                    G='Safe';     D='Web page cache (close Edge first)';                 P=@("$ED\*\Cache","$ED\*\Code Cache","$ED\*\GPUCache") },
  @{ N='npm cache';                     G='Safe';     D='Package downloads, re-fetched when needed';         P=@("$L\npm-cache") },
  @{ N='pip cache';                     G='Safe';     D='Package downloads, re-fetched when needed';         P=@("$L\pip\Cache") },

  @{ N='Chrome on-device AI model';     G='Optional'; D='Chrome re-downloads it if it needs it again';       P=@("$CH\OptGuideOnDeviceModel") },
  @{ N='Unity cache';                   G='Optional'; D='Asset cache - first project open will be slower';   P=@("$L\Unity\cache","$L\Unity\Caches") },
  @{ N='uv (Python) cache';             G='Optional'; D='Python package downloads';                          P=@("$L\uv\cache") },
  @{ N='JetBrains caches and logs';     G='Optional'; D='IDE indexes - close IDEs first, they rebuild';      P=@("$L\JetBrains\*\caches","$L\JetBrains\*\log","$L\JetBrains\*\tmp") },
  @{ N='VS Code caches';                G='Optional'; D='Cached extension installers and crash reports';     P=@("$R\Code\CachedExtensionVSIXs","$R\Code\Crashpad","$R\Code\CachedData","$R\Code\Cache","$R\Code\Code Cache","$R\Code\GPUCache") },
  @{ N='Claude app cache';              G='Optional'; D='App cache, rebuilt automatically';                  P=@("$R\Claude\Cache","$R\Claude\Code Cache","$R\Claude\GPUCache") },
  @{ N='Puppeteer browser downloads';   G='Optional'; D='Test-browser builds, re-downloaded when used';      P=@("$U\.cache\puppeteer") },
  @{ N='Installer package cache';       G='Optional'; D='Some programs may ask for their installer to repair'; P=@("$PD\Package Cache") },
  @{ N='Recycle Bin';                   G='Optional'; D='PERMANENTLY deletes everything in it';              Recycle=$true }
)

function Format-Size($b) {
  if     ($b -ge 1GB) { '{0:N2} GB' -f ($b/1GB) }
  elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b/1MB) }
  elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b/1KB) }
  else                { '{0:N0} B'  -f $b }
}

function Get-Cutoff {
  if ($script:MinAgeHours -gt 0) { (Get-Date).AddHours(-$script:MinAgeHours) } else { $null }
}

function Get-Dirs($t) {
  foreach ($p in $t.P) { foreach ($d in (Get-Item -Path $p -Force)) { if ($d.PSIsContainer) { $d } } }
}

# Walks a folder WITHOUT following junctions/symlinks, so nothing outside the folder can ever be touched.
function Get-TreeSafe($root) {
  $files = New-Object System.Collections.Generic.List[object]
  $dirs  = New-Object System.Collections.Generic.List[string]
  $links = New-Object System.Collections.Generic.List[string]
  $stack = New-Object System.Collections.Stack
  $stack.Push($root)
  while ($stack.Count -gt 0) {
    $p = $stack.Pop()
    foreach ($e in (Get-ChildItem -LiteralPath $p -Force)) {
      if ($e.PSIsContainer) {
        if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { $links.Add($e.FullName) }
        else { $dirs.Add($e.FullName); $stack.Push($e.FullName) }
      } else { $files.Add($e) }
    }
  }
  [pscustomobject]@{ Files = $files; Dirs = $dirs; Links = $links }
}

function Measure-Target($t) {
  if ($t.Recycle) {
    $sum = 0; $cnt = 0
    foreach ($i in (New-Object -ComObject Shell.Application).NameSpace(10).Items()) { $sum += $i.Size; $cnt++ }
    return [pscustomobject]@{ Bytes = $sum; Files = $cnt }
  }
  $cut = Get-Cutoff
  $sum = 0; $cnt = 0
  foreach ($d in (Get-Dirs $t)) {
    foreach ($c in (Get-ChildItem -LiteralPath $d.FullName -Force)) {
      if ($t.X -contains $c.Name) { continue }
      if ($c.PSIsContainer) {
        if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        foreach ($f in (Get-TreeSafe $c.FullName).Files) {
          if (-not $cut -or $f.LastWriteTime -lt $cut) { $sum += $f.Length; $cnt++ }
        }
      } elseif (-not $cut -or $c.LastWriteTime -lt $cut) { $sum += $c.Length; $cnt++ }
    }
  }
  [pscustomobject]@{ Bytes = $sum; Files = $cnt }
}

function Remove-EmptyDir($path, $cut) {
  if ($cut -and [IO.Directory]::GetLastWriteTime($path) -ge $cut) { return }
  try { [IO.Directory]::Delete($path) } catch { }     # non-recursive: only succeeds if the folder is empty
}

function Clear-Target($t) {
  if ($t.Recycle) { Clear-RecycleBin -Force -Confirm:$false; return }
  $cut = Get-Cutoff
  foreach ($d in (Get-Dirs $t)) {
    foreach ($c in (Get-ChildItem -LiteralPath $d.FullName -Force)) {
      if ($t.X -contains $c.Name) { continue }
      if ($c.PSIsContainer) {
        if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) {
          if (-not $cut) { try { [IO.Directory]::Delete($c.FullName) } catch { } }   # removes the link only
          continue
        }
        $tree = Get-TreeSafe $c.FullName
        if (-not $cut) { foreach ($l in $tree.Links) { try { [IO.Directory]::Delete($l) } catch { } } }
        foreach ($f in $tree.Files) {
          if (-not $cut -or $f.LastWriteTime -lt $cut) { Remove-Item -LiteralPath $f.FullName -Force }
        }
        foreach ($sub in ($tree.Dirs | Sort-Object { $_.Length } -Descending)) { Remove-EmptyDir $sub $cut }
        Remove-EmptyDir $c.FullName $cut
      } elseif (-not $cut -or $c.LastWriteTime -lt $cut) {
        Remove-Item -LiteralPath $c.FullName -Force
      }
    }
  }
}

function Get-RunningApps {
  $names = 'chrome','msedge','idea64','phpstorm64','pycharm64','Code','Unity','UnityHub'
  ($names | ForEach-Object { Get-Process -Name $_ } | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$ageNote = if ($script:MinAgeHours -gt 0) { "Files changed in the last $($script:MinAgeHours) h are skipped." } else { 'Safety filter OFF: files of any age are deleted.' }

# =====================================================================
# TEXT MODE
# =====================================================================
if ($Console -or $ScanOnly) {
  $d0 = Get-PSDrive $SysLetter
  Write-Host ""
  Write-Host ("CleanJunk {0}" -f $Version) -ForegroundColor Cyan
  Write-Host ("{0} free {1} of {2}   (admin: {3})" -f $SysDrive, (Format-Size $d0.Free), (Format-Size ($d0.Used+$d0.Free)), $isAdmin)
  Write-Host $ageNote
  if (-not $isAdmin) { Write-Host "Not running as admin - Windows folders may be skipped. Use CleanJunk-Text.bat." -ForegroundColor Yellow }
  Write-Host "Scanning, please wait..."

  $i = 0
  foreach ($t in $targets) {
    $i++
    $m = Measure-Target $t
    $t.Idx = $i; $t.Bytes = $m.Bytes; $t.Files = $m.Files
  }

  Write-Host ""
  Write-Host ("{0,3}  {1,-34} {2,10}  {3,8}  {4}" -f '#','Item','Size','Files','Type')
  Write-Host ('-' * 70)
  foreach ($t in $targets) {
    $color = if ($t.G -eq 'Safe') { 'Green' } else { 'Yellow' }
    Write-Host ("{0,3}  {1,-34} {2,10}  {3,8:N0}  {4}" -f $t.Idx, $t.N, (Format-Size $t.Bytes), $t.Files, $t.G) -ForegroundColor $color
  }
  $safeTotal = 0; $optTotal = 0
  foreach ($t in $targets) { if ($t.G -eq 'Safe') { $safeTotal += $t.Bytes } else { $optTotal += $t.Bytes } }
  Write-Host ('-' * 70)
  Write-Host ("Safe total: {0}    Optional total: {1}" -f (Format-Size $safeTotal), (Format-Size $optTotal))

  if ($ScanOnly) { Write-Host "`nScan only - nothing deleted."; return }

  Write-Host ""
  Write-Host "What do you want to clean?"
  Write-Host "  S = all Safe items"
  Write-Host "  A = everything (Safe + Optional, includes Recycle Bin)"
  Write-Host "  or numbers like 1,3,13   |   Q = quit"
  $ans = (Read-Host "Choice").Trim()
  if ($ans -eq '' -or $ans -match '^[Qq]$') { Write-Host "Nothing deleted."; return }

  if     ($ans -match '^[Ss]$') { $sel = $targets | Where-Object { $_.G -eq 'Safe' } }
  elseif ($ans -match '^[Aa]$') { $sel = $targets }
  else {
    $nums = $ans -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    $sel = $targets | Where-Object { $nums -contains $_.Idx }
  }
  if (-not $sel) { Write-Host "No valid selection. Nothing deleted."; return }

  Write-Host ""
  Write-Host "Will delete:" -ForegroundColor Cyan
  $sel | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.N, (Format-Size $_.Bytes)) }
  $run = Get-RunningApps
  if ($run) { Write-Host "Running now: $run - close them first so their cache files can be removed." -ForegroundColor Yellow }
  if ((Read-Host "Type YES to continue") -ne 'YES') { Write-Host "Cancelled. Nothing deleted."; return }

  Write-Host ""
  $totalFreed = 0
  foreach ($t in $sel) {
    Clear-Target $t
    $after = Measure-Target $t
    $freed = [Math]::Max(0, $t.Bytes - $after.Bytes)
    $totalFreed += $freed
    Write-Host ("{0,-34} freed {1,10}" -f $t.N, (Format-Size $freed))
  }
  $d1 = Get-PSDrive $SysLetter
  Write-Host ""
  Write-Host ("Done. Freed {0}.  {1} free now {2}" -f (Format-Size $totalFreed), $SysDrive, (Format-Size $d1.Free)) -ForegroundColor Green
  return
}

# =====================================================================
# WINDOW MODE (default)
# =====================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:loading = $true
$script:busy    = $false

$form = New-Object Windows.Forms.Form
$form.AutoScaleMode = 'None'
$form.Text = "CleanJunk $Version"
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Size = New-Object Drawing.Size(980, [Math]::Min(880, $wa.Height - 30))
$form.MinimumSize = New-Object Drawing.Size(820, 520)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 9.5)

# --- list (fill) - added first so docked edges are laid out before it
$lv = New-Object Windows.Forms.ListView
$lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true
$lv.HideSelection = $false; $lv.Dock = 'Fill'; $lv.ShowGroups = $true
$lv.Font = New-Object Drawing.Font('Segoe UI', 9.5)
[void]$lv.Columns.Add('Item', 240)
$c = $lv.Columns.Add('Size', 100);  $c.TextAlign = 'Right'
$c = $lv.Columns.Add('Files', 80);  $c.TextAlign = 'Right'
[void]$lv.Columns.Add('What it is', 480)
$gSafe = New-Object Windows.Forms.ListViewGroup('SAFE  -  always regenerates, no downside (ticked by default)')
$gOpt  = New-Object Windows.Forms.ListViewGroup('OPTIONAL  -  regenerates, but slower next launch or re-download')
[void]$lv.Groups.Add($gSafe); [void]$lv.Groups.Add($gOpt)
$form.Controls.Add($lv)

# --- header (top)
$top = New-Object Windows.Forms.Panel
$top.Size = New-Object Drawing.Size($form.ClientSize.Width, 92)
$top.Dock = 'Top'; $top.BackColor = [Drawing.Color]::FromArgb(30, 34, 44)
$lblTitle = New-Object Windows.Forms.Label
$lblTitle.Text = 'CleanJunk'; $lblTitle.ForeColor = [Drawing.Color]::White
$lblTitle.Font = New-Object Drawing.Font('Segoe UI Semibold', 16); $lblTitle.AutoSize = $true
$lblTitle.Location = New-Object Drawing.Point(16, 8)
$lblDrive = New-Object Windows.Forms.Label
$lblDrive.ForeColor = [Drawing.Color]::FromArgb(200, 205, 215); $lblDrive.AutoSize = $true
$lblDrive.Location = New-Object Drawing.Point(18, 46)
$pbDrive = New-Object Windows.Forms.ProgressBar
$pbDrive.Location = New-Object Drawing.Point(18, 70); $pbDrive.Size = New-Object Drawing.Size(($form.ClientSize.Width - 36), 10)
$pbDrive.Anchor = 'Top,Left,Right'
$lblAdmin = New-Object Windows.Forms.Label
$lblAdmin.AutoSize = $true; $lblAdmin.ForeColor = [Drawing.Color]::Orange
$lblAdmin.Anchor = 'Top,Right'; $lblAdmin.Location = New-Object Drawing.Point(($form.ClientSize.Width - 480), 16)
if (-not $isAdmin) { $lblAdmin.Text = 'Not admin: Windows folders will be skipped. Start with CleanJunk.bat' }
$top.Controls.AddRange(@($lblTitle, $lblDrive, $pbDrive, $lblAdmin))
$form.Controls.Add($top)

# --- bottom: buttons, selected total, progress, log
$bot = New-Object Windows.Forms.Panel
$bot.Size = New-Object Drawing.Size($form.ClientSize.Width, 200)
$bot.Dock = 'Bottom'
$mkBtn = {
  param($text, $x)
  $b = New-Object Windows.Forms.Button
  $b.Text = $text; $b.Location = New-Object Drawing.Point($x, 12); $b.Size = New-Object Drawing.Size(110, 32)
  $b.FlatStyle = 'System'; $b
}
$btnSafe = & $mkBtn 'Select Safe' 12
$btnAll  = & $mkBtn 'Select All'  128
$btnNone = & $mkBtn 'Select None' 244
$btnScan = & $mkBtn 'Re-scan'     360
$chkAge = New-Object Windows.Forms.CheckBox
$chkAge.Text = 'Skip files changed in the last 24 hours (recommended)'
$chkAge.AutoSize = $true; $chkAge.Location = New-Object Drawing.Point(486, 19)
$chkAge.Checked = ($script:MinAgeHours -gt 0)
$btnClean = New-Object Windows.Forms.Button
$btnClean.Text = 'Clean selected'; $btnClean.Size = New-Object Drawing.Size(200, 40)
$btnClean.Location = New-Object Drawing.Point(($form.ClientSize.Width - 214), 52); $btnClean.Anchor = 'Top,Right'
$btnClean.Font = New-Object Drawing.Font('Segoe UI Semibold', 11)
$btnClean.BackColor = [Drawing.Color]::FromArgb(0, 120, 90); $btnClean.ForeColor = [Drawing.Color]::White
$btnClean.FlatStyle = 'Flat'
$lblSel = New-Object Windows.Forms.Label
$lblSel.AutoSize = $true; $lblSel.Font = New-Object Drawing.Font('Segoe UI Semibold', 11)
$lblSel.Location = New-Object Drawing.Point(14, 58)
$lblStatus = New-Object Windows.Forms.Label
$lblStatus.AutoSize = $true; $lblStatus.ForeColor = [Drawing.Color]::DimGray
$lblStatus.Location = New-Object Drawing.Point(14, 84)
$pbWork = New-Object Windows.Forms.ProgressBar
$pbWork.Location = New-Object Drawing.Point(14, 110); $pbWork.Size = New-Object Drawing.Size(($form.ClientSize.Width - 28), 14)
$pbWork.Anchor = 'Top,Left,Right'
$log = New-Object Windows.Forms.TextBox
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'
$log.Font = New-Object Drawing.Font('Consolas', 9.5)
$log.Location = New-Object Drawing.Point(14, 134); $log.Size = New-Object Drawing.Size(($form.ClientSize.Width - 28), 58)
$log.Anchor = 'Top,Bottom,Left,Right'
$bot.Controls.AddRange(@($btnSafe, $btnAll, $btnNone, $btnScan, $chkAge, $btnClean, $lblSel, $lblStatus, $pbWork, $log))
$form.Controls.Add($bot)

# --- rows
foreach ($t in $targets) {
  $it = New-Object Windows.Forms.ListViewItem($t.N)
  [void]$it.SubItems.Add('...'); [void]$it.SubItems.Add('...'); [void]$it.SubItems.Add($t.D)
  if ($t.G -eq 'Safe') { $it.Group = $gSafe; $it.Checked = $true;  $it.ForeColor = [Drawing.Color]::FromArgb(20, 110, 60) }
  else                 { $it.Group = $gOpt;  $it.Checked = $false; $it.ForeColor = [Drawing.Color]::FromArgb(160, 100, 0) }
  if ($t.Recycle)      { $it.ForeColor = [Drawing.Color]::Firebrick }
  [void]$lv.Items.Add($it)
  $t.Item = $it
}
$script:loading = $false

function Update-Drive {
  $d = Get-PSDrive $SysLetter
  $total = $d.Used + $d.Free
  $lblDrive.Text = ('{0}   {1} free of {2}   ({3:N0}% used)' -f $SysDrive, (Format-Size $d.Free), (Format-Size $total), (100 * $d.Used / $total))
  $pbDrive.Value = [Math]::Min(100, [int](100 * $d.Used / $total))
}

function Update-Selected {
  $n = 0; $sum = 0
  foreach ($t in $targets) { if ($t.Item.Checked) { $n++; $sum += $t.Bytes } }
  $lblSel.Text = ('Selected: {0} item(s)  -  {1} will be freed' -f $n, (Format-Size $sum))
  $btnClean.Enabled = ($n -gt 0 -and -not $script:busy)
}

function Set-Busy($on) {
  $script:busy = $on
  foreach ($b in @($btnSafe, $btnAll, $btnNone, $btnScan)) { $b.Enabled = -not $on }
  $lv.Enabled = -not $on
  $chkAge.Enabled = -not $on
  $btnClean.Enabled = (-not $on)
  if (-not $on) { Update-Selected }
}

function Set-Row($t) {
  $t.Item.SubItems[1].Text = Format-Size $t.Bytes
  $t.Item.SubItems[2].Text = '{0:N0}' -f $t.Files
  if ($t.Bytes -eq 0) { $t.Item.ForeColor = [Drawing.Color]::Gray }
}

function Invoke-Scan {
  Set-Busy $true
  $pbWork.Maximum = $targets.Count; $pbWork.Value = 0
  foreach ($t in $targets) {
    $lblStatus.Text = "Scanning: $($t.N) ..."
    [Windows.Forms.Application]::DoEvents()
    $m = Measure-Target $t
    $t.Bytes = $m.Bytes; $t.Files = $m.Files
    Set-Row $t
    $pbWork.Value++
  }
  $lblStatus.Text = 'Scan finished. Tick what you want to remove, then press Clean selected.'
  $pbWork.Value = 0
  Update-Drive
  Set-Busy $false
}

function Set-AllChecked($pred) {
  $script:loading = $true
  foreach ($t in $targets) { $t.Item.Checked = [bool](& $pred $t) }
  $script:loading = $false
  Update-Selected
}

$lv.Add_ItemChecked({ if (-not $script:loading) { Update-Selected } })
$btnSafe.Add_Click({ Set-AllChecked { param($t) $t.G -eq 'Safe' } })
$btnAll.Add_Click({  Set-AllChecked { param($t) $true } })
$btnNone.Add_Click({ Set-AllChecked { param($t) $false } })
$btnScan.Add_Click({ Invoke-Scan })
$chkAge.Add_CheckedChanged({
  if ($script:busy) { return }
  $script:MinAgeHours = if ($chkAge.Checked) { 24 } else { 0 }
  Invoke-Scan
})

$btnClean.Add_Click({
  $sel = @($targets | Where-Object { $_.Item.Checked })
  if ($sel.Count -eq 0) { return }
  $sum = 0; $names = ($sel | ForEach-Object { $sum += $_.Bytes; '  - {0}  ({1})' -f $_.N, (Format-Size $_.Bytes) }) -join "`n"
  $msg = "Delete these items?`n`n$names`n`nTotal: $(Format-Size $sum)`n"
  if ($script:MinAgeHours -gt 0) { $msg += "`nFiles changed in the last $($script:MinAgeHours) hours are skipped." }
  else { $msg += "`nSafety filter is OFF: files of any age will be deleted." }
  $run = Get-RunningApps
  if ($run) { $msg += "`n`nRunning now: $run`nClose them first so their cache files can be removed." }
  else      { $msg += "`n`nTip: close Chrome, Edge, IDEs and games first." }
  if ((@($sel | Where-Object { $_.Recycle }).Count) -gt 0) { $msg += "`n`nWARNING: the Recycle Bin is emptied PERMANENTLY." }
  $r = [Windows.Forms.MessageBox]::Show($msg, 'Confirm cleaning', 'YesNo', 'Warning')
  if ($r -ne 'Yes') { return }

  Set-Busy $true
  $pbWork.Maximum = $sel.Count; $pbWork.Value = 0
  $log.AppendText("--- Cleaning started $(Get-Date -Format 'HH:mm:ss') ---`r`n")
  $total = 0
  foreach ($t in $sel) {
    $lblStatus.Text = "Cleaning: $($t.N) ..."
    [Windows.Forms.Application]::DoEvents()
    Clear-Target $t
    $after = Measure-Target $t
    $freed = [Math]::Max(0, $t.Bytes - $after.Bytes)
    $total += $freed
    $t.Bytes = $after.Bytes; $t.Files = $after.Files
    Set-Row $t
    $log.AppendText(('{0,-32} freed {1,10}' -f $t.N, (Format-Size $freed)) + "`r`n")
    $pbWork.Value++
  }
  Update-Drive
  $d = Get-PSDrive $SysLetter
  $log.AppendText("DONE. Freed $(Format-Size $total).  $SysDrive free now $(Format-Size $d.Free)`r`n")
  $lblStatus.Text = "Done. Freed $(Format-Size $total)."
  Set-Busy $false
})

$form.Add_Shown({
  Update-Drive
  Invoke-Scan
  if ($SelfTest) {
    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save($SelfTest); $bmp.Dispose()
    $form.Close()
  }
})

[void]$form.ShowDialog()
