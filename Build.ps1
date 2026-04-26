#Requires -Version 5.1
<#
.SYNOPSIS
    Builds RemoteShellRunner.exe from RemoteTool.ps1 using PS2EXE.

.DESCRIPTION
    - Installs the PS2EXE module if it is not already present (CurrentUser scope).
    - Converts the source PNG logo into a multi-resolution Windows .ico file
      (16, 24, 32, 48, 64, 128, 256 - PNG-encoded, Vista+ ICO format).
    - Compiles RemoteTool.ps1 into a windowed (no-console) STA EXE with the
      icon and version metadata baked in.
    - All output (icon + EXE) is written next to this Build.ps1 / RemoteTool.ps1.

.PARAMETER LogoPng
    Path to the source PNG used to produce the .ico. Defaults to
    .\assets\RemoteShellRunner-logo.png next to this script. Override only
    if you keep the source logo somewhere else.

.PARAMETER Version
    File-version (4-part) stamped into the EXE properties. Bump per release.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Build.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Build.ps1 -Version "1.1.0.0"
#>
param(
    [string]$LogoPng,
    [string]$Version = "1.0.0.0"
)

$ErrorActionPreference = 'Stop'

$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $here 'RemoteTool.ps1'
$icoPath    = Join-Path $here 'RemoteShellRunner.ico'
$exePath    = Join-Path $here 'RemoteShellRunner.exe'

if (-not $LogoPng) {
    $LogoPng = Join-Path $here 'assets\RemoteShellRunner-logo.png'
}

if (-not (Test-Path $scriptPath)) { throw "RemoteTool.ps1 not found next to Build.ps1: $scriptPath" }
if (-not (Test-Path $LogoPng))    { throw "Logo PNG not found: $LogoPng" }

# ---------------------------------------------------------------------------
#  PNG -> multi-resolution ICO
# ---------------------------------------------------------------------------
function Convert-PngToIco {
    param(
        [Parameter(Mandatory)][string]$PngPath,
        [Parameter(Mandatory)][string]$IcoPath,
        [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256)
    )

    Add-Type -AssemblyName System.Drawing

    $src = [System.Drawing.Image]::FromFile((Resolve-Path $PngPath).Path)
    $entries = New-Object System.Collections.ArrayList
    try {
        foreach ($size in $Sizes) {
            $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g   = [System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.DrawImage($src, 0, 0, $size, $size)
            $g.Dispose()

            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()

            [void]$entries.Add([pscustomobject]@{ Size = $size; Bytes = $ms.ToArray() })
            $ms.Dispose()
        }
    } finally {
        $src.Dispose()
    }

    # ICO directory layout: 6-byte header + 16 bytes per entry, then concatenated PNGs.
    $offset = 6 + ($entries.Count * 16)
    foreach ($e in $entries) {
        $e | Add-Member -NotePropertyName Offset -NotePropertyValue $offset
        $offset += $e.Bytes.Length
    }

    $fs = [System.IO.File]::Create($IcoPath)
    $bw = New-Object System.IO.BinaryWriter($fs)
    try {
        $bw.Write([uint16]0)               # reserved
        $bw.Write([uint16]1)               # type = ICO
        $bw.Write([uint16]$entries.Count)  # image count

        foreach ($e in $entries) {
            $w = if ($e.Size -ge 256) { 0 } else { [byte]$e.Size }   # 0 means 256 in ICO spec
            $h = if ($e.Size -ge 256) { 0 } else { [byte]$e.Size }
            $bw.Write([byte]$w)
            $bw.Write([byte]$h)
            $bw.Write([byte]0)             # color count (0 = no palette / true color)
            $bw.Write([byte]0)             # reserved
            $bw.Write([uint16]1)           # planes
            $bw.Write([uint16]32)          # bpp
            $bw.Write([uint32]$e.Bytes.Length)
            $bw.Write([uint32]$e.Offset)
        }

        foreach ($e in $entries) { $bw.Write($e.Bytes) }
    } finally {
        $bw.Close()
        $fs.Close()
    }
}

# ---------------------------------------------------------------------------
#  1) Ensure PS2EXE is available
# ---------------------------------------------------------------------------
Write-Host "[1/3] Checking PS2EXE module..." -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "      Module not found. Installing 'ps2exe' for current user..." -ForegroundColor Yellow
    # Make sure NuGet provider + PSGallery are usable without interactive prompts.
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
    } catch { }
    try {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    } catch { }
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe -Force
$ps2exeVer = (Get-Module ps2exe).Version
Write-Host "      PS2EXE $ps2exeVer ready." -ForegroundColor Green

# ---------------------------------------------------------------------------
#  2) Build the icon
# ---------------------------------------------------------------------------
Write-Host "[2/3] Generating multi-resolution icon from PNG..." -ForegroundColor Cyan
Convert-PngToIco -PngPath $LogoPng -IcoPath $icoPath
Write-Host "      $icoPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
#  3) Compile the EXE
# ---------------------------------------------------------------------------
Write-Host "[3/3] Compiling EXE..." -ForegroundColor Cyan

# Stop a running instance (if any) so we can replace the file - otherwise the
# delete below fails with "Access to the path is denied" because the EXE is
# loaded into memory by the OS.
$exeBase = [System.IO.Path]::GetFileNameWithoutExtension($exePath)
Get-Process -Name $exeBase -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

# Remove a stale EXE so we know the build actually produced a fresh one.
if (Test-Path $exePath) { Remove-Item $exePath -Force }

Invoke-PS2EXE `
    -inputFile   $scriptPath `
    -outputFile  $exePath `
    -iconFile    $icoPath `
    -title       "Remote Shell Runner" `
    -description "Run PowerShell commands on multiple remote hosts" `
    -product     "Remote Shell Runner" `
    -version     $Version `
    -noConsole `
    -STA `
    -requireAdmin:$false

if (-not (Test-Path $exePath)) { throw "Build failed - EXE not produced." }

$sizeMB = [math]::Round((Get-Item $exePath).Length / 1MB, 2)
Write-Host ""
Write-Host "Build complete." -ForegroundColor Green
Write-Host "  EXE:     $exePath  ($sizeMB MB)"
Write-Host "  Icon:    $icoPath"
Write-Host "  Version: $Version"
