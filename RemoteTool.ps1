Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
[System.Windows.Forms.Application]::EnableVisualStyles()
# SetCompatibleTextRenderingDefault must be called before any WinForms window
# is created in the process. If WinForms was already touched in this session
# (e.g. the tool was run before in the same terminal), the call throws -
# harmless, so we swallow it silently.
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }

# Tool metadata - bump $script:appVersion when releasing a new build.
$script:appVersion    = "1.0"
$script:appAuthor     = "Sujin Nelladath"
$script:appAuthorRole = "Microsoft MVP"
$script:appLinkedIn   = "https://www.linkedin.com/in/sujin-nelladath-8911968a/"

# Load the application icon - prefers the icon embedded in the running EXE
# (PS2EXE-compiled), falls back to a sibling RemoteShellRunner.ico when the
# script is launched as a plain .ps1.
$script:appIcon   = $null
$script:appBitmap = $null
try {
    $procPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $isHostedInPwsh = ($procPath -match '(?i)\\(powershell|pwsh|powershell_ise)\.exe$')
    if ($procPath -and -not $isHostedInPwsh) {
        $script:appIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($procPath)
    } elseif ($PSScriptRoot) {
        $icoSibling = Join-Path $PSScriptRoot 'RemoteShellRunner.ico'
        if (Test-Path $icoSibling) {
            $script:appIcon = New-Object System.Drawing.Icon($icoSibling)
        }
    }
    if ($script:appIcon) { $script:appBitmap = $script:appIcon.ToBitmap() }
} catch { }

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32Cue {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, int wParam, string lParam);
    public static void SetCue(IntPtr handle, string text) {
        SendMessage(handle, 0x1501, 1, text);
    }
}
"@

# ============================================================================
#  COLOURS  (soft professional palette, inspired by the reference tool)
# ============================================================================
$clrFormBg    = [System.Drawing.Color]::FromArgb(244, 247, 252)   # light gray-blue page bg
$clrCard      = [System.Drawing.Color]::White                     # group/card bg
$clrBand      = [System.Drawing.Color]::FromArgb(222, 234, 252)   # soft blue banner
$clrBandEdge  = [System.Drawing.Color]::FromArgb(180, 200, 230)
$clrBorder    = [System.Drawing.Color]::FromArgb(210, 220, 235)
$clrAccent    = [System.Drawing.Color]::FromArgb(45, 115, 220)
$clrAccentHot = [System.Drawing.Color]::FromArgb(30, 95, 195)
$clrAccentDn  = [System.Drawing.Color]::FromArgb(20, 80, 175)
$clrSuccess   = [System.Drawing.Color]::FromArgb(40, 160, 80)
$clrError     = [System.Drawing.Color]::FromArgb(200, 50, 50)
$clrText      = [System.Drawing.Color]::FromArgb(30, 34, 45)
$clrTextSoft  = [System.Drawing.Color]::FromArgb(90, 100, 115)
$clrInputBg   = [System.Drawing.Color]::White
$clrTermBg    = [System.Drawing.Color]::Black
$clrOutText   = [System.Drawing.Color]::FromArgb(235, 235, 240)
$clrMutedLog  = [System.Drawing.Color]::FromArgb(150, 160, 180)
$clrWhite     = [System.Drawing.Color]::White
$clrExit      = [System.Drawing.Color]::FromArgb(210, 55, 55)
$clrExitHot   = [System.Drawing.Color]::FromArgb(190, 40, 40)
$clrStop      = [System.Drawing.Color]::FromArgb(230, 130, 30)
$clrStopHot   = [System.Drawing.Color]::FromArgb(205, 110, 20)
$clrDisabled  = [System.Drawing.Color]::FromArgb(200, 205, 215)

# ============================================================================
#  FONTS
# ============================================================================
$fntTitle   = New-Object System.Drawing.Font("Segoe UI", 12.5, [System.Drawing.FontStyle]::Bold)
$fntDev     = New-Object System.Drawing.Font("Segoe UI", 9)
$fntDevBold = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$fntGroup   = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$fntHint    = New-Object System.Drawing.Font("Segoe UI", 8.5)
$fntInput   = New-Object System.Drawing.Font("Segoe UI", 10)
$fntBtn     = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5)
$fntMono    = New-Object System.Drawing.Font("Consolas", 10)
$fntOut     = New-Object System.Drawing.Font("Consolas", 10)
$fntStatus  = New-Object System.Drawing.Font("Segoe UI Semibold", 9)

$results     = @{}
$script:cred = $null

# ============================================================================
#  CREDENTIAL VALIDATION
# ============================================================================
function Test-RemoteToolCredential {
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$PlainPassword
    )
    $ctxType = [System.DirectoryServices.AccountManagement.ContextType]
    $pc = $null
    $logonName = $UserName

    try {
        if ($UserName -match '^(?<dom>[^\\]+)\\(?<user>.+)$') {
            $dom = $Matches['dom']
            $sam = $Matches['user']
            if ($dom -eq '.' -or $dom -ieq 'BUILTIN' -or $dom -ieq $env:COMPUTERNAME) {
                $pc = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                    $ctxType::Machine, $env:COMPUTERNAME)
                $logonName = $sam
            } else {
                $pc = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                    $ctxType::Domain, $dom)
                $logonName = $sam
            }
        } elseif ($UserName.Contains('@')) {
            $dnsDomain = ($UserName -split '@', 2)[1]
            $pc = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                $ctxType::Domain, $dnsDomain)
        } elseif ($env:USERDOMAIN -and ($env:USERDOMAIN -ne $env:COMPUTERNAME)) {
            $pc = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                $ctxType::Domain, $env:USERDOMAIN)
            $logonName = $UserName
        } else {
            $pc = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                $ctxType::Machine, $env:COMPUTERNAME)
            $logonName = $UserName
        }
        $valid = $pc.ValidateCredentials($logonName, $PlainPassword)
        return @{ Ok = [bool]$valid; Message = $null }
    } catch {
        return @{ Ok = $false; Message = $_.Exception.Message }
    } finally {
        if ($null -ne $pc) { $pc.Dispose() }
    }
}

