<#
.SYNOPSIS
  Even out the loudness of your FS25 radio music (Windows).

.DESCRIPTION
  OPTIONAL tool. The game never runs this. Run it yourself to normalize the
  volume of the .mp3 files in your FarmingSimulator2025\music folder so loud and
  quiet songs play at a consistent level.

  Method: ffmpeg two-pass EBU R128 loudnorm (linear gain — even loudness, no
  dynamic squashing). Originals are backed up first by default.

  ffmpeg not installed? This script downloads a portable static build into
  tools\bin\ (no admin needed) and verifies it against the provider's checksum.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File normalize_music.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File normalize_music.ps1 "C:\Users\you\Documents\My Games\FarmingSimulator2025\music" -Target -14
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File normalize_music.ps1 -Undo
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)] [string]$MusicDir = "",
    [double]$Target = -16,
    [switch]$NoBackup,
    [int]$Jobs = 2,            # reserved; processing is sequential on Windows
    [switch]$Undo,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BinDir    = Join-Path $ScriptDir "bin"
$StateDir  = Join-Path $ScriptDir ".state"
$WinUrl    = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"

function Info($m){ Write-Host $m }
function Ok($m){ Write-Host $m -ForegroundColor Green }
function Err($m){ Write-Host $m -ForegroundColor Red }

# Was the script launched with no arguments (e.g. right-click → Run with PowerShell)?
$Clicked = ($PSBoundParameters.Count -eq 0)
function Pause-IfClicked { if ($Clicked) { Read-Host "`nPress Enter to close" | Out-Null } }

function Show-Menu {
    Write-Host "Radio Shuffle - Music Audio Leveler"
    Write-Host ""
    Write-Host "  1) Dry run      (show each song's loudness, change nothing)"
    Write-Host "  2) Level audio  (normalize to $Target LUFS; originals backed up)"
    Write-Host "  3) Undo         (restore your original files)"
    Write-Host "  4) Quit"
    Write-Host ""
    $choice = Read-Host "Choose [1-4]"
    Write-Host ""
    switch ($choice) {
        "1" { $script:DryRun = $true }
        "2" { }
        "3" { $script:Undo = $true }
        default { Write-Host "Nothing to do. Bye."; Pause-IfClicked; exit 0 }
    }
}

# ── Locate the music folder ───────────────────────────────────────────────────
function Resolve-MusicDir {
    if ($MusicDir) {
        if (-not (Test-Path -LiteralPath $MusicDir -PathType Container)) { Err "Music folder not found: $MusicDir"; exit 1 }
        return (Resolve-Path -LiteralPath $MusicDir).Path
    }
    $d = $ScriptDir
    while ($d -and (Split-Path $d -Parent)) {
        if ((Test-Path (Join-Path $d "mods")) -and (Test-Path (Join-Path $d "music"))) {
            return (Join-Path $d "music")
        }
        $d = Split-Path $d -Parent
    }
    Err "Could not auto-detect your music folder. Pass it explicitly, e.g.:"
    Err '  ...normalize_music.ps1 "C:\Users\you\Documents\My Games\FarmingSimulator2025\music"'
    exit 1
}

# ── Ensure ffmpeg/ffprobe (download a portable build if missing) ──────────────
function Ensure-Ffmpeg {
    $ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue)
    $fp = (Get-Command ffprobe -ErrorAction SilentlyContinue)
    if ($ff -and $fp) { return @{ ffmpeg = $ff.Source; ffprobe = $fp.Source } }

    $localFf = Join-Path $BinDir "ffmpeg.exe"
    $localFp = Join-Path $BinDir "ffprobe.exe"
    if ((Test-Path $localFf) -and (Test-Path $localFp)) { return @{ ffmpeg = $localFf; ffprobe = $localFp } }

    Info "ffmpeg not found - downloading a portable build into tools\bin\ ..."
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ffdl_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp "ffmpeg.zip"
        # Resolve the redirect to the versioned package (HEAD, no body) so we can
        # fetch its co-located .sha256, then download the archive itself.
        $finalUrl = $WinUrl
        try {
            $head = Invoke-WebRequest -Uri $WinUrl -Method Head -MaximumRedirection 5 -UseBasicParsing
            if ($head.BaseResponse.ResponseUri) { $finalUrl = $head.BaseResponse.ResponseUri.AbsoluteUri }
        } catch { }
        Invoke-WebRequest -Uri $finalUrl -OutFile $zip -UseBasicParsing
        $want = (Invoke-WebRequest -Uri ($finalUrl + ".sha256") -UseBasicParsing).Content.Trim().Split()[0].ToLower()
        $have = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
        if ($want -ne $have) {
            Err "Checksum mismatch on downloaded ffmpeg (expected $want, got $have). Aborting."
            Err "Install ffmpeg yourself (winget install Gyan.FFmpeg) and re-run."
            exit 1
        }
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $exe = Get-ChildItem -Path $tmp -Recurse -Filter ffmpeg.exe | Select-Object -First 1
        $prb = Get-ChildItem -Path $tmp -Recurse -Filter ffprobe.exe | Select-Object -First 1
        New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
        Copy-Item $exe.FullName $localFf -Force
        Copy-Item $prb.FullName $localFp -Force
        Ok "Portable ffmpeg ready in tools\bin\"
        return @{ ffmpeg = $localFf; ffprobe = $localFp }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

