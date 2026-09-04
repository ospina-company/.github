# Is this Windows account genuinely un-bootstrapped?
#
#   irm https://raw.githubusercontent.com/ospina-company/.github/main/preflight.ps1 | iex
#
# Run this BEFORE install.ps1 on a test account. It reports whether the account
# is clean enough for the result to mean anything, and which tools are inherited
# machine-wide (those install paths will NOT be exercised by your test).
#
# Read-only. Changes nothing.

$ErrorActionPreference = 'Continue'

function Have ($c) { $null -ne (Get-Command $c -ErrorAction SilentlyContinue) }
function Test-StorePythonPackage {
  if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue |
            Select-Object -First 1)) {
    return $null
  }
  return $null -ne (Get-AppxPackage -Name 'PythonSoftwareFoundation.Python*' `
                     -ErrorAction SilentlyContinue | Select-Object -First 1)
}
function Have-UsablePython ($c) {
  $cmd = Get-Command $c -ErrorAction SilentlyContinue
  if (-not $cmd) { return $false }
  if ($cmd.Source -notmatch '(?i)\\Microsoft\\WindowsApps\\') { return $true }
  # Windows creates zero-function Store aliases even when Python is absent.
  # Count one only when this user actually has a Store Python package.
  $storePackage = Test-StorePythonPackage
  if ($null -eq $storePackage) {
    # Without Appx discovery we cannot prove that the visible alias is empty.
    # Keep the account out of the clean bucket instead of claiming it will
    # exercise Python installation from nothing.
    return $true
  }
  return $storePackage
}
function Test-IsUserScopedTool ($Tool, $Source) {
  if (-not $Source) { return $false }
  if ($Source.StartsWith('HKCU:', 'OrdinalIgnoreCase')) { return $true }
  if ($Source.StartsWith('HKLM:', 'OrdinalIgnoreCase')) { return $false }
  $isAlias = $Source -match '(?i)\\Microsoft\\WindowsApps\\'
  if ($Tool -in @('python','python3') -and $isAlias) {
    return (Test-StorePythonPackage)
  }
  return (-not $isAlias -and
          $Source.StartsWith($env:USERPROFILE, 'OrdinalIgnoreCase'))
}
function Get-LibreOfficePath {
  $cmd = Get-Command soffice -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $root) { continue }
    $candidate = Join-Path $root 'LibreOffice\program\soffice.exe'
    if (Test-Path $candidate) { return $candidate }
  }
  if ($env:LOCALAPPDATA) {
    $candidate = Join-Path $env:LOCALAPPDATA 'Programs\LibreOffice\program\soffice.exe'
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}
function Get-T3CodePath {
  $cmd = Get-Command t3 -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($root in @($env:LOCALAPPDATA, $env:ProgramFiles)) {
    if (-not $root) { continue }
    foreach ($relative in @('Programs\t3code','Programs\T3 Code','T3 Code')) {
      $candidate = Join-Path $root $relative
      if (Test-Path $candidate) { return $candidate }
    }
  }
  foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    $hit = Get-ItemProperty $key -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -like '*T3 Code*' } | Select-Object -First 1
    if ($hit) { return $key.TrimEnd('*') }
  }
  return $null
}
function Line ($state, $label, $detail) {
  $color = switch ($state) { 'CLEAN' {'Green'} 'DIRTY' {'Red'} default {'Yellow'} }
  Write-Host ("  {0,-6} {1,-38} {2}" -f $state, $label, $detail) -ForegroundColor $color
}

Write-Host ""
Write-Host "Ospina preflight: is this account un-bootstrapped?" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  user       : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
Write-Host ("  home       : {0}" -f $env:USERPROFILE)
Write-Host ("  PowerShell : {0}" -f $PSVersionTable.PSVersion)
$admin = ([Security.Principal.WindowsPrincipal] `
          [Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host ("  elevated   : {0}" -f $admin)
Write-Host ("  policy     : {0}" -f (Get-ExecutionPolicy))
if ((Get-ExecutionPolicy -Scope CurrentUser) -in @('Restricted','Undefined') -and
    (Get-ExecutionPolicy) -eq 'Restricted') {
  Write-Host "               Restricted blocks .ps1 files, which breaks npm (npm.ps1)." -ForegroundColor Yellow
  Write-Host "               Fix for this account only:" -ForegroundColor Yellow
  Write-Host "                 Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned" -ForegroundColor Yellow
}
Write-Host ""

$dirty = 0

Write-Host "Per-user state (all of these must be CLEAN for a valid test)" -ForegroundColor Cyan

# 1. GitHub CLI credentials
if (Have gh) {
  & gh auth status *> $null
  if ($LASTEXITCODE -eq 0) {
    $who = (& gh api user --jq .login 2>$null)
    Line 'DIRTY' 'gh credentials' "already signed in as $who"; $dirty++
  } else { Line 'CLEAN' 'gh credentials' 'not signed in' }
} else { Line 'CLEAN' 'gh credentials' 'gh not installed for this user' }

# 2. Agent skills. Claude and Codex use different user-level discovery roots.
foreach ($skillRoot in @('.claude\skills','.agents\skills')) {
  $skills = Join-Path $env:USERPROFILE $skillRoot
  if (Test-Path $skills) {
    $n = (Get-ChildItem $skills -ErrorAction SilentlyContinue).Count
    if ($n -gt 0) { Line 'DIRTY' "agent skills ($skillRoot)" "$skills has $n item(s)"; $dirty++ }
    else { Line 'CLEAN' "agent skills ($skillRoot)" 'directory exists but is empty' }
  } else { Line 'CLEAN' "agent skills ($skillRoot)" "no ~/$($skillRoot -replace '\\','/')" }
}

# 3. Environment variables
if ($env:OSPINA_HANDBOOK) { Line 'DIRTY' 'OSPINA_HANDBOOK' $env:OSPINA_HANDBOOK; $dirty++ }
else { Line 'CLEAN' 'OSPINA_HANDBOOK' 'not set' }
if ($env:VALE_CONFIG_PATH) { Line 'DIRTY' 'VALE_CONFIG_PATH' $env:VALE_CONFIG_PATH; $dirty++ }
else { Line 'CLEAN' 'VALE_CONFIG_PATH' 'not set' }

# 4. Shell profiles
$found = @()
foreach ($f in @('.bashrc','.bash_profile','.zshrc','.profile')) {
  $path = Join-Path $env:USERPROFILE $f
  if ((Test-Path $path) -and (Select-String -Path $path -Pattern 'ospina handbook' -Quiet -ErrorAction SilentlyContinue)) {
    $found += $f
  }
}
if ($found.Count) { Line 'DIRTY' 'shell profiles' ("ospina block in: " + ($found -join ', ')); $dirty++ }
else { Line 'CLEAN' 'shell profiles' 'no ospina block' }

# 5. Git global config (per-user, so a fresh account should have none)
if (Have git) {
  $acrlf = (& git config --global --get core.autocrlf 2>$null)
  $lpath = (& git config --global --get core.longpaths 2>$null)
} else { $acrlf = $null; $lpath = $null }
if ($acrlf -or $lpath) {
  Line 'DIRTY' 'git global config' "core.autocrlf=$acrlf core.longpaths=$lpath"; $dirty++
} else { Line 'CLEAN' 'git global config' 'core.autocrlf and core.longpaths unset' }

# 6. Existing workspace
$ws = @('C:\Ospina', (Join-Path $env:USERPROFILE 'Ospina'), (Join-Path $env:USERPROFILE 'Repositories')) |
      Where-Object { Test-Path $_ }
if ($ws) { Line 'DIRTY' 'existing workspace' ($ws -join ', '); $dirty++ }
else { Line 'CLEAN' 'existing workspace' 'none of the default paths exist' }

Write-Host ""
Write-Host "Tools already present" -ForegroundColor Cyan
Write-Host "  Your test will NOT exercise installing these. Scope is inferred from" -ForegroundColor DarkGray
Write-Host "  the path: something under your profile is yours alone, not the machine's." -ForegroundColor DarkGray

$inherited = 0
$scopeUnknown = 0
foreach ($t in 'git','gh','node','npm','corepack','uv','python','python3',
                    'pdftotext','pdftoppm','pdfinfo','soffice','vale',
                    't3','claude','codex','winget') {
  $specialPath = $null
  if ($t -in @('python','python3')) { $present = Have-UsablePython $t }
  elseif ($t -eq 'soffice') { $specialPath = Get-LibreOfficePath; $present = $null -ne $specialPath }
  elseif ($t -eq 't3') { $specialPath = Get-T3CodePath; $present = $null -ne $specialPath }
  else { $present = Have $t }
  if ($present) {
    $src = if ($specialPath) { $specialPath } else {
      (Get-Command $t -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    }
    # A binary under the user profile was installed for this account, so it is
    # not evidence that the machine provides it to everyone.
    # WindowsApps holds app execution aliases, which Windows provides. A binary
    # there sits under the profile but was not installed by this account.
    $userScoped = Test-IsUserScopedTool $t $src
    $scopeLabel = if ($null -eq $userScoped) {
      $scopeUnknown++
      'scope unknown'
    } elseif ($userScoped) {
      'this user'
    } else {
      'machine-wide'
    }
    Line 'NOTE' $t ("{0}  [{1}]" -f $src, $scopeLabel)
    if ($t -ne 'winget' -and $false -eq $userScoped) { $inherited++ }
  } else {
    Line 'CLEAN' $t 'not installed, so the install path WILL be tested'
  }
}

Write-Host ""
Write-Host "----------------------------------------------------------------"
if ($dirty -eq 0) {
  Write-Host "VALID TEST ACCOUNT. No Ospina per-user state found." -ForegroundColor Green
} else {
  Write-Host "NOT A CLEAN TEST. $dirty item(s) above are already configured." -ForegroundColor Red
  Write-Host "A run from here can pass for the wrong reason. Either use a new"
  Write-Host "account, or clear the items marked DIRTY first."
}
if ($inherited -gt 0) {
  Write-Host ""
  Write-Host "$inherited tool(s) are inherited machine-wide, so this test covers the" -ForegroundColor Yellow
  Write-Host "auth, profile, skills and clone paths, but not winget installing them" -ForegroundColor Yellow
  Write-Host "from nothing. Windows Sandbox or a VM is the only way to cover that." -ForegroundColor Yellow
}
if ($scopeUnknown -gt 0) {
  Write-Host ""
  Write-Host "$scopeUnknown tool scope(s) could not be verified, so preflight did not" -ForegroundColor Yellow
  Write-Host "classify them as either per-user or machine-wide." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Next, if the account is clean:"
Write-Host "  irm https://raw.githubusercontent.com/ospina-company/.github/main/install.ps1 | iex"
Write-Host ""