# ============================================================================
#  UI HELPERS
# ============================================================================
function New-Label($text, $font, $color, $align="MiddleLeft") {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Font = $font; $l.ForeColor = $color
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.TextAlign = $align; $l.AutoSize = $false
    $l.Margin = New-Object System.Windows.Forms.Padding(0)
    $l
}
function New-Hint($text) { New-Label $text $fntHint $clrTextSoft }

function New-Textbox {
    param([bool]$Multiline=$false, [bool]$Password=$false)
    $t = New-Object System.Windows.Forms.TextBox
    $t.BackColor   = $clrInputBg
    $t.ForeColor   = $clrText
    $t.BorderStyle = "FixedSingle"
    $t.Margin      = New-Object System.Windows.Forms.Padding(0)
    if ($Multiline) {
        $t.Multiline     = $true
        $t.ScrollBars    = "Vertical"
        $t.Font          = $fntMono
        $t.AcceptsReturn = $true
        $t.AcceptsTab    = $true
        $t.WordWrap      = $false
    } else {
        $t.Font = $fntInput
    }
    if ($Password) { $t.UseSystemPasswordChar = $true }
    $t
}

function Style-PrimaryButton($b) {
    $b.BackColor = $clrAccent
    $b.ForeColor = $clrWhite
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $clrAccentHot
    $b.FlatAppearance.MouseDownBackColor = $clrAccentDn
}
function Style-DangerButton($b) {
    $b.BackColor = $clrExit
    $b.ForeColor = $clrWhite
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $clrExitHot
    $b.FlatAppearance.MouseDownBackColor = $clrExitHot
}
function Style-StopButton($b) {
    $b.BackColor = $clrStop
    $b.ForeColor = $clrWhite
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $clrStopHot
    $b.FlatAppearance.MouseDownBackColor = $clrStopHot
}

function New-Button($text, [bool]$primary=$true) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Font = $fntBtn; $b.Cursor = "Hand"; $b.FlatStyle = "Flat"
    $b.Margin = New-Object System.Windows.Forms.Padding(0)
    $b.Height = 30
    if ($primary) { Style-PrimaryButton $b } else { Style-DangerButton $b }
    $b
}

function New-Group($title) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text      = $title
    $g.Font      = $fntGroup
    $g.ForeColor = $clrAccent
    $g.BackColor = $clrCard
    $g.Padding   = New-Object System.Windows.Forms.Padding(10, 6, 10, 10)
    $g.Margin    = New-Object System.Windows.Forms.Padding(0)
    $g
}

# TableLayoutPanel with ordered row-height list (int = absolute px, double = %)
function New-Rows {
    param($parent, $rows, $bg = $null)
    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.Dock        = "Fill"
    if ($null -eq $bg) { $t.BackColor = [System.Drawing.Color]::Transparent } else { $t.BackColor = $bg }
    $t.ColumnCount = 1
    $t.RowCount    = $rows.Count
    $t.Margin      = New-Object System.Windows.Forms.Padding(0)
    [void]$t.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    foreach ($r in $rows) {
        if ($r -is [double] -or $r -is [float]) {
            [void]$t.RowStyles.Add(
                (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, [double]$r)))
        } else {
            [void]$t.RowStyles.Add(
                (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, [int]$r)))
        }
    }
    if ($parent) { $parent.Controls.Add($t) }
    $t
}

function Put($tbl, $ctrl, $row, [int]$col=0) {
    $tbl.Controls.Add($ctrl, $col, $row)
    $ctrl.Dock   = "Fill"
    $ctrl.Margin = New-Object System.Windows.Forms.Padding(0)
}

# ============================================================================
#  FORM
# ============================================================================
$form               = New-Object System.Windows.Forms.Form
$form.Text          = "Remote Shell Runner"
$form.Size          = New-Object System.Drawing.Size(1040, 720)
$form.MinimumSize   = New-Object System.Drawing.Size(900, 640)
$form.StartPosition = "CenterScreen"
$form.BackColor     = $clrFormBg
$form.ForeColor     = $clrText
$form.Font          = $fntInput
if ($script:appIcon) { $form.Icon = $script:appIcon }

# Root: header band / thin accent / body / status strip
$root = New-Rows $null @(60, 2, [double]100, 28) $clrFormBg
$form.Controls.Add($root)

# ----------------------------------------------------------------------------
#  HEADER BAND  (soft blue)
# ----------------------------------------------------------------------------
$header           = New-Object System.Windows.Forms.Panel
$header.BackColor = $clrBand
$header.Dock      = "Fill"
$header.Margin    = New-Object System.Windows.Forms.Padding(0)
Put $root $header 0

$lblTitle           = New-Object System.Windows.Forms.Label
$lblTitle.Text      = "Remote Shell Runner"
$lblTitle.Font      = $fntTitle
$lblTitle.ForeColor = $clrText
$lblTitle.AutoSize  = $true
$lblTitle.Location  = New-Object System.Drawing.Point(18, 9)

# Developer credit - split into TWO controls so only the name (bold, blue) is
# visually emphasised while "Developed by " stays as understated soft-gray text.
$lblDevPrefix              = New-Object System.Windows.Forms.Label
$lblDevPrefix.Text         = "Developed by "
$lblDevPrefix.Font         = $fntDev
$lblDevPrefix.ForeColor    = $clrTextSoft
$lblDevPrefix.AutoSize     = $true
$lblDevPrefix.Location     = New-Object System.Drawing.Point(20, 36)
$lblDevPrefix.BackColor    = [System.Drawing.Color]::Transparent
$lblDevPrefix.Margin       = New-Object System.Windows.Forms.Padding(0)

