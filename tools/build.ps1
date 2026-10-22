[CmdletBinding()]
param(
  [string]$Version,
  [Alias('ReleaseDirectory')][string]$Directory,
  [Alias('SkipWindows')][switch]$Windows,
  [Alias('SkipLinux')][switch]$Linux,
  [Alias('SkipLinuxArm64')][switch]$Arm,
  [switch]$Sign
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($Sign -and $env:FOOSIGNER -notmatch '^[A-Fa-f0-9]{40}([A-Fa-f0-9]{24})?$') {
  throw 'Signed releases require FOOSIGNER with the full GPG key fingerprint.'
}
if ($Sign -and -not $Windows) {
  if ($env:FOO_WINDOWS_SIGN_CERT_SHA1 -notmatch '^[A-Fa-f0-9]{40}$') {
    throw 'Signed Windows releases require FOO_WINDOWS_SIGN_CERT_SHA1 with the certificate thumbprint.'
  }
  $timestamp = $null
  $validTimestamp = $false
  if ($env:FOO_WINDOWS_TIMESTAMP_URL) {
    $validTimestamp = [Uri]::TryCreate([string]$env:FOO_WINDOWS_TIMESTAMP_URL, [UriKind]::Absolute, [ref]$timestamp)
  }
  if (-not $validTimestamp -or $timestamp.Scheme -ne 'https') {
    throw 'Signed Windows releases require FOO_WINDOWS_TIMESTAMP_URL with an HTTPS RFC 3161 endpoint.'
  }
  $signTool = Get-Command signtool.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
  if (-not $signTool) {
    $signTool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.DirectoryName -like '*\x64' } | Sort-Object FullName -Descending |
      Select-Object -First 1 -ExpandProperty FullName
  }
  if (-not $signTool) { throw 'Signed Windows releases require signtool.exe from the Windows SDK.' }
}

if (-not $Version) {
  $Version = (Get-Content (Join-Path $root 'package.json') -Raw | ConvertFrom-Json).version
}

if (-not $Directory) {
  $Directory = Join-Path $root "release\foo-v$Version"
}
$Directory = [IO.Path]::GetFullPath($Directory)

$staging = Join-Path $Directory "foo-v$Version-windows-x64"
$targets = @(
  [PSCustomObject]@{ Name = 'linux-x64'; DebianArchitecture = 'amd64' },
  [PSCustomObject]@{ Name = 'linux-arm64'; DebianArchitecture = 'arm64' }
)

function Translate([string]$Path) {
  $mapped = & node (Join-Path $root 'tools\wsl.mjs') --path $Path
  if ($LASTEXITCODE -ne 0) { throw "Cannot map WSL path: $Path" }
  return $mapped.Trim()
}

function Invoke-WslJob([object[]]$Operations) {
  $request = @{ operations = $Operations } | ConvertTo-Json -Depth 10 -Compress
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request))
  $response = $encoded | & node (Join-Path $root 'tools\wsl.mjs') --base64
  if ($LASTEXITCODE -ne 0) {
    if ($response) {
      $failed = ($response | ConvertFrom-Json).results | Where-Object { $_.status -ne 0 -or $_.error } | Select-Object -First 1
      throw "WSL job failed: $($failed.error) $($failed.stderr)"
    }
    throw 'WSL job failed before returning results.'
  }
  foreach ($result in ($response | ConvertFrom-Json).results) {
    if ($result.stdout) { Write-Host $result.stdout.TrimEnd() }
    if ($result.stderr) { Write-Host $result.stderr.TrimEnd() }
  }
}

function Sign-Windows([string]$Path) {
  & $signTool sign /sha1 $env:FOO_WINDOWS_SIGN_CERT_SHA1 /fd SHA256 /tr $env:FOO_WINDOWS_TIMESTAMP_URL /td SHA256 $Path
  if ($LASTEXITCODE -ne 0) { throw "Authenticode signing failed: $Path" }
  & $signTool verify /pa $Path
  if ($LASTEXITCODE -ne 0) { throw "Authenticode verification failed: $Path" }
}

