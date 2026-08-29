# Ospina workspace installer - Windows.
#
#   irm https://raw.githubusercontent.com/ospina-company/.github/main/install.ps1 | iex
#
# Installs Git, GitHub CLI and Vale via winget, signs you in to GitHub, clones
# the handbook, and hands off to handbook/bootstrap.sh running under the Git
# Bash that Git for Windows installs.
#
# Read before running. Safe to re-run: every step checks before it acts.

$ErrorActionPreference = 'Stop'

function Say  ($m) { Write-Host $m }
function Step ($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Die  ($m) { Write-Host ""; Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Have ($c) { $null -ne (Get-Command $c -ErrorAction SilentlyContinue) }

function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User')
}

Say ""
Say "Ospina workspace setup"
Say "You will need a GitHub account that has been added to the ospina-company org."

# ------------------------------------------------------------------ packages
Step "Checking tools"
if (-not (Have winget)) {
  Die "winget is required. Install 'App Installer' from the Microsoft Store, then re-run."
}

$pkgs = @(
  @{ Cmd = 'git';   Id = 'Git.Git';         Required = $true  },
  @{ Cmd = 'gh';    Id = 'GitHub.cli';      Required = $true  },
  @{ Cmd = 'vale';  Id = 'errata-ai.Vale';  Required = $false }
)
foreach ($p in $pkgs) {
  if (Have $p.Cmd) { Say "  ok       $($p.Cmd)"; continue }
  Say "  install  $($p.Cmd)  ($($p.Id))"
  winget install --id $p.Id --silent --accept-package-agreements --accept-source-agreements | Out-Null
  Refresh-Path
  if (-not (Have $p.Cmd) -and $p.Required) {
    Die "$($p.Cmd) did not land on PATH. Close this window, open a new PowerShell, and re-run."
  }
}

# Git Bash is what actually runs the bootstrap script.
$bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
if (-not (Test-Path $bash)) {
  $bash = Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'
}
if (-not (Test-Path $bash)) { Die "Could not find Git Bash (bash.exe) after installing Git." }
Say "  ok       git bash at $bash"

# ---------------------------------------------------------------------- auth
Step "GitHub sign-in"
& gh auth status *> $null
if ($LASTEXITCODE -eq 0) {
  $who = (& gh api user --jq .login 2>$null)
  Say "  ok       signed in as $who"
} else {
  Say "  A browser window will open. Choose GitHub.com, then HTTPS."
  & gh auth login
  if ($LASTEXITCODE -ne 0) { Die "GitHub sign-in did not complete." }
}

& gh repo view ospina-company/handbook --json name *> $null
if ($LASTEXITCODE -ne 0) {
  Die "Your account cannot see ospina-company/handbook. Ask Carlos to add you to the org and grant handbook access, then re-run."
}

# ----------------------------------------------------------------- workspace
Step "Workspace location"
# Keep the root short. Deep client paths still push against Windows path limits
# even with core.longpaths set, and OneDrive-synced folders corrupt .git.
$default = "C:\Ospina"
if ($env:OSPINA_WORKSPACE) {
  $ws = $env:OSPINA_WORKSPACE
  Say "  using OSPINA_WORKSPACE=$ws"
} else {
  $reply = Read-Host "  Where should the repositories live? [$default]"
  $ws = if ([string]::IsNullOrWhiteSpace($reply)) { $default } else { $reply }
}
if ($ws -match 'OneDrive|Dropbox') {
  Say "  WARNING: cloud-synced folders corrupt git repositories. Consider $default instead."
}
New-Item -ItemType Directory -Force -Path $ws | Out-Null
Say "  workspace: $ws"

# ------------------------------------------------------------------ handbook
Step "Handbook"
$hb = Join-Path $ws 'handbook'
if (Test-Path (Join-Path $hb '.git')) {
  Say "  ok       already cloned, updating"
  & git -C $hb pull -q --ff-only 2>$null
} else {
  & gh repo clone ospina-company/handbook $hb -- -q
  if ($LASTEXITCODE -ne 0) { Die "Could not clone the handbook." }
  Say "  cloned   $hb"
}

# ------------------------------------------------------------------- handoff
Step "Running bootstrap"
Say ""
# Convert C:\Ospina\handbook to /c/Ospina/handbook for Git Bash.
$full   = (Resolve-Path $hb).Path
$drive  = $full.Substring(0,1).ToLower()
$rest   = $full.Substring(2) -replace '\\','/'
$hbUnix = "/$drive$rest"
Say "  handbook (git bash path): $hbUnix"
& $bash -lc "sh '$hbUnix/bootstrap.sh'"