$lblDev                    = New-Object System.Windows.Forms.LinkLabel
$lblDev.Text               = "Sujin Nelladath"
$lblDev.Font               = $fntDevBold
$lblDev.AutoSize           = $true
$lblDev.BackColor          = [System.Drawing.Color]::Transparent
$lblDev.LinkArea           = New-Object System.Windows.Forms.LinkArea(0, 15)
$lblDev.LinkColor          = $clrAccent
$lblDev.ActiveLinkColor    = $clrAccentHot
$lblDev.VisitedLinkColor   = $clrAccent
$lblDev.LinkBehavior       = [System.Windows.Forms.LinkBehavior]::HoverUnderline
$lblDev.Cursor             = [System.Windows.Forms.Cursors]::Hand
$lblDev.Margin             = New-Object System.Windows.Forms.Padding(0)
$lblDev.Add_LinkClicked({
    try {
        Start-Process $script:appLinkedIn
        $lblDev.LinkVisited = $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message, "Could not open LinkedIn", "OK", "Error") | Out-Null
    }
})

# Place the name link flush to the right of the prefix using exact glyph
# measurement (TextRenderer is what WinForms uses to render Label text by
# default, so this matches the prefix's actual rendered width pixel-for-pixel).
$prefixWidth = [System.Windows.Forms.TextRenderer]::MeasureText(
    $lblDevPrefix.Text, $fntDev, [System.Drawing.Size]::Empty,
    [System.Windows.Forms.TextFormatFlags]::NoPadding).Width
$lblDev.Location = New-Object System.Drawing.Point((20 + $prefixWidth), 36)

$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Text      = "Not authenticated"
$lblStatus.Font      = $fntStatus
$lblStatus.ForeColor = $clrError
$lblStatus.AutoSize  = $true

# Help / Requirements link - mirrors the developer credit on the left side
# of the header band, right-aligned, same vertical position (y = 36). Bold so
# users notice it instantly when they open the tool.
$lnkHelp                  = New-Object System.Windows.Forms.LinkLabel
$lnkHelp.Text             = "Help"
$lnkHelp.Font             = $fntDevBold
$lnkHelp.AutoSize         = $true
$lnkHelp.LinkColor        = $clrAccent
$lnkHelp.ActiveLinkColor  = $clrAccentHot
$lnkHelp.VisitedLinkColor = $clrAccent
$lnkHelp.LinkBehavior     = [System.Windows.Forms.LinkBehavior]::HoverUnderline
$lnkHelp.Cursor           = [System.Windows.Forms.Cursors]::Hand
$lnkHelp.BackColor        = [System.Drawing.Color]::Transparent
$lnkHelp.Add_LinkClicked({ Show-RequirementsDialog })

$header.Controls.AddRange(@($lblTitle, $lblDevPrefix, $lblDev, $lblStatus, $lnkHelp))

$updateStatus = {
    $lblStatus.Location = New-Object System.Drawing.Point(
        ($header.ClientSize.Width - $lblStatus.Width - 18), 20)
    $lnkHelp.Location   = New-Object System.Drawing.Point(
        ($header.ClientSize.Width - $lnkHelp.Width   - 18), 36)
}
$header.Add_Resize($updateStatus)

# Thin accent line under band
$accent           = New-Object System.Windows.Forms.Panel
$accent.BackColor = $clrBandEdge
Put $root $accent 1

# ----------------------------------------------------------------------------
#  BODY  (left card column + right output card)
# ----------------------------------------------------------------------------
$body = New-Object System.Windows.Forms.TableLayoutPanel
$body.Dock        = "Fill"
$body.BackColor   = [System.Drawing.Color]::Transparent
$body.ColumnCount = 2
$body.RowCount    = 1
$body.Padding     = New-Object System.Windows.Forms.Padding(12, 10, 12, 10)
$body.Margin      = New-Object System.Windows.Forms.Padding(0)
[void]$body.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 42)))
[void]$body.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 58)))
[void]$body.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
Put $root $body 2

# ============================================================================
#  LEFT COLUMN  (Credentials / Target Hosts / Commands / Action buttons)
# ============================================================================
$leftCol = New-Rows $null @(140, 8, [double]40, 8, [double]60, 44) $clrFormBg
$leftCol.Dock = "Fill"
$leftCol.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
$body.Controls.Add($leftCol, 0, 0)

# --- Credentials group ------------------------------------------------------
$gCred = New-Group "AUTHENTICATION"
Put $leftCol $gCred 0

$credGrid = New-Object System.Windows.Forms.TableLayoutPanel
$credGrid.Dock = "Fill"
$credGrid.BackColor = [System.Drawing.Color]::Transparent
$credGrid.ColumnCount = 2
$credGrid.RowCount    = 4
$credGrid.Margin      = New-Object System.Windows.Forms.Padding(0)
[void]$credGrid.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$credGrid.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 140)))
foreach ($h in @(18, 28, 18, 28)) {
    [void]$credGrid.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $h)))
}
$gCred.Controls.Add($credGrid)

$credGrid.Controls.Add((New-Hint "Username"), 0, 0)
$txtUser = New-Textbox
$credGrid.Controls.Add($txtUser, 0, 1); $txtUser.Dock = "Fill"
$credGrid.Controls.Add((New-Hint "Password"), 0, 2)
$txtPass = New-Textbox -Multiline:$false -Password:$true
$credGrid.Controls.Add($txtPass, 0, 3); $txtPass.Dock = "Fill"

$btnAuth = New-Button "Connect" $true
$btnAuth.Margin   = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$btnAuth.AutoSize = $false
$btnAuth.Dock     = "None"
$btnAuth.Anchor   = ([System.Windows.Forms.AnchorStyles]::Top -bor
                     [System.Windows.Forms.AnchorStyles]::Left -bor
                     [System.Windows.Forms.AnchorStyles]::Right)
