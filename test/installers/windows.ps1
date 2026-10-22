[CmdletBinding()]
param([string]$Stage = '.artifacts/release-rehearsal')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$stageRoot = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Stage))
if (-not (Test-Path -LiteralPath (Join-Path $stageRoot 'bin\foo.exe'))) {
  throw "Staged Windows compiler not found: $stageRoot"
}
$currentVersion = (Get-Content -LiteralPath (Join-Path $stageRoot 'package.json') -Raw | ConvertFrom-Json).version
$previousVersion = '0.0.0'
if (-not $currentVersion -or $currentVersion -eq $previousVersion) {
  throw "Invalid staged compiler version: $currentVersion"
}
$compiler = @(
  (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
  (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
  (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $compiler) { throw 'Inno Setup 6 is required for the Windows installer upgrade gate.' }

$temporaryRoot = [IO.Path]::GetFullPath($(if ($env:FOO_TEST_ARTIFACT_DIR) { $env:FOO_TEST_ARTIFACT_DIR } else { & node (Join-Path $PSScriptRoot '../location.mjs') }))
$workspace = Join-Path $temporaryRoot ('foo-installer-upgrade-' + [guid]::NewGuid().ToString('N'))
$appId = [guid]::NewGuid().ToString('D').ToUpperInvariant()
$old = Join-Path $workspace 'old'
$new = Join-Path $workspace 'new'
$installation = Join-Path $workspace 'installation'
New-Item -ItemType Directory -Path $old,$new | Out-Null
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{$appId}_is1"

function Compile-Installer([string]$version, [string]$destination) {
  & $compiler '/Q' "/DAppVersion=$version" "/DSourceDir=$stageRoot" "/DOutputDir=$destination" "/DProjectRoot=$root" "/DPackageId={{$appId}" "/DAppLabel=FOO release test $appId" "/DPathRegistryKey=Software\FOOReleaseTest\$appId" (Join-Path $root 'installers\windows\foo.iss')
  if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed for version $version" }
  $result = Join-Path $destination 'foo-windows-x64.exe'
  if (-not (Test-Path -LiteralPath $result)) { throw "Installer missing: $result" }
  return $result
}

function Install-Installer([string]$file, [string]$log) {
  $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$installation`"", '/TASKS=!addtopath', "/LOG=`"$log`"")
  $process = Start-Process -FilePath $file -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
  if ($process.ExitCode -ne 0) { throw "Installer failed with exit status $($process.ExitCode); log: $log" }
}

try {
  $previous = Compile-Installer $previousVersion $old
  $current = Compile-Installer $currentVersion $new
  Install-Installer $previous (Join-Path $workspace 'first.log')
  if ((Get-ItemProperty -LiteralPath $uninstallKey).DisplayVersion -ne $previousVersion) {
    throw 'Initial installer registration has the wrong version'
  }
  $cache = Join-Path $installation '.artifacts\cache'
  New-Item -ItemType Directory -Path $cache -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $cache 'upgrade-marker'), 'preserve')
  $project = Join-Path $workspace 'project.iv'
  [IO.File]::WriteAllText($project, "start { give nothing. }`n")
  Install-Installer $current (Join-Path $workspace 'upgrade.log')
  if ((Get-ItemProperty -LiteralPath $uninstallKey).DisplayVersion -ne $currentVersion) {
    throw 'Upgrade did not register the new installer version'
  }
  if ((Get-Content -LiteralPath (Join-Path $cache 'upgrade-marker') -Raw) -ne 'preserve') {
    throw 'Installer upgrade discarded the compiler cache'
  }
  if (-not (Test-Path -LiteralPath $project)) { throw 'Installer upgrade discarded a user project' }
  $version = & (Join-Path $installation 'bin\foo.exe') version
  if ($LASTEXITCODE -ne 0 -or -not (($version -join "`n") -like "*compiler $currentVersion*")) {
    throw 'Upgraded compiler did not execute'
  }
  Write-Host 'Windows Inno Setup fresh install and versioned upgrade passed'
}
finally {
  $uninstaller = Get-ChildItem -LiteralPath $installation -Filter 'unins*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($uninstaller) {
    $process = Start-Process -FilePath $uninstaller.FullName -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) { Write-Warning "Test uninstaller exited with status $($process.ExitCode)" }
  }
  if ((Test-Path -LiteralPath $workspace) -and
      $workspace.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $workspace) -like 'foo-installer-upgrade-*') {
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
      try { Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction Stop; break }
      catch {
        if ($attempt -eq 19) { Write-Warning "Test workspace remained locked: $workspace" }
        else { Start-Sleep -Milliseconds 500 }
      }
    }
  }
}
