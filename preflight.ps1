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

# 2. Agent skills
$skills = Join-Path $env:USERPROFILE '.claude\skills'
if (Test-Path $skills) {
  $n = (Get-ChildItem $skills -ErrorAction SilentlyContinue).Count
  if ($n -gt 0) { Line 'DIRTY' 'agent skills' "$skills has $n item(s)"; $dirty++ }
  else { Line 'CLEAN' 'agent skills' 'directory exists but is empty' }
} else { Line 'CLEAN' 'agent skills' 'no ~/.claude/skills' }

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
foreach ($t in 'git','gh','vale','winget','tailscale') {
  if (Have $t) {
    $src = (Get-Command $t).Source
    # A binary under the user profile was installed for this account, so it is
    # not evidence that the machine provides it to everyone.
    # WindowsApps holds app execution aliases, which Windows provides. A binary
    # there sits under the profile but was not installed by this account.
    $isAlias    = $src -and $src -match '(?i)\\Microsoft\\WindowsApps\\'
    $userScoped = $src -and -not $isAlias -and
                  $src.StartsWith($env:USERPROFILE, 'OrdinalIgnoreCase')
    Line 'NOTE' $t ("{0}  [{1}]" -f $src, $(if ($userScoped) { 'this user' } else { 'machine-wide' }))
    if ($t -ne 'winget' -and -not $userScoped) { $inherited++ }
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
Write-Host ""
Write-Host "Next, if the account is clean:"
Write-Host "  irm https://raw.githubusercontent.com/ospina-company/.github/main/install.ps1 | iex"
Write-Host ""