$credGrid.Controls.Add($btnAuth, 1, 3)

# --- Target hosts group -----------------------------------------------------
$gHosts = New-Group "TARGET HOSTS"
Put $leftCol $gHosts 2

$hostsGrid = New-Rows $gHosts @(16, [double]100)
$hostsGrid.Padding = New-Object System.Windows.Forms.Padding(0)
$hostsGrid.BackColor = [System.Drawing.Color]::Transparent
Put $hostsGrid (New-Hint "One hostname per line   |   Click a host after run to view its output") 0
$txtHosts = New-Textbox -Multiline:$true
Put $hostsGrid $txtHosts 1

# --- Commands group ---------------------------------------------------------
$gCmd = New-Group "COMMANDS"
Put $leftCol $gCmd 4

$cmdGrid = New-Rows $gCmd @(16, [double]100)
$cmdGrid.BackColor = [System.Drawing.Color]::Transparent
Put $cmdGrid (New-Hint "Full block runs as one script; variables persist") 0
$txtCmd = New-Textbox -Multiline:$true
Put $cmdGrid $txtCmd 1

# --- Action button bar (Run / Clear) ---------------------------------------
$btnBar = New-Object System.Windows.Forms.TableLayoutPanel
$btnBar.Dock = "Fill"
$btnBar.BackColor = [System.Drawing.Color]::Transparent
$btnBar.ColumnCount = 3
$btnBar.RowCount = 1
$btnBar.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
[void]$btnBar.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
[void]$btnBar.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
[void]$btnBar.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$btnBar.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$btnRun   = New-Button "Execute" $true
$btnClear = New-Button "Clear"   $true
$btnRun.Margin   = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
$btnClear.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
$btnBar.Controls.Add($btnRun,   0, 0); $btnRun.Dock   = "Fill"
$btnBar.Controls.Add($btnClear, 1, 0); $btnClear.Dock = "Fill"
Put $leftCol $btnBar 5

# ============================================================================
#  RIGHT COLUMN  (Output)
# ============================================================================
$gOut = New-Group "OUTPUT"
$gOut.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 8)
$gOut.Margin  = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
$body.Controls.Add($gOut, 1, 0); $gOut.Dock = "Fill"

$outGrid = New-Rows $gOut @(30, 18, [double]100)
$outGrid.BackColor = [System.Drawing.Color]::Transparent

# header row: live-output hint (grows) + Stop + Export + Exit
$outHead = New-Object System.Windows.Forms.TableLayoutPanel
$outHead.Dock = "Fill"
$outHead.BackColor = [System.Drawing.Color]::Transparent
$outHead.ColumnCount = 4
$outHead.RowCount = 1
$outHead.Margin = New-Object System.Windows.Forms.Padding(0)
[void]$outHead.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$outHead.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 88)))
[void]$outHead.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 100)))
[void]$outHead.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 88)))
[void]$outHead.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$lblLive = New-Label "Live command output for all target hosts" $fntHint $clrTextSoft
$outHead.Controls.Add($lblLive, 0, 0); $lblLive.Dock = "Fill"

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text   = "Stop"
$btnStop.Font   = $fntBtn
$btnStop.Cursor = "Hand"
$btnStop.FlatStyle = "Flat"
$btnStop.Height    = 30
$btnStop.Enabled   = $false
Style-StopButton $btnStop
$btnStop.Margin = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
$outHead.Controls.Add($btnStop, 1, 0); $btnStop.Dock = "Fill"

$btnExport = New-Button "Export..." $true
$btnExport.Margin = New-Object System.Windows.Forms.Padding(0, 2, 6, 2)
$outHead.Controls.Add($btnExport, 2, 0); $btnExport.Dock = "Fill"

$btnExit = New-Button "Exit" $false
$btnExit.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
$btnExit.Add_Click({ $form.Close() })
$outHead.Controls.Add($btnExit, 3, 0); $btnExit.Dock = "Fill"

Put $outGrid $outHead 0
# Row 1 is intentional spacer

$txtOut = New-Object System.Windows.Forms.RichTextBox
$txtOut.BackColor   = $clrTermBg
$txtOut.ForeColor   = $clrOutText
$txtOut.Font        = $fntOut
$txtOut.BorderStyle = "FixedSingle"
$txtOut.ReadOnly    = $true
$txtOut.ScrollBars  = "Vertical"
$txtOut.DetectUrls  = $false
Put $outGrid $txtOut 2

# ----------------------------------------------------------------------------
#  STATUS STRIP (bottom)
# ----------------------------------------------------------------------------
$statusStrip = New-Object System.Windows.Forms.Panel
$statusStrip.BackColor = $clrBand
Put $root $statusStrip 3

# Subtle top border so the strip is always visibly separated from the body
$statusTopEdge           = New-Object System.Windows.Forms.Panel
$statusTopEdge.Dock      = "Top"
$statusTopEdge.Height    = 1
$statusTopEdge.BackColor = $clrBandEdge
$statusStrip.Controls.Add($statusTopEdge)

$lblFooter           = New-Object System.Windows.Forms.Label
$lblFooter.AutoSize  = $true
$lblFooter.Font      = $fntHint
$lblFooter.ForeColor = $clrTextSoft
$lblFooter.Text      = "Ready"
$lblFooter.Location  = New-Object System.Drawing.Point(12, 7)

$lblClock           = New-Object System.Windows.Forms.Label
$lblClock.AutoSize  = $true
$lblClock.Font      = $fntHint
$lblClock.ForeColor = $clrTextSoft
$lblClock.Text      = (Get-Date -Format 'yyyy-MM-dd  HH:mm:ss')

