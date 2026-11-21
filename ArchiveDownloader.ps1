#Requires -Version 5.1
<#
  Archive Downloader - a small GUI around aria2c for archive.org downloads
  that need you to be logged in.

  - Add links to the list (type/paste them, or load them from a .txt file).
  - Paste your logged-in-user and logged-in-sig cookie values.
  - Pick a folder and click Download. Progress shows in a separate window.
  - The list shows which links are done; remove them with Remove finished.

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

# The file name aria2c will save a link as (last part of the URL, decoded).
function Get-FileNameFromUrl([string]$Url) {
    try {
        $path = ([Uri]$Url).AbsolutePath.TrimEnd('/')
        $name = [Uri]::UnescapeDataString($path.Substring($path.LastIndexOf('/') + 1))
        if (-not $name -or $name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return '' }
        return $name
    } catch { return '' }
}

# 'Done', 'Partial' (aria2 control file present) or '' (not started / unknown).
function Get-LinkStatus([string]$Url, [string]$Dest) {
    if (-not $Dest) { return '' }
    $name = Get-FileNameFromUrl $Url
    if (-not $name) { return '' }
    try { $path = Join-Path $Dest $name } catch { return '' }
    if (Test-Path -LiteralPath "$path.aria2") { return 'Partial' }
    if (Test-Path -LiteralPath $path -PathType Leaf) { return 'Done' }
    return ''
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
$form.ClientSize      = New-Object System.Drawing.Size(620, 582)
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

# --- links list ---
New-Ctl Label 12 14 380 20 'Links to download - type or paste a link, then press Enter:' | Out-Null
$btnPaste = New-Ctl Button 400 8 84 26 'Paste links'
$btnLoad  = New-Ctl Button 490 8 118 26 'Load from file...'

$txtAdd = New-Ctl TextBox 12 40 500 24
$btnAdd = New-Ctl Button 518 38 90 27 'Add'

$lv = New-Ctl ListView 12 72 596 170
$lv.View          = 'Details'
$lv.FullRowSelect = $true
$lv.MultiSelect   = $true
$lv.HideSelection = $false
$lv.GridLines     = $true
[void]$lv.Columns.Add('File', 220)
[void]$lv.Columns.Add('Status', 80)
[void]$lv.Columns.Add('Link', 270)

$btnRemove   = New-Ctl Button 12 248 120 26 'Remove selected'
$btnRemoveDone = New-Ctl Button 138 248 120 26 'Remove finished'
$btnClear    = New-Ctl Button 264 248 80 26 'Clear all'
$lblCount    = New-Ctl Label 350 253 258 20
$lblCount.TextAlign = 'TopRight'
$lblCount.ForeColor = [System.Drawing.Color]::DimGray

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miRemove = $menu.Items.Add('Remove')
$miCopy   = $menu.Items.Add('Copy link')
$miOpen   = $menu.Items.Add('Open download folder')
$lv.ContextMenuStrip = $menu

# --- cookie ---
New-Ctl Label 12 286 596 20 'Cookie: logged-in-user  (or paste the whole cookie string here)' | Out-Null
$txtUser = New-Ctl TextBox 12 306 596 24
$txtUser.Text = Unprotect-Text $settings.User

New-Ctl Label 12 336 596 20 'Cookie: logged-in-sig' | Out-Null
$txtSig = New-Ctl TextBox 12 356 596 24
$txtSig.UseSystemPasswordChar = $true
$txtSig.Text = Unprotect-Text $settings.Sig

$lblHint = New-Ctl Label 12 384 596 34 ('Find both while logged in to archive.org: press F12, then Application (Edge/Chrome) ' +
    'or Storage (Firefox), then Cookies, then https://archive.org.')
$lblHint.ForeColor = [System.Drawing.Color]::DimGray

$chkRemember = New-Ctl CheckBox 12 418 596 22 'Remember cookie on this PC (encrypted for your Windows account)'
$chkRemember.Checked = [bool]$settings.Remember

# --- destination and options ---
New-Ctl Label 12 450 596 20 'Save to:' | Out-Null
$txtDest = New-Ctl TextBox 12 470 500 24
$txtDest.Text = $settings.Dest
$btnBrowse = New-Ctl Button 518 468 90 27 'Browse...'

New-Ctl Label 12 508 140 20 'Connections per file:' | Out-Null
$numConn = New-Ctl NumericUpDown 150 505 60 24
$numConn.Minimum = 1
$numConn.Maximum = 16
$numConn.Value   = [Math]::Min(16, [Math]::Max(1, [int]$settings.Connections))

New-Ctl Label 228 508 90 20 'Files at once:' | Out-Null
$numFiles = New-Ctl NumericUpDown 318 505 60 24
$numFiles.Minimum = 1
$numFiles.Maximum = 10
$numFiles.Value   = [Math]::Min(10, [Math]::Max(1, [int]$settings.FilesAtOnce))

$lnkSettings = New-Ctl LinkLabel 428 508 180 20 'Open settings folder'
$lnkSettings.TextAlign = 'TopRight'

$lblStatus = New-Ctl Label 12 548 330 22
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray

$btnInstall  = New-Ctl Button 350 542 120 30 'Install aria2'
$btnDownload = New-Ctl Button 478 542 130 30 'Download'
$form.AcceptButton = $null   # Enter in the add box adds a link instead

if (Find-Aria2) {
    $btnInstall.Visible = $false
    $lblStatus.Text = 'Ready.'
} else {
    $lblStatus.Text = 'aria2c not found. Click Install aria2 first.'
}

# ---------- logic ----------

function Get-AllLinks { @($lv.Items | ForEach-Object { [string]$_.Tag }) }

function Update-Statuses {
    $dest = $txtDest.Text.Trim()
    $done = 0
    foreach ($item in $lv.Items) {
        $st = Get-LinkStatus ([string]$item.Tag) $dest
        if ($st -eq 'Done') { $done++ }
        $sub = $item.SubItems[1]
        if ($sub.Text -ne $st) {
            $sub.Text = $st
            $sub.ForeColor = switch ($st) {
                'Done'    { [System.Drawing.Color]::ForestGreen }
                'Partial' { [System.Drawing.Color]::DarkOrange }
                default   { [System.Drawing.SystemColors]::WindowText }
            }
        }
    }
    $total = $lv.Items.Count
    if ($total -eq 0) { $lblCount.Text = 'No links yet' }
    else { $lblCount.Text = "$total link(s), $done done" }
}

# Add links to the list, skipping blanks, # comments and duplicates.
function Add-Links([string[]]$Lines) {
    $existing = @(Get-AllLinks)
    $bad = @()
    $lv.BeginUpdate()
    foreach ($raw in $Lines) {
        $line = "$raw".Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^https?://\S+$') { $bad += $line; continue }
        if ($existing -contains $line) { continue }
        $name = Get-FileNameFromUrl $line
        if (-not $name) { $name = '(unknown)' }
        $item = New-Object System.Windows.Forms.ListViewItem -ArgumentList $name
        $item.UseItemStyleForSubItems = $false
        [void]$item.SubItems.Add('')
        [void]$item.SubItems.Add($line)
        $item.Tag = $line
        [void]$lv.Items.Add($item)
        $existing += $line
    }
    $lv.EndUpdate()
    Update-Statuses
    if ($bad.Count -gt 0) {
        $shown = ($bad | Select-Object -First 10) -join "`n"
        Show-Message "These lines are not links and were skipped:`n`n$shown" 'Warning' | Out-Null
    }
}

function Add-LinksFromClipboard {
    $text = [System.Windows.Forms.Clipboard]::GetText()
    if (-not $text) { return }
    Add-Links ($text -split "\r?\n")
    Save-Settings
}

function Add-FromBox {
    $text = $txtAdd.Text.Trim()
    if (-not $text) { return }
    Add-Links ($text -split "\r?\n")
    $txtAdd.Clear()
    Save-Settings
}

function Remove-SelectedLinks {
    $selected = @($lv.SelectedItems)
    if ($selected.Count -eq 0) { return }
    $lv.BeginUpdate()
    foreach ($item in $selected) { $lv.Items.Remove($item) }
    $lv.EndUpdate()
    Update-Statuses
    Save-Settings
}

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
        Links       = (Get-AllLinks) -join "`r`n"
    } | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8
}

