[CmdletBinding()]
param(
  [string]$Version,
  [string]$ReleaseDirectory,
  [switch]$SkipWindows,
  [switch]$SkipLinux,
  [switch]$SkipLinuxArm64
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

if (-not $Version) {
  $Version = (Get-Content (Join-Path $projectRoot 'package.json') -Raw | ConvertFrom-Json).version
}

if (-not $ReleaseDirectory) {
  $ReleaseDirectory = Join-Path $projectRoot "release\foo-v$Version"
}
$ReleaseDirectory = [IO.Path]::GetFullPath($ReleaseDirectory)

$windowsSource = Join-Path $ReleaseDirectory "foo-v$Version-windows-x64"
$linuxTargets = @(
  [PSCustomObject]@{ Name = 'linux-x64'; DebianArchitecture = 'amd64' },
  [PSCustomObject]@{ Name = 'linux-arm64'; DebianArchitecture = 'arm64' }
)

function ConvertTo-WslPath([string]$Path) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  if ($fullPath -notmatch '^([A-Za-z]):\\(.*)$') {
    throw "Only local Windows paths can be passed to WSL: $fullPath"
  }
  $drive = $Matches[1].ToLowerInvariant()
  $tail = $Matches[2].Replace('\', '/')
  return "/mnt/$drive/$tail"
}

if (-not $SkipWindows) {
  if (-not (Test-Path (Join-Path $windowsSource 'bin\foo.exe'))) {
    throw "Windows release staging directory is missing: $windowsSource"
  }

  $isccCandidates = @(@(
      (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
      (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
      (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    ) | Where-Object { $_ -and (Test-Path $_) })
  if (-not $isccCandidates) {
    throw 'Inno Setup 6 is required. Install it with: winget install --id JRSoftware.InnoSetup --exact'
  }

  & $isccCandidates[0] "/DAppVersion=$Version" "/DSourceDir=$windowsSource" "/DOutputDir=$ReleaseDirectory" "/DProjectRoot=$projectRoot" (Join-Path $projectRoot 'installers\windows\foo.iss')
  if ($LASTEXITCODE -ne 0) { throw 'The Windows installer build failed.' }
}

if (-not $SkipLinux) {
  $linuxScript = ConvertTo-WslPath (Join-Path $projectRoot 'installers\linux\package.sh')
  $linuxOutput = ConvertTo-WslPath $ReleaseDirectory
  foreach ($target in $linuxTargets) {
    if ($target.Name -eq 'linux-arm64' -and $SkipLinuxArm64) { continue }
    $linuxSource = Join-Path $ReleaseDirectory "foo-v$Version-$($target.Name)"
    if (-not (Test-Path (Join-Path $linuxSource 'bin\foo'))) {
      throw "Linux release staging directory is missing: $linuxSource"
    }
    $linuxInput = ConvertTo-WslPath $linuxSource
    & wsl -d Ubuntu-22.04 -- sh $linuxScript $Version $linuxInput $linuxOutput $target.DebianArchitecture
    if ($LASTEXITCODE -ne 0) { throw "The $($target.Name) installer build failed." }
  }
}

$installers = Get-ChildItem $ReleaseDirectory -File | Where-Object { $_.Name -match '\.exe$|\.deb$' }
if (-not $installers) { throw 'No installer artifacts were produced.' }
$installers | ForEach-Object { Write-Host "Created $($_.FullName)" }

$releaseFiles = Get-ChildItem $ReleaseDirectory -File | Where-Object {
  $_.Name -match '\.(deb|exe|tgz|vsix|zip)$' -or $_.Name -match '\.tar\.gz$'
} | Sort-Object Name
$checksumLines = $releaseFiles | ForEach-Object {
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
  "$hash  $($_.Name)"
}
$utf8WithoutBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText(
  (Join-Path $ReleaseDirectory 'SHA256SUMS.txt'),
  (($checksumLines -join "`n") + "`n"),
  $utf8WithoutBom
)
Write-Host "Updated $(Join-Path $ReleaseDirectory 'SHA256SUMS.txt')"
