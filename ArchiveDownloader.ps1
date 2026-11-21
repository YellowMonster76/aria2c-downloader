#Requires -Version 5.1
<#
  Archive Downloader - a small GUI around aria2c for archive.org downloads
  that need you to be logged in.

  - Paste one or more links (one per line) or load them from a .txt file.
  - Paste your logged-in-user and logged-in-sig cookie values.
  - Pick a folder and click Download. Progress shows in a separate window.

  Settings are saved in %APPDATA%\ArchiveDownloader\settings.json.
  If "Remember cookie" is ticked, the cookie is encrypted with Windows DPAPI,
  so only your Windows account on this PC can read it back.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$SettingsDir  = Join-Path $env:APPDATA 'ArchiveDownloader'
$SettingsFile = Join-Path $SettingsDir 'settings.json'
$ListFile     = Join-Path $SettingsDir 'links.txt'
if (-not (Test-Path $SettingsDir)) { New-Item -ItemType Directory -Path $SettingsDir | Out-Null }

# ---------- helpers ----------

function Protect-Text([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    ConvertTo-SecureString $Text -AsPlainText -Force | ConvertFrom-SecureString
}

function Unprotect-Text([string]$Blob) {
    if ([string]::IsNullOrEmpty($Blob)) { return '' }
    try {
        $secure = ConvertTo-SecureString $Blob
        (New-Object System.Management.Automation.PSCredential 'x', $secure).GetNetworkCredential().Password
    } catch { '' }
}

function Find-Aria2 {
    $cmd = Get-Command aria2c -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\aria2c.exe')
    $pkgDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path $pkgDir) {
        $candidates += Get-ChildItem $pkgDir -Recurse -Filter aria2c.exe -ErrorAction SilentlyContinue |
                       ForEach-Object { $_.FullName }
    }
    foreach ($p in $candidates) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

# Single-quote a string for safe embedding in a PowerShell command.
function Quote-PS([string]$s) { "'" + $s.Replace("'", "''") + "'" }

function Show-Message([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK') {
    [System.Windows.Forms.MessageBox]::Show($Text, 'Archive Downloader', $Buttons, $Icon)
}

# ---------- load settings ----------

$settings = [pscustomobject]@{
    Dest        = Join-Path $env:USERPROFILE 'Downloads'
    Connections = 8
    Remember    = $true
    User        = ''
    Sig         = ''
    Links       = ''
    FilesAtOnce = 5
}
if (Test-Path $SettingsFile) {
    try {
        $loaded = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        foreach ($p in $loaded.PSObject.Properties) {
            if ($settings.PSObject.Properties[$p.Name]) { $settings.($p.Name) = $p.Value }
        }
    } catch { }
}

# ---------- build the window ----------

$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Archive Downloader'
$form.ClientSize      = New-Object System.Drawing.Size(620, 462)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

function New-Ctl($type, $x, $y, $w, $h, $text = '') {
    $c = New-Object "System.Windows.Forms.$type"
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size     = New-Object System.Drawing.Size($w, $h)
    if ($text) { $c.Text = $text }
    $form.Controls.Add($c)
    return $c
}

New-Ctl Label 12 14 380 20 'Links to download (one per line):' | Out-Null
$btnClear = New-Ctl Button 410 8 74 26 'Clear'
$btnLoad  = New-Ctl Button 490 8 118 26 'Load from file...'

$txtLinks = New-Ctl TextBox 12 36 596 120
$txtLinks.Multiline  = $true
$txtLinks.ScrollBars = 'Vertical'
$txtLinks.WordWrap   = $false
if ($settings.Links) { $txtLinks.Text = [string]$settings.Links }
# Multiline WinForms text boxes don't support Ctrl+A on their own
$txtLinks.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq 'A') { $txtLinks.SelectAll(); $_.SuppressKeyPress = $true }
})

