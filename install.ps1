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
  # winget writes the new PATH to the registry; this session still holds the old
  # one. Rebuild from Machine + User so freshly installed tools are callable now
  # instead of only after a restart.
  $machine = [Environment]::GetEnvironmentVariable('Path','Machine')
  $user    = [Environment]::GetEnvironmentVariable('Path','User')
  $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Find-GitBash {
  # Git for Windows can land in several places depending on whether winget
  # installed it machine-wide or per-user, so do not assume Program Files.
  $candidates = @(
    (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
  )
  # Ask the registry where Git for Windows put itself.
  foreach ($key in @('HKLM:\SOFTWARE\GitForWindows','HKCU:\SOFTWARE\GitForWindows')) {
    try {
      $ip = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallPath
      if ($ip) { $candidates += (Join-Path $ip 'bin\bash.exe') }
    } catch { }
  }
  # Derive it from git.exe if that is on PATH: <root>\cmd\git.exe -> <root>\bin\bash.exe
  $gitCmd = Get-Command git -ErrorAction SilentlyContinue
  if ($gitCmd) {
    $root = Split-Path (Split-Path $gitCmd.Source -Parent) -Parent
    $candidates += (Join-Path $root 'bin\bash.exe')
  }
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { return $c }
  }
  return $null
}

Say ""
Say "Ospina workspace setup"
Say ""

if ($PSVersionTable.PSVersion.Major -lt 5) {
  Die "This needs Windows PowerShell 5.1 or newer. Yours is $($PSVersionTable.PSVersion)."
}
Say "  PowerShell $($PSVersionTable.PSVersion), $([Environment]::OSVersion.VersionString)"

$admin = ([Security.Principal.WindowsPrincipal] `
          [Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  Say "  Running without administrator rights. Tools will install per-user, which is fine."
}

# ------------------------------------------------------------------ packages
Step "Checking tools"
if (-not (Have winget)) {
  Die @"
winget is required and was not found.

winget ships with Windows 10 (2004+) and Windows 11 as part of 'App Installer'.
If it is missing, install App Installer from the Microsoft Store:
  https://apps.microsoft.com/detail/9nblggh4nns1
Then open a new PowerShell and run this command again.
"@
}

$pkgs = @(
  @{ Cmd = 'git';   Id = 'Git.Git';         Required = $true  },
  @{ Cmd = 'gh';    Id = 'GitHub.cli';      Required = $true  },
  @{ Cmd = 'vale';  Id = 'errata-ai.Vale';  Required = $false }
)
foreach ($p in $pkgs) {
  if (Have $p.Cmd) { Say "  ok       $($p.Cmd)"; continue }
  Say "  install  $($p.Cmd)  ($($p.Id))"
  winget install --id $p.Id --exact --silent `
                 --accept-package-agreements --accept-source-agreements | Out-Null
  $code = $LASTEXITCODE
  Refresh-Path
  # A managed laptop often blocks machine-wide installs. User scope needs no admin.
  if (-not (Have $p.Cmd)) {
    Say "  retry    $($p.Cmd) with user-scope install (no admin required)"
    winget install --id $p.Id --exact --silent --scope user `
                   --accept-package-agreements --accept-source-agreements | Out-Null
    $code = $LASTEXITCODE
    Refresh-Path
  }
  if (Have $p.Cmd) {
    Say "  ok       $($p.Cmd) installed"
  } elseif ($p.Required) {
    Die @"
$($p.Cmd) was installed but is not callable in this session (winget exit $code).

Windows does not propagate PATH to already-open terminals. Close this window,
open a new PowerShell, and run the command again. It will skip whatever is
already installed.
"@
  } else {
    Say "  note     $($p.Cmd) not callable yet; a new terminal will pick it up"
  }
}

# Git Bash is what actually runs the bootstrap script.
$bash = Find-GitBash
if (-not $bash) {
  Die @"
Could not find Git Bash (bash.exe) after installing Git.

This usually means Git was installed but this PowerShell session still has the
old PATH. Close this window, open a new PowerShell, and run the command again.
If it still fails, install Git for Windows manually from https://git-scm.com/download/win
"@
}
Say "  ok       git bash at $bash"

# ---------------------------------------------------------------------- auth
Step "GitHub sign-in"
& gh auth status *> $null
if ($LASTEXITCODE -eq 0) {
  $who = (& gh api user --jq .login 2>$null)
  Say "  ok       signed in as $who"
} else {
  Say "  You need a GitHub account for this. It is free."
  Say ""
  $hasAcct = Read-Host "  Do you already have a GitHub account? (y/n)"
  if ($hasAcct -notmatch '^[Yy]') {
    Say ""
    Say "  Opening the GitHub signup page. Create the account, then come back"
    Say "  here and run this same command again."
    Start-Process "https://github.com/signup"
    Say ""
    Say "  Command to re-run:"
    Say "    irm https://raw.githubusercontent.com/ospina-company/.github/main/install.ps1 | iex"
    exit 0
  }
  Say ""
  Say "  A browser window will open. Choose GitHub.com, then HTTPS, then"
  Say "  'Login with a web browser' and paste the code shown here."
  & gh auth login
  if ($LASTEXITCODE -ne 0) { Die "GitHub sign-in did not complete. Run 'gh auth login' and try again." }
}

$who = (& gh api user --jq .login 2>$null)

& gh repo view ospina-company/handbook --json name *> $null
if ($LASTEXITCODE -ne 0) {
  Say ""
  Say "  ------------------------------------------------------------------"
  Say "  You are signed in as: $who"
  Say ""
  Say "  That account does not have access to Ospina's repositories yet."
  Say "  This is expected the first time. Two steps:"
  Say ""
  Say "    1. Send Carlos your GitHub username:  $who"
  Say "       (hi@ospinacompany.com)"
  Say ""
  Say "    2. He sends an invite. Accept it here:"
  Say "       https://github.com/orgs/ospina-company/invitation"
  Say ""
  Say "  Then run this same command again and it will finish the setup:"
  Say "    irm https://raw.githubusercontent.com/ospina-company/.github/main/install.ps1 | iex"
  Say "  ------------------------------------------------------------------"
  exit 0
}
Say "  ok       access to Ospina repositories confirmed"

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
