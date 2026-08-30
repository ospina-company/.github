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

function Say  { param([string]$m, [string]$ForegroundColor)
  if ($ForegroundColor) { Write-Host $m -ForegroundColor $ForegroundColor } else { Write-Host $m } }
function Step ($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
# Never call exit in this script. It is run with `irm ... | iex`, which
# evaluates in the caller's session, so exit closes the user's PowerShell window
# and takes every message we just printed with it. Throw, and let the wrapper
# catch and print.
# A sentinel prefix rather than a custom exception class: PowerShell classes are
# resolved at parse time, which behaves inconsistently when the script arrives
# as a string through Invoke-Expression.
$OSPINA_HALT = '[ospina-halt] '
function Die ($m) { throw ($OSPINA_HALT + $m) }
function Have ($c) { $null -ne (Get-Command $c -ErrorAction SilentlyContinue) }

# PowerShell 5.1 turns anything a native command writes to stderr into an error
# record, and with $ErrorActionPreference = 'Stop' that terminates the script
# even when the command only printed a diagnostic. `gh auth status` on a machine
# that is not logged in does exactly that, and it is not a failure: it is the
# answer. Judge native tools by exit code, never by whether they wrote to stderr.
function Invoke-Native-Capture {
  # Same stderr problem, but we want stdout back as a string.
  param([Parameter(Mandatory)][string] $Exe, [string[]] $Arguments = @())
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { return (& $Exe @Arguments 2>$null | Select-Object -First 1) }
  finally { $ErrorActionPreference = $prev }
}

function Invoke-Native {
  param(
    [Parameter(Mandatory)][string] $Exe,
    [string[]] $Arguments = @(),
    [switch]   $Interactive   # leave stdin/stdout attached, e.g. gh auth login
  )
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    # Out-Host, not a bare call. Assigning the result of this function would
    # otherwise capture the child's stdout into the variable instead of showing
    # it, which silently hid every line bootstrap.sh printed. stderr was
    # unaffected, which is why gh's prompts appeared and bash's output did not.
    if ($Interactive) { & $Exe @Arguments | Out-Host }
    else              { & $Exe @Arguments 2>&1 | Out-Null }
    return $LASTEXITCODE
  } finally { $ErrorActionPreference = $prev }
}

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

