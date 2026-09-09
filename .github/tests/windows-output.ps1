# Runs only extracted helpers and synthetic processes; never installs packages.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source = Join-Path $root 'install.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($f in $ast.FindAll({
  $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)) { Invoke-Expression $f.Extent.Text }
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }

$preflightAst = [System.Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $root 'preflight.ps1'), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$storeProbe = $preflightAst.Find({
  $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
  $args[0].Name -eq 'Test-StorePythonPackage'
}, $true)
Invoke-Expression $storeProbe.Extent.Text
function Get-AppxPackage { param($Name,$ErrorAction) throw 'synthetic unsupported Appx query' }
try { Assert ($null -eq (Test-StorePythonPackage)) 'failed Appx query treated as absence' }
finally { Remove-Item Function:\Get-AppxPackage }

$setupEntry = $ast.Find({
  $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
  $args[0].Name -eq 'Invoke-OspinaInstall'
}, $true).Extent.Text
$loIndex = $setupEntry.IndexOf('if (-not (Ensure-LibreOffice))')
$uvPriorityIndex = $setupEntry.IndexOf('Add-UserPathEntry $uvBin')
$pythonCheckIndex = $setupEntry.IndexOf('$pythonMinor = Get-PythonMinor')
Assert ($loIndex -ge 0 -and $uvPriorityIndex -gt $loIndex -and
        $pythonCheckIndex -gt $uvPriorityIndex) 'LibreOffice can shadow verified Python priority'

Assert ((Format-DownloadReceipt 512 0.04) -eq 'downloaded 512 B in under 1s') 'small receipt'
Assert ((Format-DownloadReceipt 0 0) -eq 'downloaded 0 B in under 1s') 'zero-byte formatting'
Assert ((Format-DownloadReceipt 4096 0.8) -match '4[.,]0 KiB in under 1s') 'KiB receipt'
Assert ((Format-DownloadReceipt 1572864 2.25) -match '1[.,]5 MiB in 2[.,][23]s') 'MiB receipt'
Assert ((Get-ToolInstallFailure git -1978335138) -match 'certificate') 'certificate diagnostic'
Assert ((Get-ToolInstallFailure git 23) -match 'installation was not confirmed') 'failed install diagnostic'
Assert ((Get-ToolInstallFailure git 0) -match 'WinGet reported success') 'successful exit but missing tool'