$statusStrip.Controls.AddRange(@($lblFooter, $lblClock))
$statusStrip.Add_Resize({
    $lblClock.Location = New-Object System.Drawing.Point(
        ($statusStrip.ClientSize.Width - $lblClock.Width - 12), 7)
})
$clockTimer          = New-Object System.Windows.Forms.Timer
$clockTimer.Interval = 1000
$clockTimer.Add_Tick({
    $lblClock.Text = (Get-Date -Format 'yyyy-MM-dd  HH:mm:ss')
    $lblClock.Location = New-Object System.Drawing.Point(
        ($statusStrip.ClientSize.Width - $lblClock.Width - 12), 7)
})
$clockTimer.Start()

# ----------------------------------------------------------------------------
#  Shown / Resize
# ----------------------------------------------------------------------------
$form.Add_Shown({
    try { [Win32Cue]::SetCue($txtUser.Handle, "DOMAIN\username  or  user@domain.com") } catch { }
    try { [Win32Cue]::SetCue($txtPass.Handle, "Password") } catch { }
    # Match Connect button height exactly to the Password textbox and top-align
    $btnAuth.Height = $txtPass.Height
    $btnAuth.Top    = $txtPass.Top
    & $updateStatus
})
$form.Add_Resize({ & $updateStatus })
& $updateStatus