function Invoke-OspinaInstall {

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
  $code = Invoke-Native winget @('install','--id',$p.Id,'--exact','--silent',
            '--accept-package-agreements','--accept-source-agreements')
  Refresh-Path
  # A managed laptop often blocks machine-wide installs. User scope needs no admin.
  if (-not (Have $p.Cmd)) {
    Say "  retry    $($p.Cmd) with user-scope install (no admin required)"
    $code = Invoke-Native winget @('install','--id',$p.Id,'--exact','--silent',
              '--scope','user','--accept-package-agreements','--accept-source-agreements')
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
$authed = (Invoke-Native gh @('auth','status')) -eq 0
if ($authed) {
  $who = (Invoke-Native-Capture gh @('api','user','--jq','.login'))
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
    return
  }
  Say ""
  Say "  A browser window will open. Choose GitHub.com, then HTTPS, then"
  Say "  'Login with a web browser' and paste the code shown here."
  $rc = Invoke-Native gh @('auth','login') -Interactive
  if ($rc -ne 0) { Die "GitHub sign-in did not complete. Run 'gh auth login' and try again." }
}

$who = (Invoke-Native-Capture gh @('api','user','--jq','.login'))

if ((Invoke-Native gh @('repo','view','ospina-company/handbook','--json','name')) -ne 0) {
  # Distinguish "not in the org" from "in the org, but the team is missing
  # handbook". They need completely different things asked for.
  $inOrg = (Invoke-Native gh @('api',"orgs/ospina-company/members/$who")) -eq 0

  Say ""
  Say "  ------------------------------------------------------------------"
  Say "  You are signed in as: $who"
  Say ""
  if (-not $inOrg) {
    Say "  You are not a member of the ospina-company organization yet."
    Say "  This is expected on a first run. Two steps:"
    Say ""
    Say "    1. Send Carlos your GitHub username:  $who"
    Say "       (hi@ospinacompany.com)"
    Say ""
    Say "    2. He sends an invite. Accept it here:"
    Say "       https://github.com/orgs/ospina-company/invitation"
  } else {
    Say "  You ARE in the ospina-company organization, but your team does not"
    Say "  have access to the 'handbook' repository. Setup cannot continue"
    Say "  without it: handbook holds the conventions, the agent skills and"
    Say "  this bootstrap itself."
    Say ""
    Say "  This is a blocker, not something you can work around."
    Say ""
    Say "  Ask Carlos to add 'handbook' with Read access to your team:"
    Say "    hi@ospinacompany.com"
    Say "    https://github.com/orgs/ospina-company/teams"
  }
  Say ""
  Say "  Then run this same command again and it will finish the setup:"
  Say "    irm https://raw.githubusercontent.com/ospina-company/.github/main/install.ps1 | iex"
  Say "  ------------------------------------------------------------------"
  return
}
Say "  ok       access to Ospina repositories confirmed"

# ------------------------------------------------------------ coding agent
Step "Coding agent"
Say "  T3 Code is the editor this workflow uses. Claude Code and Codex are the"
Say "  agents that run inside it. You need T3 Code and at least one agent."
Say "  You bring your own Claude or Codex subscription; Ospina does not provide one."
Say ""

function Ask-YesNo ($question) {
  # Default yes: this is how the workflow is set up, so the common answer
  # should be the one you get by pressing Enter.
  $a = Read-Host "$question [Y/n]"
  return ([string]::IsNullOrWhiteSpace($a) -or $a -match '^[Yy]')
}

function Test-T3Code {
  if (Have t3) { return $true }
  $paths = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\t3code'),
    (Join-Path $env:LOCALAPPDATA 'Programs\T3 Code'),
    (Join-Path $env:ProgramFiles 'T3 Code')
  )
  foreach ($p in $paths) { if (Test-Path $p) { return $true } }
  # Anything registered as installed under a matching display name.
  foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                   'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -like '*T3 Code*' }
    if ($hit) { return $true }
  }
  return $false
}