# Restore the saved list
if ($settings.Links) { Add-Links ([string]$settings.Links -split "\r?\n") } else { Update-Statuses }

# Save the number settings as soon as they change, not only on Download/close
$numConn.Add_ValueChanged({ try { Save-Settings } catch { } })
$numFiles.Add_ValueChanged({ try { Save-Settings } catch { } })

# --- list events ---
$btnAdd.Add_Click({ Add-FromBox })

$txtAdd.Add_KeyDown({
    if ($_.KeyCode -eq 'Enter') {
        Add-FromBox
        $_.SuppressKeyPress = $true
    } elseif ($_.Control -and $_.KeyCode -eq 'V') {
        # A single-line box would drop everything after the first line,
        # so add multi-line pastes straight to the list.
        $clip = [System.Windows.Forms.Clipboard]::GetText()
        if ($clip -match '\r?\n') {
            Add-LinksFromClipboard
            $_.SuppressKeyPress = $true
        }
    }
})

$lv.Add_KeyDown({
    if ($_.KeyCode -eq 'Delete') {
        Remove-SelectedLinks
        $_.Handled = $true
    } elseif ($_.Control -and $_.KeyCode -eq 'A') {
        foreach ($item in $lv.Items) { $item.Selected = $true }
        $_.Handled = $true
    } elseif ($_.Control -and $_.KeyCode -eq 'V') {
        Add-LinksFromClipboard
        $_.Handled = $true
    }
})