# ============================================================================
#  HELP / REQUIREMENTS DIALOG
# ============================================================================
function Show-RequirementsDialog {
    $dlg                  = New-Object System.Windows.Forms.Form
    $dlg.Text             = "Help"
    $dlg.StartPosition    = "CenterParent"
    $dlg.Size             = New-Object System.Drawing.Size(620, 620)
    $dlg.MinimumSize      = New-Object System.Drawing.Size(540, 480)
    $dlg.BackColor        = $clrFormBg
    $dlg.Font             = $fntInput
    $dlg.MaximizeBox      = $false
    $dlg.MinimizeBox      = $false
    $dlg.ShowInTaskbar    = $false
    if ($script:appIcon) { $dlg.Icon = $script:appIcon }

    # 4-row root: title band / body card / about footer / button bar
    $dlgRoot              = New-Object System.Windows.Forms.TableLayoutPanel
    $dlgRoot.Dock         = "Fill"
    $dlgRoot.ColumnCount  = 1
    $dlgRoot.RowCount     = 4
    $dlgRoot.BackColor    = $clrFormBg
    [void]$dlgRoot.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$dlgRoot.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50)))
    [void]$dlgRoot.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$dlgRoot.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 70)))
    [void]$dlgRoot.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 54)))
    $dlg.Controls.Add($dlgRoot)

    $dlgBand              = New-Object System.Windows.Forms.Panel
    $dlgBand.Dock         = "Fill"
    $dlgBand.BackColor    = $clrBand
    $dlgRoot.Controls.Add($dlgBand, 0, 0)

    # Logo on the left side of the band - shows the full app icon at 32x32.
    $dlgBandLogo            = New-Object System.Windows.Forms.PictureBox
    $dlgBandLogo.Size       = New-Object System.Drawing.Size(32, 32)
    $dlgBandLogo.Location   = New-Object System.Drawing.Point(14, 9)
    $dlgBandLogo.SizeMode   = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $dlgBandLogo.BackColor  = [System.Drawing.Color]::Transparent
    if ($script:appBitmap) { $dlgBandLogo.Image = $script:appBitmap }
    $dlgBand.Controls.Add($dlgBandLogo)

    $dlgBandTitle           = New-Object System.Windows.Forms.Label
    $dlgBandTitle.Text      = "Remote Shell Runner v$($script:appVersion) - Requirements"
    $dlgBandTitle.Font      = $fntTitle
    $dlgBandTitle.ForeColor = $clrText
    $dlgBandTitle.AutoSize  = $true
    $dlgBandTitle.Location  = New-Object System.Drawing.Point(56, 14)
    $dlgBandTitle.BackColor = [System.Drawing.Color]::Transparent
    $dlgBand.Controls.Add($dlgBandTitle)

    $dlgBandEdge            = New-Object System.Windows.Forms.Panel
    $dlgBandEdge.Dock       = "Bottom"
    $dlgBandEdge.Height     = 1
    $dlgBandEdge.BackColor  = $clrBandEdge
    $dlgBand.Controls.Add($dlgBandEdge)

    $dlgBody              = New-Object System.Windows.Forms.Panel
    $dlgBody.Dock         = "Fill"
    $dlgBody.BackColor    = $clrCard
    $dlgBody.Padding      = New-Object System.Windows.Forms.Padding(18, 14, 18, 14)
    $dlgRoot.Controls.Add($dlgBody, 0, 1)

    $rtb                  = New-Object System.Windows.Forms.RichTextBox
    $rtb.Dock             = "Fill"
    $rtb.ReadOnly         = $true
    $rtb.BackColor        = $clrCard
    $rtb.ForeColor        = $clrText
    $rtb.BorderStyle      = "None"
    $rtb.DetectUrls       = $true
    $rtb.ScrollBars       = "Vertical"
    $rtb.TabStop          = $false
    $dlgBody.Controls.Add($rtb)

    $fntHead = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $fntBody = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $fntCode = New-Object System.Drawing.Font("Consolas", 9.5)

    $append = {
        param($text, $font, $color)
        $rtb.SelectionStart  = $rtb.TextLength
        $rtb.SelectionLength = 0
        $rtb.SelectionFont   = $font
        $rtb.SelectionColor  = $color
        $rtb.AppendText($text)
    }

    & $append "ON EACH TARGET HOST`n"                                                                       $fntHead $clrAccent
    & $append "1. PowerShell Remoting (WinRM) must be enabled. On the target, run as administrator:`n"      $fntBody $clrText
    & $append "       Enable-PSRemoting -Force`n`n"                                                          $fntCode $clrText
    & $append "2. Firewall must allow inbound TCP 5985 (HTTP) or 5986 (HTTPS) from your machine.`n`n"        $fntBody $clrText
    & $append "3. The credential you sign in with must have administrative rights on the target host.`n`n"  $fntBody $clrText

    & $append "ON YOUR MACHINE`n"                                                                            $fntHead $clrAccent
    & $append "1. Windows PowerShell 5.1 or later (built-in on Windows 10 / 11 and Server 2016+).`n`n"       $fntBody $clrText
    & $append "2. For workgroup or cross-domain targets, add them to TrustedHosts (run once as admin):`n"    $fntBody $clrText
    & $append "       Set-Item WSMan:\localhost\Client\TrustedHosts -Value 'host1,host2' -Force`n`n"         $fntCode $clrText

    & $append "CREDENTIAL FORMAT`n"                                                                          $fntHead $clrAccent
    & $append "Use one of these formats in the Username field:`n"                                            $fntBody $clrText
    & $append "   - DOMAIN\username        (Active Directory account)`n"                                     $fntBody $clrText
    & $append "   - username@domain.com    (UPN)`n"                                                          $fntBody $clrText
    & $append "   - .\username             (local account on your machine)`n"                                $fntBody $clrText
    & $append "   - COMPUTERNAME\username  (local account on the target host)`n`n"                           $fntBody $clrText

    & $append "QUICK CONNECTIVITY TEST`n"                                                                    $fntHead $clrAccent
    & $append "To verify WinRM works against a target, run on your machine:`n"                               $fntBody $clrText
    & $append "       Test-WSMan -ComputerName <hostname>`n"                                                 $fntCode $clrText
    & $append "A successful response means the host is reachable for remoting.`n"                            $fntBody $clrText

    $rtb.SelectionStart  = 0
    $rtb.SelectionLength = 0
    $rtb.ScrollToCaret()

    # ----- About footer (developer credit, version, LinkedIn) ---------------
    $dlgAbout              = New-Object System.Windows.Forms.Panel
    $dlgAbout.Dock         = "Fill"
    $dlgAbout.BackColor    = $clrCard
    $dlgRoot.Controls.Add($dlgAbout, 0, 2)

    $dlgAboutTopEdge           = New-Object System.Windows.Forms.Panel
    $dlgAboutTopEdge.Dock      = "Top"
    $dlgAboutTopEdge.Height    = 1
    $dlgAboutTopEdge.BackColor = $clrBandEdge
    $dlgAbout.Controls.Add($dlgAboutTopEdge)

    $lblAuthor           = New-Object System.Windows.Forms.Label
    $lblAuthor.Text      = "Developed by $($script:appAuthor)  -  $($script:appAuthorRole)"
    $lblAuthor.Font      = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5)
    $lblAuthor.ForeColor = $clrText
    $lblAuthor.AutoSize  = $true
    $lblAuthor.Location  = New-Object System.Drawing.Point(18, 14)
    $lblAuthor.BackColor = [System.Drawing.Color]::Transparent
    $dlgAbout.Controls.Add($lblAuthor)

    $lblVersion           = New-Object System.Windows.Forms.Label
    $lblVersion.Text      = "Version $($script:appVersion)"
    $lblVersion.Font      = $fntHint
    $lblVersion.ForeColor = $clrTextSoft
    $lblVersion.AutoSize  = $true
    $lblVersion.BackColor = [System.Drawing.Color]::Transparent
    $dlgAbout.Controls.Add($lblVersion)

    # "Connect with me on LinkedIn"  -  only "LinkedIn" is the link
    $lnkConnect                  = New-Object System.Windows.Forms.LinkLabel
    $lnkConnect.Text             = "Connect with me on LinkedIn"
    $lnkConnect.Font             = $fntDev
    $lnkConnect.AutoSize         = $true
    $lnkConnect.Location         = New-Object System.Drawing.Point(18, 38)
    # "Connect with me on " is 19 characters, "LinkedIn" is 8
    $lnkConnect.LinkArea         = New-Object System.Windows.Forms.LinkArea(19, 8)
    $lnkConnect.LinkColor        = $clrAccent
    $lnkConnect.ActiveLinkColor  = $clrAccentHot
    $lnkConnect.VisitedLinkColor = $clrAccent
    $lnkConnect.LinkBehavior     = [System.Windows.Forms.LinkBehavior]::HoverUnderline
    $lnkConnect.Cursor           = [System.Windows.Forms.Cursors]::Hand
    $lnkConnect.BackColor        = [System.Drawing.Color]::Transparent
    $lnkConnect.ForeColor        = $clrTextSoft
    $lnkConnect.Add_LinkClicked({
        try {
            Start-Process $script:appLinkedIn
            $lnkConnect.LinkVisited = $true
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message, "Could not open LinkedIn", "OK", "Error") | Out-Null
        }
    })
    $dlgAbout.Controls.Add($lnkConnect)

    $positionVersion = {
        $lblVersion.Location = New-Object System.Drawing.Point(
            ($dlgAbout.ClientSize.Width - $lblVersion.Width - 18), 16)
    }
    $dlgAbout.Add_Resize($positionVersion)

    # ----- Button bar -------------------------------------------------------
    $dlgBtnBar             = New-Object System.Windows.Forms.Panel
    $dlgBtnBar.Dock        = "Fill"
    $dlgBtnBar.BackColor   = $clrFormBg
    $dlgRoot.Controls.Add($dlgBtnBar, 0, 3)

    $dlgBtnTopEdge           = New-Object System.Windows.Forms.Panel
    $dlgBtnTopEdge.Dock      = "Top"
    $dlgBtnTopEdge.Height    = 1
    $dlgBtnTopEdge.BackColor = $clrBandEdge
    $dlgBtnBar.Controls.Add($dlgBtnTopEdge)

    $dlgBtnOk        = New-Button "Close" $true
    $dlgBtnOk.Width  = 110
    $dlgBtnOk.Height = 30
    $dlgBtnOk.Add_Click({ $dlg.Close() })
    $dlgBtnBar.Controls.Add($dlgBtnOk)

    $positionOk = {
        $dlgBtnOk.Location = New-Object System.Drawing.Point(
            ($dlgBtnBar.ClientSize.Width - $dlgBtnOk.Width - 18), 12)
    }
    $dlgBtnBar.Add_Resize($positionOk)
    $dlg.Add_Shown({ & $positionOk; & $positionVersion })

    $dlg.AcceptButton = $dlgBtnOk
    $dlg.CancelButton = $dlgBtnOk

    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