# Never change host policy: model the scope precedence and a temporary Bypass.
$script:policyFixture = @{}
function Get-ExecutionPolicy {
  param([string]$Scope)
  if (-not $Scope -or $Scope -eq 'Process') { return 'Bypass' }
  if ($script:policyFixture.ContainsKey($Scope)) { return $script:policyFixture[$Scope] }
  return 'Undefined'
}
try {
  Assert ((Get-NextShellExecutionPolicy).Policy -eq 'Restricted') 'Process Bypass hid client default'
  $script:policyFixture.LocalMachine = 'RemoteSigned'
  Assert ((Get-NextShellExecutionPolicy).Policy -eq 'RemoteSigned') 'machine policy fallback'
  $script:policyFixture.CurrentUser = 'Restricted'
  Assert ((Get-NextShellExecutionPolicy).Policy -eq 'Restricted') 'current user precedence'
  $script:policyFixture.UserPolicy = 'AllSigned'
  Assert ((Get-NextShellExecutionPolicy).Scope -eq 'UserPolicy') 'user group policy precedence'
  $script:policyFixture.MachinePolicy = 'Restricted'
  Assert ((Get-NextShellExecutionPolicy).Scope -eq 'MachinePolicy') 'machine group policy precedence'

  # Exercise the actual consent block with mocked policy writes, including the
  # misleading Process-override error that can follow a successful persistence.
  $policySource = [IO.File]::ReadAllText($source)
  $start = $policySource.IndexOf('# Several of the repositories')
  $end = $policySource.IndexOf('# Git Bash is what actually runs')
  Assert ($start -ge 0 -and $end -gt $start) 'policy block not found'
  $policyBlock = [scriptblock]::Create($policySource.Substring($start, $end - $start))
  function Ask-YesNo { return $script:policyConsent }
  function Set-ExecutionPolicy {
    param($Scope,$ExecutionPolicy,[switch]$Force,$ErrorAction)
    Assert ($Scope -eq 'CurrentUser' -and $ExecutionPolicy -eq 'RemoteSigned') 'policy write scope widened'
    $script:policyWrites++
    if ($script:policySave) { $script:policyFixture.CurrentUser = 'RemoteSigned' }
    throw 'synthetic override or write failure'
  }
  foreach ($scenario in @('consent','decline','write-failure')) {
    $script:policyFixture = @{}
    $script:policyWrites = 0
    $script:policyConsent = $scenario -ne 'decline'
    $script:policySave = $scenario -eq 'consent'
    $nextShellPolicy = Get-NextShellExecutionPolicy
    $stopped = $false
    try { $null = & $policyBlock 6>&1 } catch { $stopped = $true }
    if ($scenario -eq 'consent') {
      Assert (-not $stopped -and $script:policyWrites -eq 1) 'saved policy misreported as failure'
    } else {
      Assert $stopped 'Restricted policy allowed false success'
      if ($scenario -eq 'decline') { Assert ($script:policyWrites -eq 0) 'policy changed without consent' }
    }
  }
} finally {
  Remove-Item Function:\Get-ExecutionPolicy
  Remove-Item Function:\Set-ExecutionPolicy -ErrorAction SilentlyContinue
  Remove-Item Function:\Ask-YesNo -ErrorAction SilentlyContinue
}

