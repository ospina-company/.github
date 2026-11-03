# Runs install.ps1 end to end, the way `irm ... | iex` does, with stub GitHub,
# WinGet and agent commands and a fixture handbook whose bootstrap.sh records
# how it was called. Proves a re-run finds an existing setup, never prompts for
# a workspace, and hands off with --update; a first run and an older bootstrap
# get no --update. Needs Git for Windows. Changes nothing outside a temp folder.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installer = Get-Content -Raw (Join-Path $root 'install.ps1')
$T = Join-Path ([IO.Path]::GetTempPath()) ("ospina-handoff-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $T | Out-Null
$savedPath = $env:Path
$savedProfile = $env:USERPROFILE
$savedHome = $env:HOME

function Fail($m) { throw "FAIL: $m" }
# A prompt in an automated run would hang. Any prompt is a failure here.
function Read-Host { throw 'install.ps1 prompted for input' }
function Git-Quiet { $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & git @args 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw "git $args failed" } }
  finally { $ErrorActionPreference = $prev } }

try {
  $bin = Join-Path $T 'bin'
  New-Item -ItemType Directory -Force -Path $bin | Out-Null
  foreach ($c in 'winget','vale','t3','claude','codex') {
    Set-Content -Encoding ASCII -Path (Join-Path $bin "$c.cmd") -Value "@echo off`r`nexit /b 0"
  }

  # The fixture origin: its bootstrap.sh writes its arguments beside itself.
  function New-Origin($body) {
    $src = Join-Path $T 'src'; $origin = Join-Path $T 'origin.git'
    Remove-Item -Recurse -Force $src, $origin -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    [IO.File]::WriteAllText((Join-Path $src 'bootstrap.sh'), ($body -replace "`r`n", "`n"))
    Git-Quiet -C $src init -q -b main
    Git-Quiet -C $src add -A
    Git-Quiet -C $src -c user.name=t -c user.email=t@example.com commit -qm fixture
    Git-Quiet clone -q --bare $src $origin
    return $origin
  }
  $current = "#!/bin/sh`n# case `"`$arg`" in --update) UPDATE=1 ;; esac`nprintf '%s\n' `"`$*`" > `"`$(dirname `"`$0`")/args.txt`"`n"
  $older   = "#!/bin/sh`nprintf '%s\n' `"`$*`" > `"`$(dirname `"`$0`")/args.txt`"`n"
  $origin = New-Origin $current

  $ws = Join-Path $T 'Ospina'
  $hb = Join-Path $ws 'handbook'
  function New-Checkout($originPath) {
    Remove-Item -Recurse -Force $hb -ErrorAction SilentlyContinue
    Git-Quiet clone -q $originPath $hb
    Git-Quiet -C $hb remote set-url origin https://github.com/ospina-company/handbook.git
    Git-Quiet -C $hb config "url.$originPath.insteadOf" https://github.com/ospina-company/handbook.git
  }
  function Invoke-Installer {
    $env:Path = "$bin;$savedPath"
    $env:USERPROFILE = Join-Path $T 'home'
    Remove-Item Env:\HOME -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $env:USERPROFILE | Out-Null
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    $out = & ([scriptblock]::Create($installer)) *>&1 | Out-String -Width 8192
    $env:Path = $savedPath
    if ($out -match 'Unexpected error|ERROR:|finished with warnings or errors') { Fail "installer failed:`n$out" }
    return $out
  }
  function Args-Seen { (Get-Content -Raw (Join-Path $hb 'args.txt')).Trim() }

  # gh: signed in, handbook readable, and a clone it can actually make.
  Set-Content -Encoding ASCII -Path (Join-Path $bin 'gh.cmd') -Value @"
