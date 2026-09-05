# Ospina workspace installer - Windows.
#
#   irm https://raw.githubusercontent.com/ospina-company/.github/main/install.ps1 | iex
#
# Installs the workstation baseline via winget (Git, Node 24, Python 3.12 and
# document tools), signs you in to GitHub, clones the handbook, and hands off
# to handbook/bootstrap.sh under the Git Bash that Git for Windows installs.
#
# Read before running. Safe to re-run: every step checks before it acts.

# Saved and restored in the wrapper: this evaluates in the caller's session,
# so leaving their preference changed is a side effect they did not ask for.
$OspinaPrevEAP = $ErrorActionPreference
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
function Get-RemoteFile {
  # Invoke-WebRequest renders a progress bar per chunk, and in Windows
  # PowerShell 5.x that costs roughly a factor of ten on a large file
  # (PowerShell/PowerShell#2138, fixed only in 6.0). Suppress it and report
  # progress ourselves, so the download is fast and the reader still knows
  # what is happening.
  param(
    [Parameter(Mandatory)][string]$Uri,
    [Parameter(Mandatory)][string]$OutFile,
    [string]$Label = 'file',
    [int]$SizeMB = 0
  )
  $prev = $ProgressPreference
  $ProgressPreference = 'SilentlyContinue'
  try {
    if ($SizeMB -gt 0) { Say ("          downloading {0} ({1} MB)..." -f $Label, $SizeMB) }
    else               { Say ("          downloading {0}..." -f $Label) }
    $t0 = Get-Date
    Invoke-WebRequest $Uri -OutFile $OutFile -UseBasicParsing
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    $mb = [int]((Get-Item $OutFile).Length / 1MB)
    Say ("          downloaded {0} MB in {1}s" -f $mb, $secs)
  } finally { $ProgressPreference = $prev }
}

function Invoke-VerifiedInstallerScript {
  # Hold the file open without write/delete sharing from hashing until the
  # child exits. The child reads the same immutable file object we authenticated,
  # while its own PowerShell process contains any vendor `exit` statements.
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$ExpectedDigest,
    [Parameter(Mandatory)][string]$Label
  )
  $installerStream = [IO.File]::Open(
    $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
      $actual = ([BitConverter]::ToString(
        $sha256.ComputeHash($installerStream))).Replace('-','').ToLowerInvariant()
    } finally { $sha256.Dispose() }
    if ($actual -ne $ExpectedDigest) {
      throw "$Label digest changed; Platform must review the new installer"
    }

    $powerShellName = if ($PSVersionTable.PSEdition -eq 'Core') {
      'pwsh.exe'
    } else {
      'powershell.exe'
    }
    $powershell = Join-Path $PSHOME $powerShellName
    if (-not (Test-Path $powershell -PathType Leaf)) {
      throw "$Label cannot run because the current PowerShell executable was not found"
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $Path 2>&1 | Out-Host
      return $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
  } finally { $installerStream.Dispose() }
}

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
  param(
    [string]$MachinePath = [Environment]::GetEnvironmentVariable('Path','Machine'),
    [string]$UserPath = [Environment]::GetEnvironmentVariable('Path','User')
  )
  # Merge, do not replace. A tool that added itself to this process's PATH only
  # would otherwise disappear the moment we rebuild from the registry.
  # winget writes the new PATH to the registry; this session still holds the old
  # one. Rebuild from Machine + User so freshly installed tools are callable now
  # instead of only after a restart. Keep the current process first: helpers may
  # already have promoted a capability-verified user tool over an obsolete
  # machine-scoped copy, and a later refresh must not undo that repair.
  $merged = @($env:Path, $UserPath, $MachinePath) | Where-Object { $_ } |
            ForEach-Object { $_ -split ';' } | Where-Object { $_ } |
            Select-Object -Unique
  $env:Path = ($merged -join ';')
}