New-Ctl Label 12 166 596 20 'Cookie: logged-in-user  (or paste the whole cookie string here)' | Out-Null
$txtUser = New-Ctl TextBox 12 186 596 24
$txtUser.Text = Unprotect-Text $settings.User

New-Ctl Label 12 216 596 20 'Cookie: logged-in-sig' | Out-Null
$txtSig = New-Ctl TextBox 12 236 596 24
$txtSig.UseSystemPasswordChar = $true
$txtSig.Text = Unprotect-Text $settings.Sig

$lblHint = New-Ctl Label 12 264 596 34 ('Find both while logged in to archive.org: press F12, then Application (Edge/Chrome) ' +
    'or Storage (Firefox), then Cookies, then https://archive.org.')
$lblHint.ForeColor = [System.Drawing.Color]::DimGray

$chkRemember = New-Ctl CheckBox 12 298 596 22 'Remember cookie on this PC (encrypted for your Windows account)'
$chkRemember.Checked = [bool]$settings.Remember

New-Ctl Label 12 330 596 20 'Save to:' | Out-Null
$txtDest = New-Ctl TextBox 12 350 500 24
$txtDest.Text = $settings.Dest
$btnBrowse = New-Ctl Button 518 348 90 27 'Browse...'

New-Ctl Label 12 388 140 20 'Connections per file:' | Out-Null
$numConn = New-Ctl NumericUpDown 150 385 60 24
$numConn.Minimum = 1
$numConn.Maximum = 16
$numConn.Value   = [Math]::Min(16, [Math]::Max(1, [int]$settings.Connections))

New-Ctl Label 228 388 90 20 'Files at once:' | Out-Null
$numFiles = New-Ctl NumericUpDown 318 385 60 24
$numFiles.Minimum = 1
$numFiles.Maximum = 10
$numFiles.Value   = [Math]::Min(10, [Math]::Max(1, [int]$settings.FilesAtOnce))

$lnkSettings = New-Ctl LinkLabel 428 388 180 20 'Open settings folder'
$lnkSettings.TextAlign = 'TopRight'

$lblStatus = New-Ctl Label 12 428 330 22
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray

$btnInstall  = New-Ctl Button 350 422 120 30 'Install aria2'
$btnDownload = New-Ctl Button 478 422 130 30 'Download'
$form.AcceptButton = $null   # Enter should add new lines in the links box

if (Find-Aria2) {
    $btnInstall.Visible = $false
    $lblStatus.Text = 'Ready.'
} else {
    $lblStatus.Text = 'aria2c not found. Click Install aria2 first.'
}

# ---------- logic ----------

function Get-CookieString {
    $u = $txtUser.Text.Trim() -replace '^(?i)cookie:\s*', ''
    $s = $txtSig.Text.Trim()
    if ($u -match '=') { return $u }   # whole cookie string was pasted
    $parts = @()
    if ($u) { $parts += "logged-in-user=$u" }
    if ($s) { $parts += "logged-in-sig=$s" }
    return ($parts -join '; ')
}

function Save-Settings {
    $remember = $chkRemember.Checked
    $user = ''
    $sig  = ''
    if ($remember) {
        $user = Protect-Text $txtUser.Text.Trim()
        $sig  = Protect-Text $txtSig.Text.Trim()
    }
    [ordered]@{
        Dest        = $txtDest.Text.Trim()
        Connections = [int]$numConn.Value
        FilesAtOnce = [int]$numFiles.Value
        Remember    = $remember
        User        = $user
        Sig         = $sig
        Links       = $txtLinks.Text
    } | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8
}

# Save the number settings as soon as they change, not only on Download/close
$numConn.Add_ValueChanged({ try { Save-Settings } catch { } })
$numFiles.Add_ValueChanged({ try { Save-Settings } catch { } })

$btnClear.Add_Click({
    $txtLinks.Clear()
    [void]$txtLinks.Focus()
})