@echo off
if "%1 %2"=="repo clone" goto clone
if "%1 %2"=="auth status" exit /b 0
if "%1 %2"=="repo view" exit /b 0
if "%1 %2"=="api user" (echo tester& exit /b 0)
if "%1 %2"=="auth token" (echo test-token& exit /b 0)
exit /b 1
:clone
git clone -q "$origin" "%~4" || exit /b 1
git -C "%~4" remote set-url origin https://github.com/ospina-company/handbook.git || exit /b 1
git -C "%~4" config "url.$origin.insteadOf" https://github.com/ospina-company/handbook.git || exit /b 1
exit /b 0
"@

  # First run, workspace given explicitly: a fresh clone gets no --update.
  $env:OSPINA_WORKSPACE = $ws
  $out = Invoke-Installer
  Remove-Item Env:\OSPINA_WORKSPACE
  if ((Args-Seen) -ne '--no-login') { Fail "first run passed '$(Args-Seen)'" }

  # Re-run, found through the Git Bash profile: no prompt, --update.
  $unix = '/' + $hb.Substring(0, 1).ToLower() + ($hb.Substring(2) -replace '\\', '/')
  Set-Content -Path (Join-Path $env:USERPROFILE '.bashrc') -Value ("export OSPINA_HANDBOOK='{0}'" -f $unix)
  Remove-Item (Join-Path $hb 'args.txt')
  $out = Invoke-Installer
  if ($out -notmatch [regex]::Escape("found your existing setup at $ws")) { Fail "re-run did not find the setup:`n$out" }
  if ($out -match 'Where should the Ospina repositories live') { Fail 're-run asked for a workspace' }
  if ((Args-Seen) -ne '--no-login --update') { Fail "re-run passed '$(Args-Seen)'" }

  # A record naming a stale drive does not stop discovery.
  $state = Join-Path $env:USERPROFILE '.config\ospina-handbook\bootstrap-state'
  New-Item -ItemType Directory -Force -Path $state | Out-Null
  Set-Content -Path (Join-Path $state 'handbook-dir') -Value 'Q:\gone\handbook'
  Remove-Item (Join-Path $hb 'args.txt')
  $out = Invoke-Installer
  if ((Args-Seen) -ne '--no-login --update') { Fail "a stale record broke discovery: '$(Args-Seen)'" }
  Remove-Item (Join-Path $state 'handbook-dir')

  # A handbook that predates --update gets the standard setup.
  $origin = New-Origin $older
  New-Checkout $origin
  $out = Invoke-Installer
  if ((Args-Seen) -ne '--no-login') { Fail "an older bootstrap was given '$(Args-Seen)'" }
  if ($out -notmatch 'this handbook predates updates') { Fail 'the older-bootstrap fallback was not explained' }

  # A workspace path with an apostrophe reaches Git Bash intact.
  $origin = New-Origin $current
  $ws2 = Join-Path $T "O'Brien\Ospina"
  $env:OSPINA_WORKSPACE = $ws2
  $out = Invoke-Installer
  Remove-Item Env:\OSPINA_WORKSPACE
  if (-not (Test-Path -LiteralPath (Join-Path $ws2 'handbook\args.txt'))) { Fail "bootstrap did not run in a workspace with an apostrophe:`n$out" }

  # Found again through the profile line bootstrap wrote, quoting and all.
  $hb2 = Join-Path $ws2 'handbook'
  $unix2 = '/' + $hb2.Substring(0, 1).ToLower() + ($hb2.Substring(2) -replace '\\', '/')
  Set-Content -Path (Join-Path $env:USERPROFILE '.bashrc') -Value ("export OSPINA_HANDBOOK='{0}'" -f ($unix2 -replace "'", "'\''"))
  Remove-Item -LiteralPath (Join-Path $hb2 'args.txt')
  $out = Invoke-Installer
  if ($out -notmatch [regex]::Escape("found your existing setup at $ws2")) { Fail "a profile path with an apostrophe was not found:`n$out" }
  if ((Get-Content -Raw -LiteralPath (Join-Path $hb2 'args.txt')).Trim() -ne '--no-login --update') { Fail 'the apostrophe workspace was not updated' }

  # Brackets are literal: [a] must never resolve to a sibling folder named a.
  $ws3 = Join-Path $T '[a]\Ospina'
  New-Item -ItemType Directory -Force -Path (Join-Path $T 'a\Ospina') | Out-Null
  $env:OSPINA_WORKSPACE = $ws3
  $out = Invoke-Installer
  Remove-Item Env:\OSPINA_WORKSPACE
  if (-not (Test-Path -LiteralPath (Join-Path $ws3 'handbook\args.txt'))) { Fail "bootstrap did not run in a bracketed workspace:`n$out" }
  if (Test-Path -LiteralPath (Join-Path $T 'a\Ospina\handbook')) { Fail 'a bracketed workspace resolved to a sibling folder' }

  Write-Host 'install.ps1 re-runs update an existing setup without prompting'
} finally {
  $env:Path = $savedPath
  $env:USERPROFILE = $savedProfile
  if ($savedHome) { $env:HOME = $savedHome }
  Remove-Item Env:\OSPINA_WORKSPACE -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $T -ErrorAction SilentlyContinue
}