$state = @{LastOutput=0.0;LastProgress=$null}
foreach ($frame in @('', '  ', '-', '\', '|', '/')) {
  Assert ($null -eq (Get-WingetDisplayUpdate $frame $state 1)) 'spinner/blank leaked'
}
$bar = ([string][char]0x2588) * 8 + ([string][char]0x2592) * 8
Assert ((Get-WingetDisplayUpdate "$bar  25%" $state 5) -eq '          progress: 25%') 'bar conversion'
Assert ($null -eq (Get-WingetDisplayUpdate "$bar  26%" $state 6)) 'progress throttling'
Assert ((Get-WingetDisplayUpdate "$bar  100%" $state 7) -eq '          progress: 100%') 'completion suppressed'
Assert ($null -eq (Get-WingetDisplayUpdate "$bar  100%" $state 8)) 'duplicate completion'
Assert ((Get-WingetDisplayUpdate '|' $state 23) -match 'still working') 'working heartbeat'
Assert ((Get-WingetDisplayUpdate "$bar  1.00 MB / 62.3 MB" $state 29) -match '1.00 MB / 62.3 MB') 'download progress'
$warning = 'The installer will request to run as administrator, expect a prompt.'
Assert ((Get-WingetDisplayUpdate $warning $state 30) -eq $warning) 'approval prompt lost'
$errLine = 'ERROR: certificate mismatch (0x8A15005E)'
Assert ((Get-WingetDisplayUpdate $errLine $state 30) -eq $errLine) 'error lost'
$localized = ([string][char]0x00e9) + 'chec: 23'
Assert ((Get-WingetDisplayUpdate $localized $state 30) -eq $localized) 'localized text lost'
$ansi = [string][char]27 + '[31m' + $errLine + [char]27 + '[0m'
Assert ((Get-WingetDisplayUpdate $ansi $state 30) -eq $errLine) 'ANSI escape leaked'

# Real native bytes and stderr under Windows PowerShell 5.1, not a mocked string.
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ospina-output-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $fixture | Out-Null
$savedEncoding = [Console]::OutputEncoding
try {
  $exe = Join-Path $fixture 'winget.exe'
  Add-Type -OutputAssembly $exe -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.Text;
public class OutputFixture {
  public static int Main() {
    Console.OutputEncoding = new UTF8Encoding(false);
    Console.WriteLine("  -");
    Console.WriteLine("\u2588\u2592  100%");
    Console.WriteLine("caf\u00e9 ready");
    Console.Error.WriteLine("synthetic stderr failure");
    return 23;
  }
}
'@
  [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
  $output = @(Invoke-Native $exe @() -Interactive 6>&1)
  Assert ($output[-1] -eq 23) 'native exit code lost or output contaminated return'
  $text = ($output | Out-String)
  Assert ($text.Contains(('caf' + [char]0x00e9 + ' ready'))) 'UTF-8 native decoding failed'
  Assert ($text.Contains('synthetic stderr failure')) 'native stderr lost'
  Assert ($text.Contains('progress: 100%')) 'native progress missing'
  Assert (-not $text.Contains([string][char]0x2588)) 'native bar leaked'

  # Exercise the production encoding wrapper and real vendor child process,
  # replacing only the installation entrypoint with a harmless failure fixture.
  # This covers restoration on exceptions without executing setup or auth.
  $vendorFile = Join-Path $fixture 'vendor.ps1'
  Set-Content -LiteralPath $vendorFile -Encoding ASCII -Value @'
Write-Output (([string][char]0x2714) + ' synthetic vendor')
exit 23
'@
  $vendorDigest = (Get-FileHash -LiteralPath $vendorFile -Algorithm SHA256).Hash
  $entry = $ast.Find({
    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $args[0].Name -eq 'Invoke-OspinaInstall'
  }, $true)
  $replacement = @'
function Invoke-OspinaInstall {
  if ([Console]::OutputEncoding.CodePage -ne 65001 -or
      [Console]::InputEncoding.CodePage -ne 65001 -or
      $OutputEncoding.CodePage -ne 65001) { throw 'encoding setup failed' }
  Write-Output 'UTF8 scope verified'
  $rc = Invoke-VerifiedInstallerScript $vendorFile $vendorDigest 'synthetic vendor'
  Write-Output "vendor exit: $rc"
  throw 'synthetic setup failure'
}
'@
  $scriptText = [IO.File]::ReadAllText($source)
  $testScript = $scriptText.Substring(0, $entry.Extent.StartOffset) + $replacement +
    $scriptText.Substring($entry.Extent.EndOffset)
  [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(437)
  $inputBefore = [Console]::InputEncoding.CodePage
  $outputBefore = $OutputEncoding.CodePage
  $eapBefore = $ErrorActionPreference
  $wrapperOutput = (& ([scriptblock]::Create($testScript)) 6>&1 | Out-String)
  Assert ($wrapperOutput.Contains('UTF8 scope verified')) 'wrapper did not configure UTF8'
  Assert ($wrapperOutput.Contains(([string][char]0x2714 + ' synthetic vendor'))) 'vendor UTF8 garbled'
  Assert ($wrapperOutput.Contains('vendor exit: 23')) 'vendor exit lost'
  Assert ($wrapperOutput.Contains('synthetic setup failure')) 'exception fixture did not execute'
  Assert ([Console]::OutputEncoding.CodePage -eq 437) 'console output encoding not restored'
  Assert ([Console]::InputEncoding.CodePage -eq $inputBefore) 'console input encoding not restored'
  Assert ($OutputEncoding.CodePage -eq $outputBefore) 'pipeline encoding not restored'
  Assert ($ErrorActionPreference -eq $eapBefore) 'error preference not restored'
} finally {
  [Console]::OutputEncoding = $savedEncoding
  Remove-Item -LiteralPath $fixture -Recurse -Force
}
Write-Host 'Windows output regression tests passed'
# Actions' PowerShell wrapper propagates LASTEXITCODE. The nonzero fixture
# statuses above are expected assertions, not the outcome of this test suite.
$global:LASTEXITCODE = 0