# ============================================================================
#  HELPERS
# ============================================================================
function Write-Line($rtb, $text, $color) {
    $rtb.SelectionStart  = $rtb.TextLength
    $rtb.SelectionLength = 0
    $rtb.SelectionColor  = $color
    $rtb.AppendText("$text`n")
    $rtb.SelectionColor  = $clrOutText
    $rtb.ScrollToCaret()
}
function Set-Footer($text) { $lblFooter.Text = $text }

# ============================================================================
#  CONNECT
# ============================================================================
$btnAuth.Add_Click({
    $u = $txtUser.Text.Trim()
    $p = $txtPass.Text
    if (-not $u -or -not $p) {
        $lblStatus.Text      = "Enter username and password"
        $lblStatus.ForeColor = $clrError
        Set-Footer "Enter username and password"
        & $updateStatus; return
    }

    Set-Footer "Validating credentials..."
    $form.Cursor = 'WaitCursor'
    try {
        $check = Test-RemoteToolCredential -UserName $u -PlainPassword $p
    } finally {
        $form.Cursor = 'Default'
    }

    if (-not $check.Ok) {
        $script:cred = $null
        $lblStatus.Text      = "Authentication failed"
        $lblStatus.ForeColor = $clrError
        & $updateStatus
        $detail = if ($check.Message) { " ($($check.Message))" } else { "" }
        Write-Line $txtOut "[$(Get-Date -Format 'HH:mm:ss')] Login failed for $u - invalid credentials or domain unreachable$detail" $clrError
        Set-Footer "Authentication failed"
        return
    }

    $sec         = ConvertTo-SecureString $p -AsPlainText -Force
    $script:cred = New-Object System.Management.Automation.PSCredential($u, $sec)
    $lblStatus.Text      = "Signed in: $u"
    $lblStatus.ForeColor = $clrSuccess
    & $updateStatus
    Write-Line $txtOut "[$(Get-Date -Format 'HH:mm:ss')] Authenticated as $u" $clrSuccess
    Set-Footer "Signed in as $u"
})

# ============================================================================
#  RUN  (background runspace with soft-stop)
# ============================================================================
$script:runState = @{
    Active       = $false
    StopRequested= $false
    Hosts        = @()
    HostIndex    = 0
    ScriptText   = ''
    PS           = $null
    Async        = $null
    CurrentHost  = $null
    CurrentLog   = ''
}

function Set-RunButtons {
    param([bool]$Running)
    if ($Running) {
        $btnRun.Enabled   = $false
        $btnClear.Enabled = $false
        $btnStop.Enabled  = $true
        $btnAuth.Enabled  = $false
    } else {
        $btnRun.Enabled   = $true
        $btnClear.Enabled = $true
        $btnStop.Enabled  = $false
        $btnAuth.Enabled  = $true
    }
}

function Start-NextHost {
    $idx = $script:runState.HostIndex
    $h   = $script:runState.Hosts[$idx].Trim()
    $script:runState.CurrentHost = $h
    $script:runState.CurrentLog  = "=== $h ===`n"

    Write-Line $txtOut "" $clrOutText
    Write-Line $txtOut "---  $h  ---" $clrAccent
    foreach ($line in ($script:runState.ScriptText -split "`r?`n")) {
        Write-Line $txtOut "PS $h> $line" $clrMutedLog
        $script:runState.CurrentLog += "PS $h> $line`n"
    }

    Set-Footer ("Running on host {0} of {1}: {2}" -f ($idx + 1), $script:runState.Hosts.Count, $h)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $isLocal = ($h -eq "localhost" -or $h -ieq $env:COMPUTERNAME)

    try {
        if ($isLocal) {
            [void]$ps.AddScript($script:runState.ScriptText)
        } else {
            $sb = [ScriptBlock]::Create($script:runState.ScriptText)
            [void]$ps.AddCommand('Invoke-Command').
                    AddParameter('ComputerName', $h).
                    AddParameter('ScriptBlock',  $sb).
                    AddParameter('ErrorAction',  'Continue')
            if ($script:cred) {
                [void]$ps.AddParameter('Credential', $script:cred)
            }
        }
        $script:runState.PS    = $ps
        $script:runState.Async = $ps.BeginInvoke()
    } catch {
        Write-Line $txtOut "[ERROR] $($_.Exception.Message)" $clrError
        $script:runState.CurrentLog += "[ERROR] $($_.Exception.Message)`n"
        $results[$h] = $script:runState.CurrentLog
        try { $ps.Dispose() } catch { }
        $script:runState.PS    = $null
        $script:runState.Async = $null
    }
}