$btnLoad.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtLinks.Text = (Get-Content $dlg.FileName) -join "`r`n"
    }
})

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose where to save the downloads'
    if ($txtDest.Text -and (Test-Path $txtDest.Text)) { $dlg.SelectedPath = $txtDest.Text }
    if ($dlg.ShowDialog() -eq 'OK') { $txtDest.Text = $dlg.SelectedPath }
})

$lnkSettings.Add_LinkClicked({
    if (-not (Test-Path $SettingsDir)) { New-Item -ItemType Directory -Path $SettingsDir | Out-Null }
    Start-Process explorer.exe -ArgumentList "`"$SettingsDir`""
})

$btnInstall.Add_Click({
    Start-Process powershell.exe -ArgumentList '-NoProfile -Command "winget install --id aria2.aria2 -e; Read-Host ''Press Enter to close''"'
    $lblStatus.Text = 'Installing in a new window. Click Download when done.'
    $btnInstall.Visible = $false
})

$btnDownload.Add_Click({
    $aria = Find-Aria2
    if (-not $aria) {
        Show-Message "aria2c was not found.`n`nClick 'Install aria2', or run:  winget install aria2.aria2" 'Warning' | Out-Null
        $btnInstall.Visible = $true
        return
    }

    $links = @($txtLinks.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($links.Count -eq 0) { Show-Message 'Paste at least one link.' 'Warning' | Out-Null; return }

    $bad = @($links | Where-Object { $_ -notmatch '^https?://' })
    if ($bad.Count -gt 0) {
        Show-Message ("These lines are not links:`n`n" + ($bad -join "`n")) 'Warning' | Out-Null
        return
    }

    $dest = $txtDest.Text.Trim()
    if (-not $dest) { Show-Message 'Choose a folder to save to.' 'Warning' | Out-Null; return }
    if (-not (Test-Path $dest)) {
        try { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        catch { Show-Message "Could not create the folder:`n$dest" 'Error' | Out-Null; return }
    }

    $cookie = Get-CookieString
    if (-not $cookie) {
        $answer = Show-Message 'No cookie entered. Download anyway? (Only works for public files.)' 'Question' 'YesNo'
        if ($answer -ne 'Yes') { return }
    }

    Save-Settings
    [System.IO.File]::WriteAllLines($ListFile, [string[]]$links)   # UTF-8 without BOM

    $n = [int]$numConn.Value
    $j = [int]$numFiles.Value
    # Script run in the new console window. The cookie is passed through an
    # environment variable so it never appears on a command line.
    $child = @"
`$host.UI.RawUI.WindowTitle = 'Archive Downloader - $($links.Count) file(s)'
`$h = @()
if (`$env:AD_COOKIE) { `$h = @('--header', "Cookie: `$env:AD_COOKIE") }
& $(Quote-PS $aria) -i $(Quote-PS $ListFile) -d $(Quote-PS $dest) -j $j -x $n -s $n -k 1M -c ``
    --file-allocation=none --max-tries=10 --retry-wait=5 --summary-interval=0 --console-log-level=warn @h
Write-Host ''
if (`$LASTEXITCODE -eq 0) {
    Write-Host 'All downloads finished.' -ForegroundColor Green
} else {
    Write-Host "aria2c stopped with error code `$LASTEXITCODE. Click Download again to resume." -ForegroundColor Red
    Write-Host 'If you got small HTML files instead of the real ones, your cookie has probably expired.'
}
Read-Host 'Press Enter to close'
"@
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($child))

    $env:AD_COOKIE = $cookie
    try {
        Start-Process powershell.exe -ArgumentList "-NoProfile -EncodedCommand $encoded"
    } finally {
        Remove-Item Env:AD_COOKIE -ErrorAction SilentlyContinue
    }
    $lblStatus.Text = "Started $($links.Count) download(s) in a new window."
})

$form.Add_FormClosing({ try { Save-Settings } catch { } })

[void]$form.ShowDialog()