function Install-T3Code {
  # Not on winget, so take the signed installer from the project's own
  # GitHub releases. Falls back to the download page if anything goes wrong.
  try {
    Say "          finding the latest T3 Code release..."
    $rel = Invoke-RestMethod 'https://api.github.com/repos/pingdotgg/t3code/releases/latest' `
                             -Headers @{ 'User-Agent' = 'ospina-installer' }
    $asset = $rel.assets | Where-Object { $_.name -like '*x64.exe' } | Select-Object -First 1
    if (-not $asset) { throw 'no Windows installer in the latest release' }
    $out = Join-Path $env:TEMP $asset.name
    Say "          downloading $($asset.name)..."
    Invoke-WebRequest $asset.browser_download_url -OutFile $out -UseBasicParsing
    Say "          running the installer..."
    Start-Process -FilePath $out -ArgumentList '/S' -Wait
    Remove-Item $out -ErrorAction SilentlyContinue
    return $true
  } catch {
    Say "          could not install automatically: $($_.Exception.Message)"
    Say "          opening the download page instead"
    Start-Process 'https://t3.codes/download'
    return $false
  }
}

$agents = @(
  @{ Name = 'T3 Code';     Test = { Test-T3Code };  Install = { Install-T3Code } },
  @{ Name = 'Claude Code'; Test = { Have claude };
     Install = { (Invoke-Native winget @('install','--id','Anthropic.ClaudeCode','--exact','--silent',
                   '--accept-package-agreements','--accept-source-agreements')) -eq 0 } },
  @{ Name = 'Codex';       Test = { Have codex };
     Install = {
       if (Have npm) {
         # Go through cmd. On Windows `npm` resolves to npm.ps1, and a machine
         # on the default Restricted execution policy refuses to run it, which
         # is not something a partner should have to diagnose.
         (Invoke-Native cmd @('/c','npm','install','-g','@openai/codex')) -eq 0
       }
       else {
         Say "          Codex installs through npm, and Node.js is not present."
         Say "          Install Node.js first: winget install OpenJS.NodeJS"
         Say "          then: npm install -g @openai/codex"
         $false
       }
     } }
)

foreach ($a in $agents) {
  if (& $a.Test) { Say ("  ok       {0,-14} already installed" -f $a.Name); continue }
  Say ("  --       {0,-14} not found" -f $a.Name)
  if (-not (Ask-YesNo "           Install $($a.Name)?")) {
    Say  "           skipped. You can re-run this command later and it will offer again."
    continue
  }
  # Installing an agent is optional. A failure here must never take the rest of
  # the setup down with it: the repositories and conventions matter more, and
  # an agent can be installed by hand afterwards.
  try {
    $okAgent = & $a.Install
    Refresh-Path
    if ($okAgent -or (& $a.Test)) { Say ("  ok       {0,-14} installed" -f $a.Name) }
    else { Say ("  note     {0,-14} not installed; a new terminal may be needed" -f $a.Name) }
  } catch {
    Say ("  note     {0,-14} install failed, continuing without it" -f $a.Name)
    Say ("           reason: {0}" -f $_.Exception.Message)
    Say  "           Setup continues. Install it later and re-run this command."
  }
}
Say ""


# ----------------------------------------------------------------- workspace
Step "Workspace location"

# Offer places that already exist and make sense on this machine, rather than
# inventing one path and hoping. A free-text prompt puts the burden on someone
# who has no idea what the constraints are.
function Get-WorkspaceCandidates {
  $home_ = $env:USERPROFILE
  $od    = $env:OneDrive
  $out   = @()

  function Add-Candidate($path, $why, $rank) {
    if (-not $path) { return }
    # OneDrive and Dropbox sync clients write into .git concurrently with git
    # and corrupt repositories. Never offer a synced location.
    if ($od -and $path.StartsWith($od, 'OrdinalIgnoreCase')) { return }
    if ($path -match '(?i)onedrive|dropbox|google drive|box sync') { return }
    $script:cands += [pscustomobject]@{
      Path = $path; Why = $why; Rank = $rank; Exists = (Test-Path $path)
    }
  }

  $script:cands = @()
  # Existing developer folders first: if one of these is here, it is where this
  # person already keeps code.
  foreach ($d in @('Repositories','repos','source\repos','Projects','projects','dev','code','git','Developer')) {
    $full = Join-Path $home_ $d
    if (Test-Path $full) { Add-Candidate (Join-Path $full 'Ospina') "inside your existing $d folder" 10 }
  }
  # A short root on the system drive. Shortest paths, which matters on Windows.
  Add-Candidate 'C:\Ospina' 'short path, avoids Windows path-length limits' 20
  # Home directory.
  Add-Candidate (Join-Path $home_ 'Ospina') 'in your home folder' 30
  # A roomier non-system drive, if one exists.
  Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^[D-Z]$' -and $_.Free -gt 20GB } |
    Sort-Object Free -Descending | Select-Object -First 1 | ForEach-Object {
      Add-Candidate ("{0}:\Ospina" -f $_.Name) ("more free space ({0:N0} GB)" -f ($_.Free/1GB)) 15
    }
  $script:cands | Sort-Object Rank, Path | Group-Object Path | ForEach-Object { $_.Group[0] }
}

if ($env:OSPINA_WORKSPACE) {
  $ws = $env:OSPINA_WORKSPACE
  Say "  using OSPINA_WORKSPACE=$ws"
} else {
  $cands = @(Get-WorkspaceCandidates)
  $sysFree = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue).Free
  if ($sysFree) { Say ("  $($env:SystemDrive) has {0:N0} GB free" -f ($sysFree/1GB)) }
  if ($env:OneDrive) { Say "  OneDrive is active, so synced folders are excluded (they corrupt git)" }
  Say ""
  Say "  Where should the Ospina repositories live?"
  Say ""
  for ($i = 0; $i -lt $cands.Count; $i++) {
    $c = $cands[$i]
    $tag = if ($c.Exists) { "" } else { " (will be created)" }
    Say ("    {0}) {1,-42} {2}{3}" -f ($i+1), $c.Path, $c.Why, $tag)
  }
  Say ("    {0}) somewhere else, type a path" -f ($cands.Count + 1))
  Say ""
  $pick = Read-Host "  Choice [1]"
  if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '1' }

  if ($pick -as [int] -and [int]$pick -ge 1 -and [int]$pick -le $cands.Count) {
    $ws = $cands[[int]$pick - 1].Path
  } elseif ($pick -as [int] -and [int]$pick -eq ($cands.Count + 1)) {
    $ws = Read-Host "  Full path"
    if ([string]::IsNullOrWhiteSpace($ws)) { Die "No path given." }
  } else {
    # Treat anything else as a literal path, so typing one still works.
    $ws = $pick
  }
  $ws = [Environment]::ExpandEnvironmentVariables($ws)
  if ($env:OneDrive -and $ws.StartsWith($env:OneDrive, 'OrdinalIgnoreCase')) {
    Say ""
    Say "  WARNING: that path is inside OneDrive. Sync clients and git both write" 
    Say "  to .git and will eventually corrupt the repositories."
    $ok = Read-Host "  Use it anyway? (y/n)"
    if ($ok -notmatch '^[Yy]') { Die "Pick a path outside OneDrive and run the command again." }
  }
}

New-Item -ItemType Directory -Force -Path $ws | Out-Null
$ws = (Resolve-Path $ws).Path
Say "  workspace: $ws"

Step "Handbook"
$hb = Join-Path $ws 'handbook'
if (Test-Path (Join-Path $hb '.git')) {
  Say "  ok       already cloned, updating"
  $null = Invoke-Native git @('-C',$hb,'pull','-q','--ff-only')
} else {
  if ((Invoke-Native gh @('repo','clone','ospina-company/handbook',$hb,'--','-q')) -ne 0) {
    Die "Could not clone the handbook."
  }
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

# Hand the credential to the child explicitly. Git Bash starts as a login shell
# and its profile sanitises the environment, so gh inside bash cannot always
# find the config it just wrote from PowerShell. Without this, bootstrap.sh sees
# an unauthenticated gh and starts a SECOND interactive login, which cannot
# complete from a nested shell and hangs on
# "please complete authentication in your browser".
$tok = Invoke-Native-Capture gh @('auth','token')
if ($tok) {
  $env:GH_TOKEN = $tok
  Say "  passing your GitHub credential to the bootstrap step"
  Say ""
  Say "  Cloning can take several minutes depending on how many repositories"
  Say "  you have access to. Progress appears below." -ForegroundColor DarkGray
} else {
  Say "  could not read a gh token; the bootstrap step may ask you to sign in again"
}

# --no-login is belt and braces: even if the credential does not survive, the
# child must never start a login it has no way to finish.
try {
  $rc = Invoke-Native $bash @('-lc', "sh '$hbUnix/bootstrap.sh' --no-login") -Interactive
} finally {
  Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
}

} # end Invoke-OspinaInstall

try {
  Invoke-OspinaInstall
}
catch {
  $msg = $_.Exception.Message
  Write-Host ""
  if ($msg -and $msg.StartsWith($OSPINA_HALT)) {
    Write-Host ("ERROR: " + $msg.Substring($OSPINA_HALT.Length)) -ForegroundColor Red
  } else {
    Write-Host "Unexpected error: $msg" -ForegroundColor Red
    Write-Host "  at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray
    Write-Host "  Please send this to Carlos: hi@ospinacompany.com" -ForegroundColor DarkGray
  }
}
finally {
  Write-Host ""
  Write-Host "This window stays open so you can read the output above." -ForegroundColor DarkGray
}