function Finish-CurrentHost {
    param([bool]$Stopped = $false)
    $ps = $script:runState.PS
    $h  = $script:runState.CurrentHost
    if ($null -eq $ps) { return }

    try {
        $output = $null
        try {
            $output = $ps.EndInvoke($script:runState.Async)
        } catch [System.Management.Automation.PipelineStoppedException] {
            Write-Line $txtOut "[STOPPED] $h - command cancelled" $clrError
            $script:runState.CurrentLog += "[STOPPED] $h - command cancelled`n"
        } catch {
            Write-Line $txtOut "[ERROR] $($_.Exception.Message)" $clrError
            $script:runState.CurrentLog += "[ERROR] $($_.Exception.Message)`n"
        }

        if ($output) {
            $out = ($output | Out-String).TrimEnd()
            if ($out) {
                Write-Line $txtOut $out $clrOutText
                $script:runState.CurrentLog += "$out`n"
            }
        }
        if ($ps.Streams.Error.Count -gt 0) {
            foreach ($err in $ps.Streams.Error) {
                Write-Line $txtOut "[ERROR] $($err.Exception.Message)" $clrError
                $script:runState.CurrentLog += "[ERROR] $($err.Exception.Message)`n"
            }
        }
    } finally {
        $results[$h] = $script:runState.CurrentLog
        try { $ps.Dispose() } catch { }
        $script:runState.PS    = $null
        $script:runState.Async = $null
    }
}

function Complete-Run {
    param([bool]$Stopped = $false)
    $script:runState.Active = $false
    $runTimer.Stop()
    $form.Cursor = 'Default'
    Set-RunButtons -Running:$false

    Write-Line $txtOut "" $clrOutText
    if ($Stopped) {
        Write-Line $txtOut "---  STOPPED BY USER  $(Get-Date -Format 'HH:mm:ss')  ---" $clrError
        Set-Footer "Execution stopped"
    } else {
        Write-Line $txtOut "---  Done  $(Get-Date -Format 'HH:mm:ss')  ---" $clrMutedLog
        Set-Footer ("Done - {0} host(s)" -f $script:runState.Hosts.Count)
    }
}

$runTimer          = New-Object System.Windows.Forms.Timer
$runTimer.Interval = 200
$runTimer.Add_Tick({
    if (-not $script:runState.Active) { $runTimer.Stop(); return }

    # No current host -> start next or complete
    if ($null -eq $script:runState.PS) {
        if ($script:runState.StopRequested -or
            $script:runState.HostIndex -ge $script:runState.Hosts.Count) {
            Complete-Run -Stopped:$script:runState.StopRequested
            return
        }
        Start-NextHost
        return
    }

    # Current host finished (either normally or because of Stop)
    if ($script:runState.Async -and $script:runState.Async.IsCompleted) {
        Finish-CurrentHost
        $script:runState.HostIndex += 1
    }
})

$btnRun.Add_Click({
    if ($script:runState.Active) { return }

    $hosts      = @($txtHosts.Text -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
    $scriptText = $txtCmd.Text.Trim()

    if (-not $hosts -or $hosts.Count -eq 0) {
        Write-Line $txtOut "[ERROR] No hosts specified."    $clrError
        Set-Footer "No hosts"; return
    }
    if (-not $scriptText) {
        Write-Line $txtOut "[ERROR] No commands specified." $clrError
        Set-Footer "No commands"; return
    }

    $results.Clear()

    $script:runState.Active        = $true
    $script:runState.StopRequested = $false
    $script:runState.Hosts         = $hosts
    $script:runState.HostIndex     = 0
    $script:runState.ScriptText    = $scriptText
    $script:runState.PS            = $null
    $script:runState.Async         = $null
    $script:runState.CurrentHost   = $null
    $script:runState.CurrentLog    = ''

    Set-RunButtons -Running:$true
    $form.Cursor = 'AppStarting'
    Set-Footer ("Starting run on {0} host(s)..." -f $hosts.Count)
    $runTimer.Start()
})

$btnStop.Add_Click({
    if (-not $script:runState.Active) { return }
    if ($script:runState.StopRequested) { return }
    $script:runState.StopRequested = $true
    $btnStop.Enabled = $false
    Set-Footer "Stopping..."
    try {
        if ($script:runState.PS) {
            $script:runState.PS.BeginStop($null, $null) | Out-Null
        }
    } catch { }
})

# ============================================================================
#  CLEAR / HOST CLICK / EXPORT
# ============================================================================
$btnClear.Add_Click({ $txtOut.Clear(); $results.Clear(); Set-Footer "Output cleared" })

$txtHosts.Add_MouseClick({
    $pos   = $txtHosts.GetCharIndexFromPosition($txtHosts.PointToClient([System.Windows.Forms.Cursor]::Position))
    $idx   = $txtHosts.GetLineFromCharIndex($pos)
    $lines = $txtHosts.Lines
    if ($idx -lt $lines.Length) {
        $h = $lines[$idx].Trim()
        if ($results.ContainsKey($h)) {
            $txtHosts.Select($txtHosts.GetFirstCharIndexFromLine($idx), $lines[$idx].Length)
            $txtOut.Clear()
            Write-Line $txtOut $results[$h] $clrOutText
            Set-Footer "Showing output for $h"
        }
    }
})

$btnExport.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title       = "Export output to log file"
    $dlg.Filter      = "Log files (*.log)|*.log|All files (*.*)|*.*"
    $dlg.DefaultExt  = "log"
    $dlg.AddExtension = $true
    $dlg.FileName    = "remote-shell-runner_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date)
    if ($dlg.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($dlg.FileName, $txtOut.Text, $utf8NoBom)
        Set-Footer "Exported to $($dlg.FileName)"
        [System.Windows.Forms.MessageBox]::Show("Saved to:`n$($dlg.FileName)", "Export", "OK", "Information") | Out-Null
    } catch {
        Set-Footer "Export failed"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Export failed", "OK", "Error") | Out-Null
    }
})

$form.Add_FormClosed({
    if ($clockTimer) { $clockTimer.Stop(); $clockTimer.Dispose() }
    if ($runTimer)   { $runTimer.Stop();   $runTimer.Dispose() }
    if ($script:runState -and $script:runState.PS) {
        try { $script:runState.PS.Stop() } catch { }
        try { $script:runState.PS.Dispose() } catch { }
    }
})

[void]$form.ShowDialog()