function Find-GitBash {
  # Git for Windows can land in several places depending on whether winget
  # installed it machine-wide or per-user, so do not assume Program Files.
  # ProgramFiles(x86) does not exist on every edition, and Join-Path on a null
  # root throws rather than returning nothing.
  $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
  $candidates = @()
  foreach ($r in $roots) { $candidates += (Join-Path $r 'Git\bin\bash.exe') }
  if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe') }
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

# ---------------------------------------------------------------------
# All helpers are defined here, above the wrapper. PowerShell executes
# function definitions in order, so a helper defined further down the
# file does not exist yet when earlier code calls it.
# ---------------------------------------------------------------------

function Ask-YesNo ($question) {
  # Default yes: this is how the workflow is set up, so the common answer should
  # be the one you get by pressing Enter.
  $a = Read-Host "$question [Y/n]"
  return ([string]::IsNullOrWhiteSpace($a) -or $a -match '^[Yy]')
}
function Test-Npm {
  # Get-Command finding npm proves a file exists, not that npm runs. Resolve the
  # .cmd next to the active Node installation so the default Restricted policy
  # cannot select npm.ps1 and cmd.exe cannot select a file in the current repo.
  $npm = Get-NodeToolPath 'npm'
  if (-not $npm) { return $false }
  return (Invoke-Native $npm @('--version')) -eq 0
}
function Get-NodeMajor {
  $version = Invoke-Native-Capture node @('--version')
  if ($version -match '^v?([0-9]+)\.') { return $Matches[1] }
  return $null
}
function Get-PythonMinor {
  $version = Invoke-Native-Capture python @('--version')
  if ($version -match '^Python\s+([0-9]+\.[0-9]+)\.') { return $Matches[1] }
  return $null
}
function Get-NodeToolDirectories {
  # Do not ask cmd.exe to find npm/corepack: cmd searches the current working
  # directory before PATH, so running setup from a checkout containing npm.cmd
  # would execute repository code. Derive tools from the active node.exe and
  # WinGet's per-user portable-package directory instead.
  $dirs = @()
  $node = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue |
          Select-Object -First 1
  if ($node -and $node.Source) {
    $dirs += (Split-Path $node.Source -Parent)
    try {
      $item = Get-Item $node.Source -Force -ErrorAction Stop
      foreach ($target in @($item.Target)) {
        if (-not $target) { continue }
        $resolvedTarget = $target
        if (-not [IO.Path]::IsPathRooted($resolvedTarget)) {
          $resolvedTarget = Join-Path (Split-Path $node.Source -Parent) $resolvedTarget
        }
        $resolvedTarget = [IO.Path]::GetFullPath($resolvedTarget)
        $dirs += (Split-Path $resolvedTarget -Parent)
      }
    } catch { }
  }
  $wingetPackages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
  if (Test-Path $wingetPackages) {
    Get-ChildItem $wingetPackages -Directory -Filter 'OpenJS.NodeJS.LTS_*' `
      -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
      ForEach-Object {
        # The non-admin WinGet fallback is a portable archive. Its package root
        # contains node-v24.x-win-<arch>\node.exe rather than node.exe directly.
        # Find only directories that carry both Node and its matching npm shim.
        Get-ChildItem $_.FullName -File -Filter 'node.exe' -Recurse `
          -ErrorAction SilentlyContinue | ForEach-Object {
            $candidateDir = Split-Path $_.FullName -Parent
            if (Test-Path (Join-Path $candidateDir 'npm.cmd')) {
              $dirs += $candidateDir
            }
          }
      }
  }
  return @($dirs | Where-Object { $_ } | Select-Object -Unique)
}
function Get-NodeToolPath ($Name) {
  foreach ($dir in (Get-NodeToolDirectories)) {
    $candidate = Join-Path $dir ($Name + '.cmd')
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}
function Resolve-NodeToolchainPath {
  foreach ($dir in (Get-NodeToolDirectories)) {
    $nodeExe = Join-Path $dir 'node.exe'
    $npmCmd = Join-Path $dir 'npm.cmd'
    if ((Test-Path $nodeExe) -and (Test-Path $npmCmd)) {
      $version = Invoke-Native-Capture $nodeExe @('--version')
      if ($version -notmatch '^v?24\.') { continue }
      Add-UserPathEntry $dir
      return $true
    }
  }
  return $false
}
function Invoke-NodeToolCapture ($Name, [string[]] $Arguments = @()) {
  $tool = Get-NodeToolPath $Name
  if (-not $tool) { return $null }
  return (Invoke-Native-Capture $tool $Arguments)
}
function Get-CorepackPath {
  $tool = Get-NodeToolPath 'corepack'
  if ($tool) { return $tool }

  # A per-user `npm install -g corepack` writes its command shim to npm's
  # global prefix, which need not be beside node.exe or inside WinGet's package
  # directory. Resolve npm itself by trusted absolute path, then inspect only
  # the prefix npm reports.
  $prefix = Invoke-NodeToolCapture 'npm' @('prefix','-g')
  if ($prefix) {
    $candidate = Join-Path $prefix 'corepack.cmd'
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}
function Test-UvDefaultInstall ([string] $UvExe = 'uv') {
  if ($UvExe -eq 'uv' -and -not (Have uv)) { return $false }
  if ($UvExe -ne 'uv' -and -not (Test-Path $UvExe)) { return $false }
  # clap exits successfully on --help before it validates preview-feature names.
  # Follow the help check with a real parse against an impossible directory.
  # The temporary file makes that directory impossible and prevents any Python
  # download or user-state change.
  $prev = $ErrorActionPreference
  $probeFile = $null
  $hadInstallDir = Test-Path Env:\UV_PYTHON_INSTALL_DIR
  $hadBinDir = Test-Path Env:\UV_PYTHON_BIN_DIR
  $previousInstallDir = if ($hadInstallDir) { $env:UV_PYTHON_INSTALL_DIR } else { $null }
  $previousBinDir = if ($hadBinDir) { $env:UV_PYTHON_BIN_DIR } else { $null }
  $ErrorActionPreference = 'Continue'
  try {
    & $UvExe python install --default --preview-features `
      python-install-default --help *> $null
    if ($LASTEXITCODE -ne 0) { return $false }

    $probeFile = [IO.Path]::GetTempFileName()
    $env:UV_PYTHON_INSTALL_DIR = Join-Path $probeFile 'install'
    $env:UV_PYTHON_BIN_DIR = Join-Path $probeFile 'bin'
    $probeOutput = (& $UvExe python install ospina-capability-probe-invalid `
      --default --preview-features python-install-default --offline `
      --no-python-downloads 2>&1 | Out-String)
    $probeRc = $LASTEXITCODE
    return ($probeRc -ne 0 -and
            $probeOutput -notmatch '(?i)preview-features|python-install-default')
  } catch {
    return $false
  } finally {
    if ($hadInstallDir) { $env:UV_PYTHON_INSTALL_DIR = $previousInstallDir }
    else { Remove-Item Env:\UV_PYTHON_INSTALL_DIR -ErrorAction SilentlyContinue }
    if ($hadBinDir) { $env:UV_PYTHON_BIN_DIR = $previousBinDir }
    else { Remove-Item Env:\UV_PYTHON_BIN_DIR -ErrorAction SilentlyContinue }
    if ($probeFile) { Remove-Item $probeFile -Force -ErrorAction SilentlyContinue }
    $ErrorActionPreference = $prev
  }
}
function Get-UvCandidatePaths {
  $paths = @()
  $active = Get-Command uv.exe -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
  if ($active -and $active.Source) { $paths += $active.Source }
  if ($env:USERPROFILE) { $paths += (Join-Path $env:USERPROFILE '.local\bin\uv.exe') }
  if ($env:LOCALAPPDATA) {
    $packages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path $packages) {
      Get-ChildItem $packages -Directory -Filter 'astral-sh.uv_*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | ForEach-Object {
          $candidate = Get-ChildItem $_.FullName -File -Filter 'uv.exe' -Recurse `
                         -ErrorAction SilentlyContinue | Select-Object -First 1
          if ($candidate) { $paths += $candidate.FullName }
        }
    }
  }
  return @($paths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)
}
function Resolve-UvOnPath {
  foreach ($candidate in (Get-UvCandidatePaths)) {
    if (Test-UvDefaultInstall $candidate) {
      Add-UserPathEntry (Split-Path $candidate -Parent)
      return $true
    }
  }
  return $false
}
function Install-CodexOfficial {
  # Keep vendor installation logic with OpenAI. Their supported PowerShell
  # installer selects the right Windows architecture and install location.
  $tempInstaller = $null
  try {
    Say "          running OpenAI's official Codex installer..."
    # Reviewed on 2026-08-31. The official endpoint is mutable, so authenticate
    # the content before executing it and fail closed on an upstream change.
    $expectedCodexDigest = '391f247de2c70c7e99041979ec02dae7e76be27ac9cfc1dfe7c1eb21d48d8b97'
    $tempInstaller = Join-Path ([IO.Path]::GetTempPath()) `
      ("ospina-codex-install-{0}.ps1" -f [IO.Path]::GetRandomFileName())
    Get-RemoteFile -Uri 'https://chatgpt.com/codex/install.ps1' -OutFile $tempInstaller `
                   -Label 'OpenAI Codex installer'
    $rc = Invoke-VerifiedInstallerScript -Path $tempInstaller `
      -ExpectedDigest $expectedCodexDigest -Label 'OpenAI Codex installer'
    if ($rc -ne 0) { throw "OpenAI Codex installer exited with code $rc" }
    Refresh-Path
    $null = Resolve-OnPath -Command 'codex' -Directories @(
      (Join-Path $env:USERPROFILE '.local\bin'),
      (Join-Path $env:USERPROFILE '.codex\bin')
    )
    return $true
  } catch {
    Say ("          official install failed: {0}" -f $_.Exception.Message)
    Say  "          Install manually: https://learn.chatgpt.com/docs/codex/cli"
    return $false
  } finally {
    if ($tempInstaller -and (Test-Path $tempInstaller)) {
      Remove-Item $tempInstaller -Force -ErrorAction SilentlyContinue
    }
  }
}
function Install-ClaudeOfficial {
  # Use the native installer so T3 Code can call Claude's native updater. A
  # WinGet-managed install lands outside that update path.
  $tempInstaller = $null
  try {
    Say "          running Anthropic's official native installer..."
    # Reviewed on 2026-09-04. The endpoint is mutable, so authenticate the
    # downloaded bytes before executing them and fail closed on a change.
    $expectedClaudeDigest = 'cd17c6b555f761d60373659824bf805e1510538226e4c7028e19d7494937a333'
    $tempInstaller = Join-Path ([IO.Path]::GetTempPath()) `
      ("ospina-claude-install-{0}.ps1" -f [IO.Path]::GetRandomFileName())
    Get-RemoteFile -Uri 'https://claude.ai/install.ps1' -OutFile $tempInstaller `
                   -Label 'Anthropic Claude installer'
    $rc = Invoke-VerifiedInstallerScript -Path $tempInstaller `
      -ExpectedDigest $expectedClaudeDigest -Label 'Anthropic Claude installer'
    if ($rc -ne 0) { throw "Anthropic Claude installer exited with code $rc" }
    Refresh-Path
    $null = Resolve-OnPath -Command 'claude' -Directories @(
      (Join-Path $env:USERPROFILE '.local\bin')
    )
    return (Test-Claude)
  } catch {
    Say ("          native install failed: {0}" -f $_.Exception.Message)
    Say  "          Fallback: winget install Anthropic.ClaudeCode"
    Say  "          (note: a winget install cannot be updated from T3 Code)"
    return $false
  } finally {
    if ($tempInstaller -and (Test-Path $tempInstaller)) {
      Remove-Item $tempInstaller -Force -ErrorAction SilentlyContinue
    }
  }
}
function Resolve-OnPath {
  # A tool that exists but is not callable is a PATH problem, and the installer
  # knows where it put things. Fix it here rather than telling the reader to
  # open a new terminal and hope.
  param(
    [Parameter(Mandatory)][string] $Command,
    [Parameter(Mandatory)][string[]] $Directories
  )
  if (Have $Command) { return $true }
  foreach ($dir in ($Directories | Where-Object { $_ })) {
    foreach ($ext in @('.exe','.cmd','.ps1','')) {
      if (Test-Path (Join-Path $dir ($Command + $ext))) {
        Add-UserPathEntry $dir
        Say ("          added {0} to your PATH" -f $dir)
        return (Have $Command)
      }
    }
  }
  return $false
}
function Get-ClaudeNativePath {
  if (-not $env:USERPROFILE) { return $null }
  $p = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
  if (Test-Path $p) { return $p }
  return $null
}
function Test-Claude {
  # The native installer writes ~/.local/bin/claude.exe and adds that folder to
  # the user PATH, but the running session does not always pick it up. Check the
  # known location too, or a good install looks like a failed one.
  if (Have claude) { return $true }
  return ($null -ne (Get-ClaudeNativePath))
}
function Add-UserPathEntry {
  param([Parameter(Mandatory)][string]$Dir)
  # Read and write the raw registry value so an employee's REG_EXPAND_SZ Path
  # retains both its value kind and expressions such as %USERPROFILE%.
  $userEnvironmentKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
  if (-not $userEnvironmentKey) { Die 'The current-user Environment registry key is unavailable.' }
  try {
    $pathExists = $userEnvironmentKey.GetValueNames() -contains 'Path'
    $userPathKind = if ($pathExists) {
      $userEnvironmentKey.GetValueKind('Path')
    } else { [Microsoft.Win32.RegistryValueKind]::String }
    if ($userPathKind -notin @([Microsoft.Win32.RegistryValueKind]::String,
                               [Microsoft.Win32.RegistryValueKind]::ExpandString)) {
      Die "The current-user Path has unsupported registry kind '$userPathKind'. Ask your device administrator to repair it, then re-run."
    }
    $userPath = if ($pathExists) {
      [string]$userEnvironmentKey.GetValue(
        'Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } else { '' }
    $userParts = @($userPath -split ';' | Where-Object {
      $_ -and -not [string]::Equals($_, $Dir, [StringComparison]::OrdinalIgnoreCase)
    })
    $userEnvironmentKey.SetValue(
      'Path', ((@($Dir) + $userParts) -join ';'), $userPathKind)
  } finally {
    $userEnvironmentKey.Dispose()
  }

  # Windows creates a new process PATH as machine entries followed by user
  # entries. A per-user Node/Python/uv install therefore cannot outrank an old
  # machine-scoped copy through HKCU\Environment\Path alone. Keep a separate
  # reviewed list and have the two shells used by T3 Code promote it at startup.
  $preferredPath = [Environment]::GetEnvironmentVariable('OSPINA_PREFERRED_PATH','User')
  $preferredParts = @($preferredPath -split ';' | Where-Object {
    $_ -and -not [string]::Equals($_, $Dir, [StringComparison]::OrdinalIgnoreCase)
  })
  $preferredPath = ((@($Dir) + $preferredParts) -join ';')
  [Environment]::SetEnvironmentVariable('OSPINA_PREFERRED_PATH', $preferredPath, 'User')
  $env:OSPINA_PREFERRED_PATH = $preferredPath
  $stateDir = Join-Path $env:USERPROFILE '.ospina'
  New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
  [IO.File]::WriteAllText((Join-Path $stateDir 'preferred-path'), $preferredPath,
                          (New-Object Text.UTF8Encoding($false)))
  Install-OspinaPathProfiles

  $processParts = @($env:Path -split ';' | Where-Object {
    $_ -and -not [string]::Equals($_, $Dir, [StringComparison]::OrdinalIgnoreCase)
  })
  $env:Path = ((@($Dir) + $processParts) -join ';')
}
function Find-ByteSequence {
  param(
    [byte[]]$Bytes,
    [byte[]]$Needle,
    [int]$StartAt = 0,
    [ValidateRange(1, 2)][int]$Alignment = 1,
    [int]$AlignmentOffset = 0
  )
  if (-not $Bytes -or -not $Needle -or $Needle.Length -gt $Bytes.Length) { return -1 }
  for ($i = [Math]::Max(0, $StartAt); $i -le $Bytes.Length - $Needle.Length; $i++) {
    if ((($i - $AlignmentOffset) % $Alignment) -ne 0) { continue }
    $matched = $true
    for ($j = 0; $j -lt $Needle.Length; $j++) {
      if ($Bytes[$i + $j] -ne $Needle[$j]) { $matched = $false; break }
    }
    if ($matched) { return $i }
  }
  return -1
}
function Add-OspinaProfileBlock {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Start,
    [Parameter(Mandatory)][string]$End,
    [Parameter(Mandatory)][string]$Block,
    [switch]$PowerShellProfile
  )
  $parent = Split-Path $Path -Parent
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

  # Never decode and rewrite an employee's profile: doing so can change its
  # encoding, line endings, BOM, or non-ASCII text. Detect the existing encoding
  # only so the ASCII block is appended in the same representation.
  $bytes = if (Test-Path $Path) { [IO.File]::ReadAllBytes($Path) } else { [byte[]]@() }
  $encoding = $null
  $preambleLength = 0
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $encoding = New-Object Text.UTF8Encoding($true); $preambleLength = 3
  } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    $encoding = [Text.Encoding]::Unicode; $preambleLength = 2
  } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
    $encoding = [Text.Encoding]::BigEndianUnicode; $preambleLength = 2
  } elseif ($PowerShellProfile -and $bytes.Length -eq 0) {
    # Windows PowerShell 5.1 needs a BOM to identify UTF-8 reliably.
    $encoding = New-Object Text.UTF8Encoding($true)
  } elseif ($PowerShellProfile) {
    # A BOM-less Windows PowerShell 5.1 profile uses the active ANSI code page.
    $encoding = [Text.Encoding]::Default
  } else {
    $encoding = New-Object Text.UTF8Encoding($false)
  }
  $searchAlignment = if ($encoding.CodePage -in @(1200, 1201)) { 2 } else { 1 }

  $existingText = if ($bytes.Length -gt $preambleLength) {
    $encoding.GetString($bytes, $preambleLength, $bytes.Length - $preambleLength)
  } else { '' }
  $blockBytes = $encoding.GetBytes($Block.Trim())
  if ((Find-ByteSequence -Bytes $bytes -Needle $blockBytes -StartAt $preambleLength `
                         -Alignment $searchAlignment -AlignmentOffset $preambleLength) -ge 0) {
    return
  }

  if ($PowerShellProfile -and (Test-Path $Path)) {
    try {
      $signature = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
    } catch {
      Say ("  note     The PowerShell signature on '{0}' could not be checked safely." -f $Path)
      Say  "           Ask your device administrator to add OSPINA_PREFERRED_PATH at the start of PATH."
      return
    }
    if (-not $signature -or [string]$signature.Status -ne 'NotSigned') {
      Say ("  note     The signed PowerShell profile '{0}' was not changed." -f $Path)
      Say  "           Ask your device administrator to add OSPINA_PREFERRED_PATH at the start of PATH."
      return
    }
  }

  $startBytes = $encoding.GetBytes($Start)
  $endBytes = $encoding.GetBytes($End)
  $startIndex = Find-ByteSequence -Bytes $bytes -Needle $startBytes -StartAt $preambleLength `
                                  -Alignment $searchAlignment -AlignmentOffset $preambleLength
  $endIndex = if ($startIndex -ge 0) {
    Find-ByteSequence -Bytes $bytes -Needle $endBytes `
                      -StartAt ($startIndex + $startBytes.Length) `
                      -Alignment $searchAlignment -AlignmentOffset $preambleLength
  } else { -1 }
  if ($startIndex -ge 0 -and $endIndex -lt 0) {
    Die "The managed Ospina block in '$Path' is incomplete. Restore its closing marker, then re-run."
  }

  $managedBytes = $encoding.GetBytes($Block.Trim() + "`n")
  if ($startIndex -ge 0) {
    # Replace only the bytes between Ospina's markers. Every user-owned byte
    # before and after the managed block remains byte-for-byte identical.
    $afterIndex = $endIndex + $endBytes.Length
    $before = if ($startIndex -gt 0) { [byte[]]$bytes[0..($startIndex - 1)] } else { [byte[]]@() }
    $after = if ($afterIndex -lt $bytes.Length) {
      [byte[]]$bytes[$afterIndex..($bytes.Length - 1)]
    } else { [byte[]]@() }
    $combined = [byte[]]@($before + $managedBytes + $after)
    [IO.File]::WriteAllBytes($Path, $combined)
    return
  }

  $prefix = if ($existingText -and -not $existingText.EndsWith("`n") -and
                -not $existingText.EndsWith("`r")) { "`n" } else { '' }
  $appendBytes = $encoding.GetBytes($prefix + $Block.Trim() + "`n")
  $preamble = if ($bytes.Length -eq 0) { $encoding.GetPreamble() } else { [byte[]]@() }
  # PowerShell 5.1 collapses an empty [byte[]] to $null; concatenation tolerates
  # that representation while preserving every original byte in order.
  $combined = [byte[]]@($bytes + $preamble + $appendBytes)
  [IO.File]::WriteAllBytes($Path, $combined)
}
function Test-OspinaOnlyProfile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Start,
    [Parameter(Mandatory)][string]$End
  )
  if (-not (Test-Path $Path)) { return $false }
  try { $text = [IO.File]::ReadAllText($Path) } catch { return $false }
  $pattern = '^\s*' + [regex]::Escape($Start) + '.*?' +
             [regex]::Escape($End) + '\s*$'
  return [regex]::IsMatch($text, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
}
function Install-OspinaPathProfiles {
  # PowerShell 5.1 and PowerShell 7 use different profile directories. Write
  # the same small marked block to both, plus Git Bash's login profile.
  $start = '# >>> ospina workstation PATH >>>'
  $end = '# <<< ospina workstation PATH <<<'
  $powerShellBlock = @'
# >>> ospina workstation PATH >>>
$ospinaPreferredPath = [Environment]::GetEnvironmentVariable('OSPINA_PREFERRED_PATH','User')
if ($ospinaPreferredPath) {
  $ospinaPreferredParts = @($ospinaPreferredPath -split ';' | Where-Object { $_ })
  $ospinaCurrentParts = @($env:Path -split ';' | Where-Object {
    $_ -and $_ -notin $ospinaPreferredParts
  })
  $env:Path = (($ospinaPreferredParts + $ospinaCurrentParts) -join ';')
}
# <<< ospina workstation PATH <<<
'@
  $documents = [Environment]::GetFolderPath('MyDocuments')
  if (-not $documents) { $documents = Join-Path $env:USERPROFILE 'Documents' }
  foreach ($profilePath in @(
    (Join-Path $documents 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $documents 'PowerShell\Microsoft.PowerShell_profile.ps1')
  )) {
    Add-OspinaProfileBlock -Path $profilePath -Start $start -End $end `
                           -Block $powerShellBlock -PowerShellProfile
  }

  $bashBlock = @'
# >>> ospina workstation PATH >>>
_ospina_preferred_windows_path=
if [ -r "$HOME/.ospina/preferred-path" ]; then
  IFS= read -r _ospina_preferred_windows_path < "$HOME/.ospina/preferred-path" || true
fi
if [ -z "$_ospina_preferred_windows_path" ]; then
  _ospina_preferred_windows_path=${OSPINA_PREFERRED_PATH:-}
fi
if [ -n "$_ospina_preferred_windows_path" ]; then
  _ospina_preferred_path=$(cygpath -p "$_ospina_preferred_windows_path" 2>/dev/null || true)
  if [ -n "$_ospina_preferred_path" ]; then
    _ospina_current_path=
    _ospina_old_ifs=$IFS
    IFS=:
    for _ospina_current_part in $PATH; do
      _ospina_duplicate=
      for _ospina_preferred_part in $_ospina_preferred_path; do
        if [ "$_ospina_current_part" = "$_ospina_preferred_part" ]; then
          _ospina_duplicate=1
          break
        fi
      done
      if [ -z "$_ospina_duplicate" ]; then
        _ospina_current_path=${_ospina_current_path:+$_ospina_current_path:}$_ospina_current_part
      fi
    done
    IFS=$_ospina_old_ifs
    PATH=$_ospina_preferred_path${_ospina_current_path:+:$_ospina_current_path}
    export PATH
  fi
fi
unset _ospina_current_part _ospina_current_path _ospina_duplicate _ospina_old_ifs
unset _ospina_preferred_part _ospina_preferred_path _ospina_preferred_windows_path
# <<< ospina workstation PATH <<<
'@
  $bashProfiles = @('.bash_profile','.bash_login','.profile') |
                  ForEach-Object { Join-Path $env:USERPROFILE $_ }
  # The pre-2026-08-31 installer always created .bash_profile. If that file
  # contains only our managed block and hides an employee's older login file,
  # remove our obsolete file so Bash can read the employee's original one.
  if ((Test-OspinaOnlyProfile -Path $bashProfiles[0] -Start $start -End $end) -and
      ((Test-Path $bashProfiles[1]) -or (Test-Path $bashProfiles[2]))) {
    Remove-Item $bashProfiles[0] -Force
  }
  $bashProfile = $bashProfiles | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $bashProfile) { $bashProfile = $bashProfiles[0] }
  Add-OspinaProfileBlock -Path $bashProfile -Start $start -End $end -Block $bashBlock
  $bashRc = Join-Path $env:USERPROFILE '.bashrc'
  if (-not [string]::Equals($bashRc, $bashProfile, [StringComparison]::OrdinalIgnoreCase)) {
    Add-OspinaProfileBlock -Path $bashRc -Start $start -End $end -Block $bashBlock
  }
}
function Test-Codex {
  if (Have codex) { return $true }
  # npm global installs land in a prefix that is not always on PATH, and a tool
  # that exists but cannot be found would otherwise be reinstalled every run.
  $prefix = Invoke-NodeToolCapture 'npm' @('prefix','-g')
  if ($prefix) {
    foreach ($n in @('codex.cmd','codex.ps1','codex')) {
      if (Test-Path (Join-Path $prefix $n)) { return $true }
    }
  }
  foreach ($p in @((Join-Path $env:USERPROFILE '.local\bin\codex.exe'),
                   (Join-Path $env:USERPROFILE '.codex\bin\codex.exe'))) {
    if (Test-Path $p) { return $true }
  }
  return $false
}
function Test-T3Code {
  if (Have t3) { return $true }
  $paths = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\t3code'),
    (Join-Path $env:LOCALAPPDATA 'Programs\T3 Code'),
    (Join-Path $env:ProgramFiles 'T3 Code')
  )
  foreach ($p in $paths) {
    if (-not (Test-Path $p -PathType Container)) { continue }
    $executable = Get-ChildItem -LiteralPath $p -File -Filter '*.exe' -Recurse `
      -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like 'T3 Code*.exe' -or $_.Name -eq 't3code.exe'
      } | Select-Object -First 1
    if ($executable) { return $true }
  }
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
  # T3 Code now publishes an official winget package. Use its package manifest,
  # pinned digest and upgrade path instead of scraping the latest release.
  try {
    $rc = Invoke-Native winget @('install','--id','T3Tools.T3Code','--exact','--source','winget','--silent',
            '--disable-interactivity','--accept-package-agreements','--accept-source-agreements') -Interactive
    Refresh-Path
    return ($rc -eq 0 -or (Test-T3Code))
  } catch {
    Say "          could not install automatically: $($_.Exception.Message)"
    Say "          opening the download page instead"
    Start-Process 'https://t3.codes/download'
    return $false
  }
}
function Get-LibreOfficeDirectories {
  $dirs = @()
  if ($env:ProgramFiles) { $dirs += (Join-Path $env:ProgramFiles 'LibreOffice\program') }
  if (${env:ProgramFiles(x86)}) {
    $dirs += (Join-Path ${env:ProgramFiles(x86)} 'LibreOffice\program')
  }
  if ($env:LOCALAPPDATA) {
    $dirs += (Join-Path $env:LOCALAPPDATA 'Programs\LibreOffice\program')
  }
  return $dirs
}
function Ensure-LibreOffice {
  if (-not (Have soffice)) {
    $null = Resolve-OnPath -Command 'soffice' -Directories (Get-LibreOfficeDirectories)
  }
  if (Have soffice) { return $true }

  Say "  install  LibreOffice (document and workbook rendering)"
  $script:OspinaLibreOfficeExitCode = Invoke-Native winget @(
    'install','--id','TheDocumentFoundation.LibreOffice','--exact','--source','winget','--silent',
    '--disable-interactivity','--accept-package-agreements','--accept-source-agreements'
  ) -Interactive
  Refresh-Path
  $null = Resolve-OnPath -Command 'soffice' -Directories (Get-LibreOfficeDirectories)
  return (Have soffice)
}
function Test-SyncedPath {
  # One definition, used by the menu, the OSPINA_WORKSPACE route and the typed
  # path. Sync clients and git both write to .git and eventually corrupt it, so
  # every route has to apply the same rule.
  param([string]$Path)
  if (-not $Path) { return $false }
  foreach ($root in @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)) {
    if ($root -and $Path.StartsWith($root, 'OrdinalIgnoreCase')) { return $true }
  }
  return ($Path -match '(?i)onedrive|dropbox|google drive|box sync')
}
function Get-WorkspaceCandidates {
  $home_ = $env:USERPROFILE
  $od    = $env:OneDrive
  $out   = @()

  function Add-Candidate($path, $why, $rank) {
    if (-not $path) { return }
    # OneDrive and Dropbox sync clients write into .git concurrently with git
    # and corrupt repositories. Never offer a synced location.
    if (Test-SyncedPath $path) { return }
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
  Say "  Running without elevation. Most tools install per-user."
  Say "  Windows may request administrator approval for LibreOffice."
}

if ((Get-ExecutionPolicy) -eq 'AllSigned') {
  Die @"
This account enforces PowerShell's AllSigned policy. Ospina setup needs a small
per-user profile block so Node 24 and Python 3.12 outrank older machine tools.
Ask your device administrator to approve that profile change or set a compatible
policy, then re-run this command.
"@
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

$NodeVersion = '24.19.0'
$pkgs = @(
  @{ Cmd = 'git';       Id = 'Git.Git';                 Required = $true  },
  @{ Cmd = 'gh';        Id = 'GitHub.cli';              Required = $true  },
  @{ Cmd = 'node';      Id = 'OpenJS.NodeJS.LTS';       Required = $true; Version = $NodeVersion },
  @{ Cmd = 'uv';        Id = 'astral-sh.uv';            Required = $true  },
  @{ Cmd = 'pdftotext'; Id = 'oschwartz10612.Poppler'; Required = $true  },
  @{ Cmd = 'vale';      Id = 'errata-ai.Vale';          Required = $false }
)
foreach ($p in $pkgs) {
  if (Have $p.Cmd) { Say "  ok       $($p.Cmd)"; continue }
  Say "  install  $($p.Cmd)  ($($p.Id))"
  # -Interactive so winget's progress and any prompt are visible. Hiding this
  # output made a slow first-run source update indistinguishable from a hang,
  # and would hide a prompt the reader cannot then answer.
  Say "          this can take a minute; winget output follows"
  $wingetArgs = @('install','--id',$p.Id,'--exact','--source','winget','--silent',
                  '--disable-interactivity',
                  '--accept-package-agreements','--accept-source-agreements')
  if ($p.Version) { $wingetArgs += @('--version',$p.Version) }
  $code = Invoke-Native winget $wingetArgs -Interactive
  Refresh-Path
  if ($p.Cmd -eq 'node') { $null = Resolve-NodeToolchainPath }
  if ($p.Cmd -eq 'uv') { $null = Resolve-UvOnPath }
  # A managed laptop often blocks machine-wide installs. User scope needs no admin.
  if (-not (Have $p.Cmd)) {
    Say "  retry    $($p.Cmd) with user-scope install (no admin required)"
    $wingetArgs = @('install','--id',$p.Id,'--exact','--source','winget','--silent','--scope','user',
                    '--disable-interactivity','--accept-package-agreements',
                    '--accept-source-agreements')
    if ($p.Version) { $wingetArgs += @('--version',$p.Version) }
    $code = Invoke-Native winget $wingetArgs -Interactive
    Refresh-Path
    if ($p.Cmd -eq 'node') { $null = Resolve-NodeToolchainPath }
    if ($p.Cmd -eq 'uv') { $null = Resolve-UvOnPath }
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

# Merely finding uv is not enough. Update it through the reviewed WinGet source
# unless it accepts the exact default-Python preview flags used below.
if (-not (Test-UvDefaultInstall)) {
  $null = Resolve-UvOnPath
}
if (-not (Test-UvDefaultInstall)) {
  Say "  upgrade  uv (the installed version lacks the required default-Python preview capability)"
  $uvArgs = @('upgrade','--id','astral-sh.uv','--exact','--source','winget','--silent',
              '--disable-interactivity','--accept-package-agreements','--accept-source-agreements')
  $null = Invoke-Native winget $uvArgs -Interactive
  Refresh-Path
  $null = Resolve-UvOnPath
  if (-not (Test-UvDefaultInstall)) {
    $uvArgs = @('install','--id','astral-sh.uv','--exact','--source','winget','--silent',
                '--scope','user','--force','--disable-interactivity',
                '--accept-package-agreements','--accept-source-agreements')
    $null = Invoke-Native winget $uvArgs -Interactive
    Refresh-Path
    $null = Resolve-UvOnPath
  }
}
if (-not (Test-UvDefaultInstall)) {
  Die "uv is installed, but it cannot enable the default-Python preview feature. Remove the conflicting uv installation, then re-run."
}

# Node 24 is the common version supported by T3 Code and all current Ospina
# Node repositories. A random newer system Node is not equivalent: some repos
# deliberately cap support below Node 25.
$nodeMajor = Get-NodeMajor
if ($nodeMajor -ne '24') {
  Say "  install  Node 24 LTS (current Node major: $nodeMajor)"
  $null = Invoke-Native winget @('install','--id','OpenJS.NodeJS.LTS','--exact','--source','winget','--silent',
            '--version',$NodeVersion,'--force','--disable-interactivity',
            '--accept-package-agreements','--accept-source-agreements') -Interactive
  Refresh-Path
  $nodeMajor = Get-NodeMajor
  if ($nodeMajor -ne '24') {
    $null = Invoke-Native winget @('install','--id','OpenJS.NodeJS.LTS','--exact','--source','winget','--silent',
              '--version',$NodeVersion,'--scope','user','--force','--disable-interactivity',
              '--accept-package-agreements','--accept-source-agreements') -Interactive
    Refresh-Path
    $null = Resolve-NodeToolchainPath
  }
  $nodeMajor = Get-NodeMajor
}
if ($nodeMajor -ne '24') {
  Die "Node 24 LTS is required, but Node major '$nodeMajor' is active. Remove the conflicting Node installation, then re-run."
}
Say "  ok       node 24 LTS"
$null = Resolve-NodeToolchainPath

$corepackReady = $true
if (-not (Have corepack)) {
  Say "  install  corepack"
  $npm = Get-NodeToolPath 'npm'
  if ($npm) { $rc = Invoke-Native $npm @('install','-g','corepack') -Interactive }
  else { $rc = 127 }
  Refresh-Path
  $installedCorepack = Get-CorepackPath
  if ($rc -ne 0 -or -not $installedCorepack) {
    Say "  note     Corepack did not install. pnpm repositories will not run yet."
    $corepackReady = $false
  } else {
    Add-UserPathEntry (Split-Path $installedCorepack -Parent)
  }
}
if ($corepackReady) {
  $corepackDir = Join-Path $env:USERPROFILE '.local\bin'
  New-Item -ItemType Directory -Force -Path $corepackDir | Out-Null
  $corepack = Get-CorepackPath
  if (-not $corepack -or
      (Invoke-Native $corepack @('enable','--install-directory',$corepackDir)) -ne 0) {
    Say "  note     Corepack could not enable pnpm. Setup will continue."
    $corepackReady = $false
  } else {
    Add-UserPathEntry $corepackDir
    Say "  ok       corepack enabled (each repo selects its pinned pnpm)"
  }
}

Say "  install  Python 3.12 (managed by uv)"
# --default creates the unversioned python/python3 shims and remains gated as a
# uv preview feature. Enable only that feature for this invocation.
if ((Invoke-Native uv @('python','install','3.12','--default','--preview-features','python-install-default') -Interactive) -ne 0) {
  Die "uv could not install Python 3.12."
}
$uvBin = Invoke-Native-Capture uv @('python','dir','--bin')
if ($uvBin -and (Test-Path -LiteralPath $uvBin -PathType Container)) {
  Add-UserPathEntry $uvBin
} else {
  Say "  note     uv did not report an existing Python bin directory; PATH was not changed."
}
if ((Invoke-Native uv @('python','find','3.12')) -ne 0) {
  Die "Python 3.12 was requested but uv cannot find it."
}
$pythonMinor = Get-PythonMinor
if ($pythonMinor -ne '3.12') {
  Die "Python 3.12 is installed, but the 'python' command resolves to '$pythonMinor'. Open a new PowerShell and re-run."
}
Say "  ok       python command is Python 3.12"

if (-not (Ensure-LibreOffice)) {
  Say "  note     LibreOffice is not installed (winget exit $OspinaLibreOfficeExitCode)."
  Say "           Its official WinGet package is machine-scoped and needs administrator approval."
  Say "           Setup will continue, but document and workbook visual QA will be unavailable."
} else { Say "  ok       soffice" }

# Several of the repositories a partner clones are pnpm / Next.js projects, and
# npm resolves to npm.ps1. Under the default Restricted policy none of them can
# be built or run. That makes this a prerequisite for the work itself, not a
# detail of installing one agent.
if ((Get-ExecutionPolicy) -eq 'Restricted') {
  Say ""
  Say "  PowerShell's execution policy is Restricted."
  Say "  That blocks .ps1 files, and npm on Windows is npm.ps1, so npm and pnpm"
  Say "  cannot run at all. Several Ospina repositories are Node projects and"
  Say "  will not build until this is changed."
  Say ""
  Say "  The standard developer setting, for your account only. It still refuses"
  Say "  unsigned scripts downloaded from the internet:"
  Say "    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned"
  Say ""
  if (Ask-YesNo "  Apply it now?") {
    try {
      Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
      Say ("  ok       execution policy is now {0}" -f (Get-ExecutionPolicy -Scope CurrentUser))
    } catch {
      Say ("  note     could not change it: {0}" -f $_.Exception.Message)
      Say  "           Node tooling will not work until you set it yourself."
    }
  } else {
    Say "  note     left as Restricted. npm and pnpm will not run, so the Node"
    Say "           repositories cannot be built until you change it. Ospina's"
    Say "           PATH preference profile also cannot run, so verified user"
    Say "           tools may not stay ahead of older machine tools in new terminals."
  }
} else {
  Say ("  ok       execution policy: {0}" -f (Get-ExecutionPolicy))
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
  # Without a login there is no membership endpoint to ask about; treat it as
  # "not a member" so the reader gets the invite path rather than a bad request.
  $inOrg = $false
  if ($who) { $inOrg = (Invoke-Native gh @('api',"orgs/ospina-company/members/$who")) -eq 0 }

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











$agents = @(
  @{ Name = 'T3 Code'; Command = $null;     Test = { Test-T3Code };  Install = { Install-T3Code }
     Manual = 'download from https://t3.codes/download' },
  @{ Name = 'Claude Code'; Command = 'claude'; Test = { Test-Claude }
     Manual = 'irm https://claude.ai/install.ps1 | iex'
     Install = { Install-ClaudeOfficial } },
  @{ Name = 'Codex'; Command = 'codex';       Test = { Test-Codex }; Manual = 'irm https://chatgpt.com/codex/install.ps1 | iex';
     Diagnose = {
       # npm can install into a prefix that is not on PATH. Show where it went.
       $prefix = Invoke-NodeToolCapture 'npm' @('prefix','-g')
       if ($prefix) {
         Say ("           npm global prefix: {0}" -f $prefix)
         $cand = Join-Path $prefix 'codex.cmd'
         if (Test-Path $cand) {
           Say  "           codex.cmd IS there, so this is a PATH problem. Add that"
           Say  "           folder to PATH, or open a new terminal."
         } else {
           Say  "           codex.cmd is NOT there, so the install did not complete."
         }
       }
     };
     Install = { Install-CodexOfficial } }
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
    # Trust the check, not the installer's exit code. A package manager can
    # report success while leaving nothing callable, and claiming "installed"
    # then means the next run asks again with no explanation.
    if (& $a.Test) {
      $cmdName = $a.Command
      if ($cmdName -and -not (Have $cmdName)) {
        Say ("  note     {0,-14} installed, but '{1}' is not callable in this" -f $a.Name, $cmdName)
        Say  "           session yet. Open a NEW terminal and it will work."
      } else {
        Say ("  ok       {0,-14} installed" -f $a.Name)
      }
    } elseif ($okAgent) {
      Say ("  note     {0,-14} the installer reported success, but the command is" -f $a.Name)
      Say  "           not callable yet. This is usually PATH: open a NEW terminal"
      Say  "           and run this command again to confirm."
      if ($a.Manual) { Say ("           If it persists, install by hand: {0}" -f $a.Manual) }
      if ($a.Diagnose) { & $a.Diagnose }
    } else {
      Say ("  note     {0,-14} did not install. Setup continues without it." -f $a.Name)
      if ($a.Manual) { Say ("           Install by hand: {0}" -f $a.Manual) }
    }
  } catch {
    Say ("  note     {0,-14} install failed, continuing without it" -f $a.Name)
    Say ("           reason: {0}" -f $_.Exception.Message)
    Say  "           Setup continues. Install it later and re-run this command."
  }
}
Say ""

$null = Resolve-OnPath -Command 'claude' -Directories @(
  (Join-Path $env:USERPROFILE '.local\bin')
)
$null = Resolve-OnPath -Command 'codex' -Directories @(
  (Join-Path $env:USERPROFILE '.local\bin'),
  (Join-Path $env:USERPROFILE '.codex\bin'),
  (Invoke-NodeToolCapture 'npm' @('prefix','-g'))
)
$providerAuthed = $false
if (Have claude) {
  if ((Invoke-Native claude @('auth','status')) -eq 0) {
    Say "  ok       Claude Code signed in"
    $providerAuthed = $true
  } elseif (Ask-YesNo "           Sign in to Claude Code now?") {
    $null = Invoke-Native claude @('auth','login') -Interactive
    if ((Invoke-Native claude @('auth','status')) -eq 0) {
      Say "  ok       Claude Code signed in"
      $providerAuthed = $true
    } else {
      Say "  note     Claude Code sign-in did not complete. Re-run it later."
    }
  }
}
if (Have codex) {
  if ((Invoke-Native codex @('login','status')) -eq 0) {
    Say "  ok       Codex signed in"
    $providerAuthed = $true
  } elseif (Ask-YesNo "           Sign in to Codex now?") {
    $null = Invoke-Native codex @('login') -Interactive
    if ((Invoke-Native codex @('login','status')) -eq 0) { $providerAuthed = $true }
  }
}
if (-not $providerAuthed) {
  Say "  note     Sign in to at least one agent before starting work in T3 Code."
}
Say ""


# ----------------------------------------------------------------- workspace
Step "Workspace location"

# Offer places that already exist and make sense on this machine, rather than
# inventing one path and hoping. A free-text prompt puts the burden on someone
# who has no idea what the constraints are.


if ($env:OSPINA_WORKSPACE) {
  $ws = $env:OSPINA_WORKSPACE
  Say "  using OSPINA_WORKSPACE=$ws"
  # The env-var route must not skip the sync-folder check the menu applies.
  if (Test-SyncedPath $ws) {
    Die "OSPINA_WORKSPACE points inside a cloud-synced folder. Sync clients and git both write to .git and will corrupt the repositories. Choose a path outside OneDrive, Dropbox, Google Drive and Box."
  }
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

  if ($pick -as [int]) {
    $n = [int]$pick
    if ($n -ge 1 -and $n -le $cands.Count) {
      $ws = $cands[$n - 1].Path
    } elseif ($n -eq ($cands.Count + 1)) {
      $ws = Read-Host "  Full path"
      if ([string]::IsNullOrWhiteSpace($ws)) { Die "No path given." }
    } else {
      # A number outside the menu is a mistyped choice, not a directory called "9".
      Die "$n is not one of the choices. Re-run and pick 1 to $($cands.Count + 1)."
    }
  } else {
    # Non-numeric input is treated as a literal path, so typing one still works.
    $ws = $pick
  }
  $ws = [Environment]::ExpandEnvironmentVariables($ws)
  if (Test-SyncedPath $ws) {
    Say ""
    Say "  WARNING: that path is inside a cloud-synced folder. Sync clients and git"
    Say "  both write to .git and will eventually corrupt the repositories."
    $ok = Read-Host "  Use it anyway? (y/n)"
    if ($ok -notmatch '^[Yy]') { Die "Pick a path outside OneDrive, Dropbox, Google Drive and Box, then run the command again." }
  }
}

New-Item -ItemType Directory -Force -Path $ws | Out-Null
$ws = (Resolve-Path $ws).Path
Say "  workspace: $ws"

Step "Handbook"
$hb = Join-Path $ws 'handbook'
if (Test-Path (Join-Path $hb '.git')) {
  Say "  ok       already cloned, verifying and updating"
  $handbookOrigin = Invoke-Native-Capture git @('-C',$hb,'remote','get-url','origin')
  $handbookOrigin = if ($handbookOrigin) {
    ($handbookOrigin.TrimEnd('/') -replace '\.git$','')
  } else { '' }
  $officialHandbookOrigins = @(
    'https://github.com/ospina-company/handbook',
    'git@github.com:ospina-company/handbook',
    'ssh://git@github.com/ospina-company/handbook'
  )
  if ($officialHandbookOrigins -notcontains $handbookOrigin) {
    Die @"
The existing handbook checkout does not use Ospina's official origin.
Expected: https://github.com/ospina-company/handbook
Got:      $(if ($handbookOrigin) { $handbookOrigin } else { 'no origin' })
Its bootstrap will not run. Move that checkout aside, then re-run.
"@
  }
  $handbookBranch = Invoke-Native-Capture git @('-C',$hb,'symbolic-ref','--quiet','--short','HEAD')
  if ($handbookBranch -ne 'main') {
    $branchLabel = if ($handbookBranch) { $handbookBranch } else { 'a detached commit' }
    Die "The existing handbook checkout is on '$branchLabel', not main.`nIts bootstrap will not run. Preserve or commit your work, switch the handbook to main, then re-run.`nYour repositories were not touched."
  }
  $handbookDirty = Invoke-Native-Capture git @('-C',$hb,'status','--porcelain')
  if ($handbookDirty) {
    Die "The existing handbook has local changes, so its bootstrap will not run.`nPreserve or commit those changes, restore a clean main checkout, then re-run.`nYour repositories were not touched."
  }
  if ((Invoke-Native git @('-C',$hb,'fetch','-q','origin','main')) -ne 0) {
    Die @"
Could not fetch the official handbook main branch, so its existing bootstrap will not run.
Older bootstrap versions can disclose repository names your account cannot read.
Check the network and your access, then re-run.
Your repositories were not touched.
"@
  }
  $handbookTarget = Invoke-Native-Capture git @('-C',$hb,'rev-parse','--verify','FETCH_HEAD')
  if (-not $handbookTarget -or
      (Invoke-Native git @('-C',$hb,'merge','-q','--ff-only',$handbookTarget)) -ne 0) {
    Die "The handbook main branch could not fast-forward to the official version.`nPreserve any local commits, restore main from the official origin, then re-run.`nIts existing bootstrap did not run."
  }
  $handbookHead = Invoke-Native-Capture git @('-C',$hb,'rev-parse','HEAD')
  if ($handbookHead -ne $handbookTarget) {
    Die "The handbook did not resolve to the fetched official main commit.`nIts existing bootstrap did not run. Restore a clean official main checkout, then re-run."
  }
} else {
  if (Test-Path $hb) {
    Die "'$hb' already exists but is not a Git checkout.`nMove that file or folder aside, then re-run. Nothing there was changed."
  }
  if ((Invoke-Native gh @('repo','clone','ospina-company/handbook',$hb,'--','-q')) -ne 0) {
    Die "Could not clone the handbook."
  }
  Say "  cloned   $hb"
}

# ------------------------------------------------------------------- handoff
Step "Running bootstrap"
Say ""
# Convert C:\Ospina\handbook to /c/Ospina/handbook for Git Bash.
$full = (Resolve-Path $hb).Path
# Git Bash addresses drives as /c/..., so a UNC path has no representation here
# and the conversion below would silently produce nonsense.
if ($full -notmatch '^[A-Za-z]:\\') {
  Die "The workspace must be on a drive letter, not a network path.`n  Got: $full`n  Re-run and choose a local path such as C:\Ospina."
}
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
$hadPrevToken = Test-Path Env:\GH_TOKEN
$prevToken    = if ($hadPrevToken) { $env:GH_TOKEN } else { $null }
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

# Invoke Bash with the script path as a native argument, not a shell command
# string. That preserves valid Windows paths containing spaces, apostrophes or
# shell metacharacters without quoting or code-injection risk. --no-login is
# belt and braces: even if the credential does not survive, the child must never
# start a login it has no way to finish.
try {
  $hbScriptUnix = "$hbUnix/bootstrap.sh"
  $rc = Invoke-Native $bash @($hbScriptUnix,'--no-login') -Interactive
} finally {
  # Restore whatever the caller had. This script runs in their session, so
  # deleting a variable we did not set would be a side effect they never asked
  # for.
  if ($hadPrevToken) { $env:GH_TOKEN = $prevToken }
  else { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue }
}

# bootstrap.sh exits non-zero when it finished with warnings, which is not
# necessarily a failure, but saying nothing leaves the reader guessing about
# output that has already scrolled past.
if ($rc -ne 0) {
  Say ""
  Say "  The bootstrap step finished with warnings or errors (exit $rc)." -ForegroundColor Yellow
  Say "  Read section 7 above for which checks did not pass. Re-running this"
  Say "  command is safe and fixes most of them."
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
  $ErrorActionPreference = $OspinaPrevEAP
  Write-Host ""
  Write-Host "This window stays open so you can read the output above." -ForegroundColor DarkGray
}