# ── State (skip already-leveled files) ────────────────────────────────────────
function State-Key($path){
    $md5 = [Security.Cryptography.MD5]::Create()
    ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($path)) | ForEach-Object { $_.ToString("x2") }) -join ""
}
function Is-Done($file){
    $m = Join-Path $StateDir (State-Key $file)
    if (-not (Test-Path $m)) { return $false }
    $fi = Get-Item -LiteralPath $file
    return (Get-Content -LiteralPath $m -Raw).Trim() -eq ("{0}:{1}" -f $fi.Length, $fi.LastWriteTimeUtc.Ticks)
}
function Mark-Done($file){
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $fi = Get-Item -LiteralPath $file
    Set-Content -LiteralPath (Join-Path $StateDir (State-Key $file)) -Value ("{0}:{1}" -f $fi.Length, $fi.LastWriteTimeUtc.Ticks) -NoNewline
}

# ── Normalize one file (two-pass loudnorm) ────────────────────────────────────
function Normalize-One($file, $FF, $rel){
    if (Is-Done $file) { Info "skip (done)  $rel"; return }

    $p1 = & $FF -hide_banner -nostats -i $file -af "loudnorm=I=$Target`:TP=-1.5:LRA=11:print_format=json" -f null - 2>&1
    $txt = ($p1 -join "`n")
    $jstart = $txt.IndexOf("{"); $jend = $txt.LastIndexOf("}")
    if ($jstart -lt 0 -or $jend -lt 0) { Err "measure failed  $rel (skipping)"; return }
    $m = $txt.Substring($jstart, $jend - $jstart + 1) | ConvertFrom-Json

    if ($DryRun) { Info ("would level  {0}   (in {1} LUFS -> {2})" -f $rel, $m.input_i, $Target); return }

    if (-not $NoBackup) {
        $bdest = Join-Path $script:BackupDir $rel
        New-Item -ItemType Directory -Path (Split-Path $bdest -Parent) -Force | Out-Null
        if (-not (Test-Path $bdest)) { Copy-Item -LiteralPath $file -Destination $bdest }
    }

    # Temp file does NOT end in .mp3, so an interrupted run can't leave a stray
    # song in \music; it's renamed over the original on success.
    $tmp = "$file.partial"
    $af = "loudnorm=I=$Target`:TP=-1.5:LRA=11:measured_I=$($m.input_i):measured_TP=$($m.input_tp):measured_LRA=$($m.input_lra):measured_thresh=$($m.input_thresh):offset=$($m.target_offset):linear=true"
    & $FF -hide_banner -nostats -y -i $file -af $af -c:a libmp3lame -q:a 2 -map_metadata 0 -f mp3 $tmp *> $null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $tmp)) {
        Move-Item -LiteralPath $tmp -Destination $file -Force
        Mark-Done $file
        Ok "leveled      $rel"
    } else {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        Err "encode failed $rel"
    }
}

# ── Undo ──────────────────────────────────────────────────────────────────────
function Do-Undo {
    if (-not (Test-Path $script:BackupDir)) { Err "No backup folder at $($script:BackupDir)"; exit 1 }
    Info "Restoring originals from $($script:BackupDir) ..."
    Get-ChildItem -Path $script:BackupDir -Recurse -Filter *.mp3 | ForEach-Object {
        $rel = $_.FullName.Substring($script:BackupDir.Length).TrimStart('\','/')
        $dest = Join-Path $script:MusicDir $rel
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
        Info "restored $rel"
    }
    Remove-Item -Recurse -Force $StateDir -ErrorAction SilentlyContinue
    Ok "Undo complete."
}

# ── Main ──────────────────────────────────────────────────────────────────────
if ($Clicked) { Show-Menu }

$script:MusicDir  = Resolve-MusicDir
$script:BackupDir = Join-Path (Split-Path $script:MusicDir -Parent) "music_backup"

Info "Music folder : $($script:MusicDir)"
Info "Target       : $Target LUFS"
Info ("Backups      : " + ($(if ($NoBackup) {"off"} else {"on -> $($script:BackupDir)"})))
if ($DryRun) { Info "(dry run - no files will be changed)" }
Info ""

if ($Undo) { Do-Undo; Pause-IfClicked; exit 0 }

$ff = Ensure-Ffmpeg
$FF = $ff.ffmpeg
Info "ffmpeg       : $FF"
Info ""

# Remove any stray temp files from a previously interrupted run
Get-ChildItem -Path $script:MusicDir -Recurse -Filter *.partial -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

$files = Get-ChildItem -Path $script:MusicDir -Recurse -Filter *.mp3 | Sort-Object FullName
Info ("Found {0} mp3 files. Processing ..." -f $files.Count)
Info ""

foreach ($f in $files) {
    $rel = $f.FullName.Substring($script:MusicDir.Length).TrimStart('\','/')
    try { Normalize-One $f.FullName $FF $rel } catch { Err "error on $rel : $_" }
}

Info ""
Ok ("Done. {0} files considered. Backups in: {1}" -f $files.Count, $(if ($NoBackup) {"(disabled)"} else {$script:BackupDir}))
if (-not $DryRun) { Info "Reload your FS25 save to hear the leveled audio." }
Pause-IfClicked