if (-not $Windows) {
  if (-not (Test-Path (Join-Path $staging 'bin\foo.exe'))) {
    throw "Windows release staging directory is missing: $staging"
  }
  if ($Sign) { Sign-Windows (Join-Path $staging 'bin\foo.exe') }

  $candidates = @(@(
      (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
      (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
      (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    ) | Where-Object { $_ -and (Test-Path $_) })
  if (-not $candidates) {
    throw 'Inno Setup 6 is required. Install it with: winget install --id JRSoftware.InnoSetup --exact'
  }

  & $candidates[0] "/DAppVersion=$Version" "/DSourceDir=$staging" "/DOutputDir=$Directory" "/DProjectRoot=$root" (Join-Path $root 'installers\windows\foo.iss')
  if ($LASTEXITCODE -ne 0) { throw 'The Windows installer build failed.' }
  if ($Sign) { Sign-Windows (Join-Path $Directory 'foo-windows-x64.exe') }

  $archive = Join-Path $Directory 'foo-windows-x64.zip'
  if (Test-Path $archive) { Remove-Item -LiteralPath $archive -Force }
  & tar -a -cf $archive -C $Directory (Split-Path -Leaf $staging)
  if ($LASTEXITCODE -ne 0) { throw 'The Windows archive build failed.' }
  Write-Host "Created $archive"
}

if (-not $Linux) {
  $script = Translate (Join-Path $root 'installers\linux\package.sh')
  $output = Translate $Directory
  $operations = @()
  foreach ($target in $targets) {
    if ($target.Name -eq 'linux-arm64' -and $Arm) { continue }
    $source = Join-Path $Directory "foo-v$Version-$($target.Name)"
    if (-not (Test-Path (Join-Path $source 'bin\foo'))) {
      throw "Linux release staging directory is missing: $source"
    }
    $submission = Translate $source
    $operations += @{ command = 'sh'; args = @($script, $Version, $submission, $output, $target.DebianArchitecture); tools = @('fakeroot', 'dpkg-deb', 'readelf') }

    $bundle = Join-Path $Directory "foo-$($target.Name).tar.gz"
    $destination = Translate $bundle
    $parent = Translate (Split-Path -Parent $source)
    $name = Split-Path -Leaf $source
    $operations += @{ command = 'tar'; args = @('-C', $parent, '-czf', $destination, $name) }
  }
  if ($operations.Count -gt 0) { Invoke-WslJob $operations }
}

if (-not $Windows) {
  & npm pack --offline --pack-destination $Directory $staging
  if ($LASTEXITCODE -ne 0) { throw 'The staged npm release archive build failed.' }
}

$installers = Get-ChildItem $Directory -File | Where-Object { $_.Name -match '\.exe$|\.deb$' }
if (-not $installers) { throw 'No installer artifacts were produced.' }
$installers | ForEach-Object { Write-Host "Created $($_.FullName)" }

$files = Get-ChildItem $Directory -File | Where-Object {
  $_.Name -ne 'SHA256SUMS.txt.asc' -and (
    $_.Name -match '\.(asc|deb|exe|tgz|vsix|zip)$' -or
    $_.Name -match '\.tar\.gz$' -or $_.Name -eq 'notes.md'
  )
} | Sort-Object Name
$checksums = $files | ForEach-Object {
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
  "$hash  $($_.Name)"
}
$utf8WithoutBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText(
  (Join-Path $Directory 'SHA256SUMS.txt'),
  (($checksums -join "`n") + "`n"),
  $utf8WithoutBom
)
Write-Host "Updated $(Join-Path $Directory 'SHA256SUMS.txt')"
if ($Sign) {
  $script = Translate (Join-Path $root 'tools\sign.mjs')
  $manifest = Translate (Join-Path $Directory 'SHA256SUMS.txt')
  $secret = Read-Host 'GPG passphrase' -AsSecureString
  $phrase = [System.Net.NetworkCredential]::new('', $secret).Password
  if (-not $phrase) { throw 'A GPG passphrase is required for release signing.' }
  Invoke-WslJob @(
    @{ command = 'node'; args = @($script, '--manifest', $manifest); env = @{ FOOSIGNER = $env:FOOSIGNER; FOOSIGNPIPE = '1' }; input = "$phrase`n"; tools = @('gpg') },
    @{ command = 'node'; args = @($script, '--verify', '--manifest', $manifest); env = @{ FOOSIGNER = $env:FOOSIGNER }; tools = @('gpg') }
  )
  $phrase = ''
}
