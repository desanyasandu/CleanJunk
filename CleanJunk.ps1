<#
.SYNOPSIS
  CleanJunk - find and remove temp files and regenerable caches on Windows 10/11.
.DESCRIPTION
  Default: opens a window where you tick what to clean. Nothing is deleted until you confirm.
  Never touches Downloads, Documents, Desktop, Docker/WSL disks, or app logins/settings.
  The "Big files" window only lists the largest files and folders; it never deletes anything.
.PARAMETER ScanOnly
  Text mode: list sizes, delete nothing.
.PARAMETER Console
  Text mode: scan, then pick what to clean by typing.
.PARAMETER BigFiles
  Text mode: list the largest files and folders on the system drive, delete nothing.
.PARAMETER MinAgeHours
  Only delete files not modified in the last N hours (default 24). Use 0 to delete everything.
#>
param(
  [switch]$ScanOnly,
  [switch]$Console,
  [switch]$BigFiles,
  [int]$MinAgeHours = 24,
  [string]$BigRoot,         # folder the big-files scan starts from (default: system drive)
  [string]$SelfTest,        # developer option: save a screenshot of the main window to this PNG and exit
  [string]$SelfTestBig      # developer option: scan big files, save a screenshot of that window and exit
)

$Version = '1.1.0'
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
if (-not $BigRoot) { $BigRoot = "$SysDrive\" }
$script:MinAgeHours = $MinAgeHours
$script:Pump = $null           # set by the window so long tasks keep it responsive
$script:BigProgress = $null

# G = Safe (always regenerates, no downside) | Optional (regenerates, but costs a re-download / slower launch)
# K = kind: (none) folder contents | Pattern | Dism | Docker | WinOld | Recycle
# X = top-level names inside a folder to skip,  D = description,  Unk = size can't be known in advance
$targets = @(
  @{ N='User temp files';               G='Safe';     D='Leftover files from apps and installers';           P=@($env:TEMP) },
  @{ N='Windows temp files';            G='Safe';     D='System temporary files';                            P=@("$Win\Temp") },
  @{ N='Windows Update download cache'; G='Safe';     D='Downloads of updates that are already installed';   P=@("$Win\SoftwareDistribution\Download") },
  @{ N='Delivery Optimization cache';   G='Safe';     D='Update pieces shared with other PCs (needs admin)'; P=@("$Win\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") },
  @{ N='Windows logs';                  G='Safe';     D='Old system log files';                              P=@("$Win\Logs") },
  @{ N='Crash dumps / error reports';   G='Safe';     D='Crash reports from apps and Windows';               P=@("$L\CrashDumps","$PD\Microsoft\Windows\WER","$L\Microsoft\Windows\WER","$Win\Minidump","$Win\LiveKernelReports") },
  @{ N='Explorer thumbnail/icon cache'; G='Safe';     D='Rebuilt automatically by Windows';                  P=@("$L\Microsoft\Windows\Explorer") },
  @{ N='DirectX shader cache';          G='Safe';     D='Game/app shader cache, rebuilt when needed';        P=@("$L\D3DSCache") },
  @{ N='NVIDIA shader cache';           G='Safe';     D='GPU shader cache, rebuilt when needed';             P=@("$L\NVIDIA\DXCache","$L\NVIDIA\GLCache") },
  @{ N='Chrome cache';                  G='Safe';     D='Web page cache (close Chrome first)';               P=@("$CH\*\Cache","$CH\*\Code Cache","$CH\*\GPUCache") },
  @{ N='Edge cache';                    G='Safe';     D='Web page cache (close Edge first)';                 P=@("$ED\*\Cache","$ED\*\Code Cache","$ED\*\GPUCache") },
  @{ N='npm cache';                     G='Safe';     D='Package downloads, re-fetched when needed';         P=@("$L\npm-cache") },
  @{ N='pip cache';                     G='Safe';     D='Package downloads, re-fetched when needed';         P=@("$L\pip\Cache") },

  @{ N='Chrome on-device AI model';     G='Optional'; D='Chrome re-downloads it if it needs it again';       P=@("$CH\OptGuideOnDeviceModel") },
  @{ N='Unity cache';                   G='Optional'; D='Asset cache - first project open will be slower';   P=@("$L\Unity\cache","$L\Unity\Caches") },
  @{ N='Gradle caches';                 G='Optional'; D='Build dependencies - next build re-downloads them'; P=@("$U\.gradle\caches","$U\.gradle\daemon") },
  @{ N='NuGet / Yarn caches';           G='Optional'; D='Package downloads - re-fetched on next restore';    P=@("$U\.nuget\packages","$L\NuGet\v3-cache","$L\NuGet\plugins-cache","$L\Yarn\Cache") },
  @{ N='uv (Python) cache';             G='Optional'; D='Python package downloads';                          P=@("$L\uv\cache") },
  @{ N='JetBrains caches and logs';     G='Optional'; D='IDE indexes - close IDEs first, they rebuild';      P=@("$L\JetBrains\*\caches","$L\JetBrains\*\log","$L\JetBrains\*\tmp") },
  @{ N='VS Code caches';                G='Optional'; D='Cached extension installers and crash reports';     P=@("$R\Code\CachedExtensionVSIXs","$R\Code\Crashpad","$R\Code\CachedData","$R\Code\Cache","$R\Code\Code Cache","$R\Code\GPUCache") },
  @{ N='Claude app cache';              G='Optional'; D='App cache, rebuilt automatically';                  P=@("$R\Claude\Cache","$R\Claude\Code Cache","$R\Claude\GPUCache") },
  @{ N='Puppeteer browser downloads';   G='Optional'; D='Test-browser builds, re-downloaded when used';      P=@("$U\.cache\puppeteer") },
  @{ N='Installer package cache';       G='Optional'; D='Some programs may ask for their installer to repair'; P=@("$PD\Package Cache") },
  @{ N='Scattered .dmp / .etl files';   G='Optional'; D='Crash dumps and trace logs spread across AppData';   K='Pattern'; Roots=@($L, $R); Ext=@('.dmp','.etl') },
  @{ N='Windows component cleanup';     G='Optional'; D='Windows removes old update files itself (5-15 min)'; K='Dism'; Unk=$true },
  @{ N='Docker unused data';            G='Optional'; D='Stopped containers, dangling images, build cache';   K='Docker' },
  @{ N='Windows.old';                   G='Optional'; D='Previous Windows install - no going back after';     K='WinOld'; P=@("$SysDrive\Windows.old") },
  @{ N='Recycle Bin';                   G='Optional'; D='PERMANENTLY deletes everything in it';              K='Recycle' }
)

function Format-Size($b) {
  if     ($b -ge 1GB) { '{0:N2} GB' -f ($b/1GB) }
  elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b/1MB) }
  elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b/1KB) }
  else                { '{0:N0} B'  -f $b }
}