$btnPaste.Add_Click({ Add-LinksFromClipboard })

$btnLoad.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        Add-Links @(Get-Content -LiteralPath $dlg.FileName)
        Save-Settings
    }
})

$btnRemove.Add_Click({ Remove-SelectedLinks })
$miRemove.Add_Click({ Remove-SelectedLinks })

$btnRemoveDone.Add_Click({
    Update-Statuses
    $doneItems = @($lv.Items | Where-Object { $_.SubItems[1].Text -eq 'Done' })
    if ($doneItems.Count -eq 0) { $lblStatus.Text = 'No finished links to remove.'; return }
    $lv.BeginUpdate()
    foreach ($item in $doneItems) { $lv.Items.Remove($item) }
    $lv.EndUpdate()
    Update-Statuses
    Save-Settings
    $lblStatus.Text = "Removed $($doneItems.Count) finished link(s)."
})

$btnClear.Add_Click({
    if ($lv.Items.Count -eq 0) { return }
    $answer = Show-Message "Remove all $($lv.Items.Count) link(s) from the list?`n`n(Downloaded files are not touched.)" 'Question' 'YesNo'
    if ($answer -ne 'Yes') { return }
    $lv.Items.Clear()
    Update-Statuses
    Save-Settings
})

$miCopy.Add_Click({
    $text = (@($lv.SelectedItems) | ForEach-Object { [string]$_.Tag }) -join "`r`n"
    if ($text) { [System.Windows.Forms.Clipboard]::SetText($text) }
})

$miOpen.Add_Click({
    $dest = $txtDest.Text.Trim()
    if ($dest -and (Test-Path -LiteralPath $dest)) { Start-Process explorer.exe -ArgumentList "`"$dest`"" }
})

# --- other events ---
$txtDest.Add_TextChanged({ Update-Statuses })

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

    # Anything still in the add box counts too
    if ($txtAdd.Text.Trim()) { Add-FromBox }

    if ($lv.Items.Count -eq 0) { Show-Message 'Add at least one link.' 'Warning' | Out-Null; return }

    $dest = $txtDest.Text.Trim()
    if (-not $dest) { Show-Message 'Choose a folder to save to.' 'Warning' | Out-Null; return }
    if (-not (Test-Path $dest)) {
        try { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        catch { Show-Message "Could not create the folder:`n$dest" 'Error' | Out-Null; return }
    }

    # Skip links that are already fully downloaded
    $links = @(Get-AllLinks | Where-Object { (Get-LinkStatus $_ $dest) -ne 'Done' })
    $skipped = $lv.Items.Count - $links.Count
    if ($links.Count -eq 0) {
        Show-Message 'Every link in the list is already downloaded. Use Remove finished to clear them.' | Out-Null
        return
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
    $msg = "Started $($links.Count) download(s) in a new window."
    if ($skipped -gt 0) { $msg += " Skipped $skipped already done." }
    $lblStatus.Text = $msg
})

# Refresh the Status column every few seconds while downloads run
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ Update-Statuses })
$timer.Start()

$form.Add_FormClosing({
    $timer.Stop()
    try { Save-Settings } catch { }
})

[void]$form.ShowDialog()