function Get-Free { ([IO.DriveInfo]::new("$SysDrive\")).AvailableFreeSpace }

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

# Files with the given extensions under the roots, never following junctions/symlinks.
function Get-PatternFiles($t) {
  $cut = Get-Cutoff
  $out = New-Object System.Collections.Generic.List[object]
  $stack = New-Object System.Collections.Stack
  foreach ($r in $t.Roots) { if ($r -and (Test-Path -LiteralPath $r)) { $stack.Push([IO.DirectoryInfo]$r) } }
  while ($stack.Count -gt 0) {
    $d = $stack.Pop()
    try { foreach ($s in $d.EnumerateDirectories()) { if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($s) } } } catch { }
    try {
      foreach ($f in $d.EnumerateFiles()) {
        if ($t.Ext -contains $f.Extension.ToLower() -and (-not $cut -or $f.LastWriteTime -lt $cut)) { $out.Add($f) }
      }
    } catch { }
  }
  return ,$out
}

function Get-DockerReclaimable {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $null }
  $lines = & docker system df --format '{{.Reclaimable}}' 2>$null
  if ($LASTEXITCODE -ne 0) { return -1 }
  $sum = 0.0
  foreach ($line in $lines) {
    if ($line -match '([\d\.]+)\s*([kKMGT]?B)') {
      $n = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
      $mul = switch ($Matches[2].ToUpper()) { 'KB' { 1KB } 'MB' { 1MB } 'GB' { 1GB } 'TB' { 1TB } default { 1 } }
      $sum += $n * $mul
    }
  }
  [long]$sum
}

# Runs a program hidden and waits, keeping the window responsive.
function Invoke-Waiting($exe, $argLine) {
  $p = Start-Process -FilePath $exe -ArgumentList $argLine -WindowStyle Hidden -PassThru
  if (-not $p) { return }
  while (-not $p.HasExited) { if ($script:Pump) { & $script:Pump }; Start-Sleep -Milliseconds 200 }
}

function Measure-Folders($t) {
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

function Clear-Folders($t) {
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

function Measure-Target($t) {
  $t.Note = $null
  switch ($t.K) {
    'Recycle' {
      $sum = 0; $cnt = 0
      foreach ($i in (New-Object -ComObject Shell.Application).NameSpace(10).Items()) { $sum += $i.Size; $cnt++ }
      return [pscustomobject]@{ Bytes = $sum; Files = $cnt }
    }
    'Pattern' {
      $fs = Get-PatternFiles $t
      $sum = 0; foreach ($f in $fs) { $sum += $f.Length }
      return [pscustomobject]@{ Bytes = $sum; Files = $fs.Count }
    }
    'Dism' {
      if (-not $isAdmin) { $t.Note = 'needs admin' }
      return [pscustomobject]@{ Bytes = 0; Files = 0 }
    }
    'Docker' {
      $r = Get-DockerReclaimable
      if ($null -eq $r) { $t.Note = 'Docker not installed'; $r = 0 }
      elseif ($r -lt 0) { $t.Note = 'start Docker Desktop to measure'; $r = 0 }
      return [pscustomobject]@{ Bytes = $r; Files = 0 }
    }
    'WinOld' {
      $saved = $script:MinAgeHours; $script:MinAgeHours = 0
      $m = Measure-Folders $t
      $script:MinAgeHours = $saved
      return $m
    }
    default { return (Measure-Folders $t) }
  }
}

function Clear-Target($t) {
  switch ($t.K) {
    'Recycle' { Clear-RecycleBin -Force -Confirm:$false }
    'Pattern' { foreach ($f in (Get-PatternFiles $t)) { try { $f.IsReadOnly = $false; $f.Delete() } catch { } } }
    'Dism'    { if ($isAdmin) { Invoke-Waiting 'dism.exe' '/Online /Cleanup-Image /StartComponentCleanup' } }
    'Docker'  {
      if ((Get-DockerReclaimable) -gt 0) { & docker system prune -f *> $null; & docker builder prune -f *> $null }
    }
    'WinOld'  {
      foreach ($d in (Get-Dirs $t)) {
        Invoke-Waiting 'takeown.exe' "/F `"$($d.FullName)`" /R /A /D Y"
        Invoke-Waiting 'icacls.exe' "`"$($d.FullName)`" /grant *S-1-5-32-544:F /T /C /Q"
      }
      $saved = $script:MinAgeHours; $script:MinAgeHours = 0
      Clear-Folders $t
      $script:MinAgeHours = $saved
      foreach ($d in (Get-Dirs $t)) { try { [IO.Directory]::Delete($d.FullName) } catch { } }
    }
    default   { Clear-Folders $t }
  }
}

# Cleans one item and returns bytes freed. Items whose size is unknown are measured by drive free space.
function Invoke-Clean($t) {
  $f0 = Get-Free
  Clear-Target $t
  $after = Measure-Target $t
  $freed = if ($t.Unk) { [Math]::Max(0, (Get-Free) - $f0) } else { [Math]::Max(0, $t.Bytes - $after.Bytes) }
  $t.Bytes = $after.Bytes; $t.Files = $after.Files
  $freed
}

function Get-SizeText($t) { if ($t.Unk) { 'unknown' } else { Format-Size $t.Bytes } }

function Get-CleanNotes($sel) {
  $n = @()
  if ($sel | Where-Object { $_.K -eq 'Dism' })    { $n += 'Windows component cleanup can take 5-15 minutes.' }
  if ($sel | Where-Object { $_.K -eq 'WinOld' })  { $n += 'Deleting Windows.old removes the option to go back to your previous Windows version.' }
  if ($sel | Where-Object { $_.K -eq 'Docker' })  { $n += 'Docker: removes stopped containers, unused networks, dangling images and build cache.' }
  if ($sel | Where-Object { $_.K -eq 'Recycle' }) { $n += 'WARNING: the Recycle Bin is emptied PERMANENTLY.' }
  $n
}

# Lists the biggest files and folders (folders up to 3 levels deep). Read-only.
function Invoke-BigScan($root, $minFile = 100MB) {
  $big  = New-Object System.Collections.Generic.List[object]
  $dirs = @{}
  $stack = New-Object System.Collections.Stack
  $stack.Push(@([IO.DirectoryInfo]$root, 0, [string[]]@()))
  $n = 0
  while ($stack.Count -gt 0) {
    $e = $stack.Pop(); $d = $e[0]; $depth = $e[1]; $keys = $e[2]
    if ($depth -ge 1 -and $depth -le 3) { $keys = $keys + $d.FullName }
    try {
      foreach ($f in $d.EnumerateFiles()) {
        $n++
        $len = $f.Length
        foreach ($k in $keys) { $dirs[$k] = $dirs[$k] + $len }
        if ($len -ge $minFile) { $big.Add($f) }
        if ($n % 5000 -eq 0 -and $script:BigProgress) { & $script:BigProgress $n $d.FullName }
      }
    } catch { }
    try {
      foreach ($s in $d.EnumerateDirectories()) {
        if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push(@($s, ($depth + 1), $keys)) }
      }
    } catch { }
  }
  [pscustomobject]@{
    Files   = @($big | Sort-Object Length -Descending | Select-Object -First 40)
    Folders = @($dirs.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 40)
    Count   = $n
  }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$ageNote = if ($script:MinAgeHours -gt 0) { "Files changed in the last $($script:MinAgeHours) h are skipped." } else { 'Safety filter OFF: files of any age are deleted.' }

function Get-RunningApps {
  $names = 'chrome','msedge','idea64','phpstorm64','pycharm64','studio64','Code','Unity','UnityHub'
  ($names | ForEach-Object { Get-Process -Name $_ } | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
}

# =====================================================================
# TEXT MODE - big files
# =====================================================================
if ($BigFiles) {
  Write-Host ("CleanJunk {0} - biggest files and folders in {1} (nothing is deleted)" -f $Version, $BigRoot) -ForegroundColor Cyan
  $script:BigProgress = { param($n, $p) Write-Host ("`rScanned {0:N0} files..." -f $n) -NoNewline }
  $res = Invoke-BigScan $BigRoot
  Write-Host ("`rScanned {0:N0} files.          " -f $res.Count)
  Write-Host "`nLargest files:" -ForegroundColor Yellow
  foreach ($f in ($res.Files | Select-Object -First 20)) { Write-Host ("{0,10}  {1}" -f (Format-Size $f.Length), $f.FullName) }
  Write-Host "`nLargest folders:" -ForegroundColor Yellow
  foreach ($d in ($res.Folders | Select-Object -First 20)) { Write-Host ("{0,10}  {1}" -f (Format-Size $d.Value), $d.Key) }
  return
}

# =====================================================================
# TEXT MODE - cleaner
# =====================================================================
if ($Console -or $ScanOnly) {
  Write-Host ""
  Write-Host ("CleanJunk {0}" -f $Version) -ForegroundColor Cyan
  $free0 = Get-Free
  Write-Host ("{0} free {1}   (admin: {2})" -f $SysDrive, (Format-Size $free0), $isAdmin)
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
  Write-Host ("{0,3}  {1,-32} {2,10}  {3,8}  {4}" -f '#','Item','Size','Files','Type')
  Write-Host ('-' * 78)
  foreach ($t in $targets) {
    $color = if ($t.G -eq 'Safe') { 'Green' } else { 'Yellow' }
    $note  = if ($t.Note) { "  ($($t.Note))" } else { '' }
    Write-Host ("{0,3}  {1,-32} {2,10}  {3,8:N0}  {4}{5}" -f $t.Idx, $t.N, (Get-SizeText $t), $t.Files, $t.G, $note) -ForegroundColor $color
  }
  $safeTotal = 0; $optTotal = 0
  foreach ($t in $targets) { if ($t.G -eq 'Safe') { $safeTotal += $t.Bytes } else { $optTotal += $t.Bytes } }
  Write-Host ('-' * 78)
  Write-Host ("Safe total: {0}    Optional total: {1}" -f (Format-Size $safeTotal), (Format-Size $optTotal))

  if ($ScanOnly) { Write-Host "`nScan only - nothing deleted."; return }

  Write-Host ""
  Write-Host "What do you want to clean?"
  Write-Host "  S = all Safe items"
  Write-Host "  A = everything (Safe + Optional, includes Recycle Bin and Windows.old)"
  Write-Host "  or numbers like 1,3,13   |   Q = quit"
  $ans = (Read-Host "Choice").Trim()
  if ($ans -eq '' -or $ans -match '^[Qq]$') { Write-Host "Nothing deleted."; return }

  if     ($ans -match '^[Ss]$') { $sel = @($targets | Where-Object { $_.G -eq 'Safe' }) }
  elseif ($ans -match '^[Aa]$') { $sel = @($targets) }
  else {
    $nums = $ans -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    $sel = @($targets | Where-Object { $nums -contains $_.Idx })
  }
  if ($sel.Count -eq 0) { Write-Host "No valid selection. Nothing deleted."; return }

  Write-Host ""
  Write-Host "Will delete:" -ForegroundColor Cyan
  $sel | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.N, (Get-SizeText $_)) }
  foreach ($n in (Get-CleanNotes $sel)) { Write-Host $n -ForegroundColor Yellow }
  $run = Get-RunningApps
  if ($run) { Write-Host "Running now: $run - close them first so their cache files can be removed." -ForegroundColor Yellow }
  if ((Read-Host "Type YES to continue") -ne 'YES') { Write-Host "Cancelled. Nothing deleted."; return }

  Write-Host ""
  $totalFreed = 0
  foreach ($t in $sel) {
    Write-Host ("{0,-32} ..." -f $t.N) -NoNewline
    $freed = Invoke-Clean $t
    $totalFreed += $freed
    Write-Host ("`r{0,-32} freed {1,10}" -f $t.N, (Format-Size $freed))
  }
  Write-Host ""
  Write-Host ("Done. Freed {0}.  {1} free now {2}" -f (Format-Size $totalFreed), $SysDrive, (Format-Size (Get-Free))) -ForegroundColor Green
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
$script:Pump    = { [Windows.Forms.Application]::DoEvents() }

$form = New-Object Windows.Forms.Form
$form.AutoScaleMode = 'None'
$form.Text = "CleanJunk $Version"
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Size = New-Object Drawing.Size(980, [Math]::Min(900, $wa.Height - 30))
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
$pbDrive.Location = New-Object Drawing.Point(18, 72); $pbDrive.Size = New-Object Drawing.Size(($form.ClientSize.Width - 36), 10)
$pbDrive.Anchor = 'Top,Left,Right'
$lblAdmin = New-Object Windows.Forms.Label
$lblAdmin.AutoSize = $true; $lblAdmin.ForeColor = [Drawing.Color]::Orange
$lblAdmin.Anchor = 'Top,Right'; $lblAdmin.Location = New-Object Drawing.Point(($form.ClientSize.Width - 480), 12)
if (-not $isAdmin) { $lblAdmin.Text = 'Not admin: Windows folders will be skipped. Start with CleanJunk.bat' }
$btnBig = New-Object Windows.Forms.Button
$btnBig.Text = 'Find big files...'; $btnBig.Size = New-Object Drawing.Size(150, 28)
$btnBig.Location = New-Object Drawing.Point(($form.ClientSize.Width - 168), 38); $btnBig.Anchor = 'Top,Right'
$btnBig.FlatStyle = 'Flat'; $btnBig.ForeColor = [Drawing.Color]::White
$btnBig.BackColor = [Drawing.Color]::FromArgb(55, 62, 78)
$top.Controls.AddRange(@($lblTitle, $lblDrive, $pbDrive, $lblAdmin, $btnBig))
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
  if ($t.G -eq 'Safe') { $it.Group = $gSafe; $it.Checked = $true;  $t.Color = [Drawing.Color]::FromArgb(20, 110, 60) }
  else                 { $it.Group = $gOpt;  $it.Checked = $false; $t.Color = [Drawing.Color]::FromArgb(160, 100, 0) }
  if ($t.K -eq 'Recycle' -or $t.K -eq 'WinOld') { $t.Color = [Drawing.Color]::Firebrick }
  $it.ForeColor = $t.Color
  [void]$lv.Items.Add($it)
  $t.Item = $it
}
$script:loading = $false

function Update-Drive {
  $di = [IO.DriveInfo]::new("$SysDrive\")
  $total = $di.TotalSize; $free = $di.AvailableFreeSpace
  $lblDrive.Text = ('{0}   {1} free of {2}   ({3:N0}% used)' -f $SysDrive, (Format-Size $free), (Format-Size $total), (100 * ($total - $free) / $total))
  $pbDrive.Value = [Math]::Min(100, [int](100 * ($total - $free) / $total))
}

function Update-Selected {
  $n = 0; $sum = 0; $unk = $false
  foreach ($t in $targets) { if ($t.Item.Checked) { $n++; $sum += $t.Bytes; if ($t.Unk) { $unk = $true } } }
  $extra = if ($unk) { ' + Windows component cleanup' } else { '' }
  $lblSel.Text = ('Selected: {0} item(s)  -  {1}{2} will be freed' -f $n, (Format-Size $sum), $extra)
  $btnClean.Enabled = ($n -gt 0 -and -not $script:busy)
}

function Set-Busy($on) {
  $script:busy = $on
  foreach ($b in @($btnSafe, $btnAll, $btnNone, $btnScan, $btnBig)) { $b.Enabled = -not $on }
  $lv.Enabled = -not $on
  $chkAge.Enabled = -not $on
  $btnClean.Enabled = (-not $on)
  if (-not $on) { Update-Selected }
}

function Set-Row($t) {
  $t.Item.SubItems[1].Text = Get-SizeText $t
  $t.Item.SubItems[2].Text = if ($t.Unk -or $t.K -eq 'Docker') { '-' } else { '{0:N0}' -f $t.Files }
  $t.Item.SubItems[3].Text = if ($t.Note) { "$($t.D)   [$($t.Note)]" } else { $t.D }
  $t.Item.ForeColor = if ($t.Bytes -eq 0 -and -not $t.Unk) { [Drawing.Color]::Gray } else { $t.Color }
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
  $sum = 0; $names = ($sel | ForEach-Object { $sum += $_.Bytes; '  - {0}  ({1})' -f $_.N, (Get-SizeText $_) }) -join "`n"
  $msg = "Delete these items?`n`n$names`n`nTotal: $(Format-Size $sum)`n"
  if ($script:MinAgeHours -gt 0) { $msg += "`nFiles changed in the last $($script:MinAgeHours) hours are skipped." }
  else { $msg += "`nSafety filter is OFF: files of any age will be deleted." }
  $run = Get-RunningApps
  if ($run) { $msg += "`n`nRunning now: $run`nClose them first so their cache files can be removed." }
  else      { $msg += "`n`nTip: close Chrome, Edge, IDEs and games first." }
  $notes = Get-CleanNotes $sel
  if ($notes) { $msg += "`n`n" + ($notes -join "`n") }
  $r = [Windows.Forms.MessageBox]::Show($msg, 'Confirm cleaning', 'YesNo', 'Warning')
  if ($r -ne 'Yes') { return }

  Set-Busy $true
  $pbWork.Maximum = $sel.Count; $pbWork.Value = 0
  $log.AppendText("--- Cleaning started $(Get-Date -Format 'HH:mm:ss') ---`r`n")
  $total = 0
  foreach ($t in $sel) {
    $lblStatus.Text = "Cleaning: $($t.N) ..."
    [Windows.Forms.Application]::DoEvents()
    $freed = Invoke-Clean $t
    $total += $freed
    Set-Row $t
    $log.AppendText(('{0,-32} freed {1,10}' -f $t.N, (Format-Size $freed)) + "`r`n")
    $pbWork.Value++
  }
  Update-Drive
  $log.AppendText("DONE. Freed $(Format-Size $total).  $SysDrive free now $(Format-Size (Get-Free))`r`n")
  $lblStatus.Text = "Done. Freed $(Format-Size $total)."
  Set-Busy $false
})

# ---------------------------------------------------------------------
# Big files window (read-only: lists items, never deletes)
# ---------------------------------------------------------------------
$bf = New-Object Windows.Forms.Form
$bf.AutoScaleMode = 'None'
$bf.Text = "CleanJunk $Version - Big files"
$bf.Size = New-Object Drawing.Size(1000, [Math]::Min(760, $wa.Height - 30))
$bf.MinimumSize = New-Object Drawing.Size(760, 460)
$bf.StartPosition = 'CenterScreen'
$bf.Font = New-Object Drawing.Font('Segoe UI', 9.5)

$blv = New-Object Windows.Forms.ListView
$blv.View = 'Details'; $blv.FullRowSelect = $true; $blv.HideSelection = $false
$blv.Dock = 'Fill'; $blv.ShowGroups = $true; $blv.MultiSelect = $false
$c = $blv.Columns.Add('Size', 100); $c.TextAlign = 'Right'
[void]$blv.Columns.Add('Modified', 110)
[void]$blv.Columns.Add('Path', 740)
$gBigFiles   = New-Object Windows.Forms.ListViewGroup('LARGEST FILES  (100 MB and up)')
$gBigFolders = New-Object Windows.Forms.ListViewGroup('LARGEST FOLDERS  (up to 3 levels deep)')
[void]$blv.Groups.Add($gBigFiles); [void]$blv.Groups.Add($gBigFolders)
$bf.Controls.Add($blv)

$bfTop = New-Object Windows.Forms.Panel
$bfTop.Size = New-Object Drawing.Size($bf.ClientSize.Width, 70)
$bfTop.Dock = 'Top'; $bfTop.BackColor = [Drawing.Color]::FromArgb(30, 34, 44)
$lblBInfo = New-Object Windows.Forms.Label
$lblBInfo.Text = "Shows the biggest files and folders on $BigRoot so you can decide what to remove. Nothing is deleted here."
$lblBInfo.ForeColor = [Drawing.Color]::White; $lblBInfo.AutoSize = $true
$lblBInfo.Location = New-Object Drawing.Point(16, 12)
$lblB = New-Object Windows.Forms.Label
$lblB.ForeColor = [Drawing.Color]::FromArgb(200, 205, 215); $lblB.AutoSize = $true
$lblB.Location = New-Object Drawing.Point(16, 40)
$lblB.Text = 'Press "Scan drive". A full scan takes a few minutes (about 5 for 2 million files).'
$btnBScan = New-Object Windows.Forms.Button
$btnBScan.Text = 'Scan drive'; $btnBScan.Size = New-Object Drawing.Size(130, 32)
$btnBScan.Location = New-Object Drawing.Point(($bf.ClientSize.Width - 146), 19); $btnBScan.Anchor = 'Top,Right'
$btnBScan.FlatStyle = 'Flat'; $btnBScan.ForeColor = [Drawing.Color]::White
$btnBScan.BackColor = [Drawing.Color]::FromArgb(0, 120, 90)
$bfTop.Controls.AddRange(@($lblBInfo, $lblB, $btnBScan))
$bf.Controls.Add($bfTop)

$bfBot = New-Object Windows.Forms.Panel
$bfBot.Size = New-Object Drawing.Size($bf.ClientSize.Width, 52)
$bfBot.Dock = 'Bottom'
$btnBOpen = New-Object Windows.Forms.Button
$btnBOpen.Text = 'Open location'; $btnBOpen.Size = New-Object Drawing.Size(130, 32)
$btnBOpen.Location = New-Object Drawing.Point(12, 10); $btnBOpen.FlatStyle = 'System'
$btnBCopy = New-Object Windows.Forms.Button
$btnBCopy.Text = 'Copy path'; $btnBCopy.Size = New-Object Drawing.Size(110, 32)
$btnBCopy.Location = New-Object Drawing.Point(150, 10); $btnBCopy.FlatStyle = 'System'
$lblBHint = New-Object Windows.Forms.Label
$lblBHint.AutoSize = $true; $lblBHint.ForeColor = [Drawing.Color]::DimGray
$lblBHint.Location = New-Object Drawing.Point(276, 18)
$lblBHint.Text = 'Tip: games -> uninstall from Steam/Epic. Downloads/videos -> move to another drive or delete yourself.'
$bfBot.Controls.AddRange(@($btnBOpen, $btnBCopy, $lblBHint))
$bf.Controls.Add($bfBot)

function Invoke-BigScanUi {
  $btnBScan.Enabled = $false; $btnBOpen.Enabled = $false; $btnBCopy.Enabled = $false
  $blv.Items.Clear()
  $script:BigProgress = { param($n, $p)
    $lblB.Text = ('Scanning... {0:N0} files   {1}' -f $n, $p)
    [Windows.Forms.Application]::DoEvents()
  }
  $res = Invoke-BigScan $BigRoot
  $script:BigProgress = $null
  $blv.BeginUpdate()
  foreach ($f in $res.Files) {
    $it = New-Object Windows.Forms.ListViewItem((Format-Size $f.Length))
    [void]$it.SubItems.Add($f.LastWriteTime.ToString('yyyy-MM-dd')); [void]$it.SubItems.Add($f.FullName)
    $it.Tag = @{ Path = $f.FullName; File = $true }; $it.Group = $gBigFiles
    [void]$blv.Items.Add($it)
  }
  foreach ($d in $res.Folders) {
    $it = New-Object Windows.Forms.ListViewItem((Format-Size $d.Value))
    [void]$it.SubItems.Add(''); [void]$it.SubItems.Add($d.Key)
    $it.Tag = @{ Path = $d.Key; File = $false }; $it.Group = $gBigFolders
    [void]$blv.Items.Add($it)
  }
  $blv.EndUpdate()
  $lblB.Text = ('Scanned {0:N0} files. Select a row and press "Open location" to look at it.' -f $res.Count)
  $btnBScan.Enabled = $true; $btnBOpen.Enabled = $true; $btnBCopy.Enabled = $true
}

function Open-BigSelected {
  if ($blv.SelectedItems.Count -eq 0) { return }
  $tag = $blv.SelectedItems[0].Tag
  if ($tag.File) { Start-Process explorer.exe "/select,`"$($tag.Path)`"" } else { Start-Process explorer.exe "`"$($tag.Path)`"" }
}

$btnBScan.Add_Click({ Invoke-BigScanUi })
$btnBOpen.Add_Click({ Open-BigSelected })
$blv.Add_DoubleClick({ Open-BigSelected })
$btnBCopy.Add_Click({ if ($blv.SelectedItems.Count -gt 0) { [Windows.Forms.Clipboard]::SetText($blv.SelectedItems[0].Tag.Path) } })
$bf.Add_FormClosing({ param($s, $e) if ($s -eq $bf -and -not $SelfTestBig) { $e.Cancel = $true; $bf.Hide() } })
$btnBig.Add_Click({ [void]$bf.ShowDialog($form) })

$bf.Add_Shown({
  if ($SelfTestBig) {
    Invoke-BigScanUi
    $bmp = New-Object Drawing.Bitmap($bf.Width, $bf.Height)
    $bf.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $bf.Width, $bf.Height)))
    $bmp.Save($SelfTestBig); $bmp.Dispose()
    $bf.Close()
  }
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

if ($SelfTestBig) { [void]$bf.ShowDialog(); return }
[void]$form.ShowDialog()
