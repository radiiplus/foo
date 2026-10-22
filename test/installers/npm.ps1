[CmdletBinding()]
param([string]$Stage = '.artifacts/release-rehearsal')

$ErrorActionPreference = 'Stop'
$stageRoot = if ([IO.Path]::IsPathRooted($Stage)) {
  [IO.Path]::GetFullPath($Stage)
} else {
  [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Stage))
}
if (-not (Test-Path -LiteralPath (Join-Path $stageRoot 'foo.artifact.json'))) {
  throw "Staged compiler distribution not found: $stageRoot"
}
$expectedVersion = (Get-Content -LiteralPath (Join-Path $stageRoot 'package.json') -Raw | ConvertFrom-Json).version
$temporaryRoot = [IO.Path]::GetFullPath($(if ($env:FOO_TEST_ARTIFACT_DIR) { $env:FOO_TEST_ARTIFACT_DIR } else { & node (Join-Path $PSScriptRoot '../location.mjs') }))
$workspace = [IO.Path]::GetFullPath((Join-Path $temporaryRoot ("foo-npm-release-" + [guid]::NewGuid().ToString('N'))))
if (-not $workspace.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Release test directory escaped the temporary root: $workspace"
}
New-Item -ItemType Directory -Path $workspace | Out-Null

try {
  Push-Location $stageRoot
  try {
    $packed = npm pack --offline --json --pack-destination $workspace | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Offline npm pack failed' }
  }
  finally { Pop-Location }
  $archive = Join-Path $workspace (@($packed)[0].filename)
  if (-not (Test-Path -LiteralPath $archive)) { throw "npm archive missing: $archive" }

  $prefix = Join-Path $workspace 'installation'
  & npm install --offline --ignore-scripts --no-audit --no-fund --prefix $prefix $archive
  if ($LASTEXITCODE -ne 0) { throw 'Offline npm fresh install failed' }
  $installed = Join-Path $prefix 'node_modules\foo'
  foreach ($relative in @('bin\foo.exe', 'bin\foo.exe.dependencies.json',
      'toolchain\assets.json', 'vendor\manifest.json', 'vendor\moltenvk')) {
    if (-not (Test-Path -LiteralPath (Join-Path $installed $relative))) {
      throw "Installed npm package omitted $relative"
    }
  }
  Push-Location $installed
  try {
    $version = & node bin/foo.mjs version
    if ($LASTEXITCODE -ne 0 -or -not (($version -join "`n") -like "*compiler $expectedVersion*")) {
      throw 'Installed compiler version check failed'
    }
  }
  finally { Pop-Location }

  $project = Join-Path $prefix 'project'
  New-Item -ItemType Directory -Path $project | Out-Null
  [IO.File]::WriteAllText((Join-Path $project 'main.iv'), "start { give nothing. }`n")
  $cache = Join-Path $prefix '.artifacts\cache'
  New-Item -ItemType Directory -Path $cache -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $cache 'upgrade-marker'), 'preserve')
  & npm install --offline --force --ignore-scripts --no-audit --no-fund --prefix $prefix $archive
  if ($LASTEXITCODE -ne 0) { throw 'Offline npm reinstall failed' }
  if ((Get-Content -LiteralPath (Join-Path $cache 'upgrade-marker') -Raw) -ne 'preserve') {
    throw 'Reinstall discarded the existing project cache'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $project 'main.iv'))) {
    throw 'Reinstall discarded the existing project'
  }
  Write-Host 'Offline npm pack, fresh install, reinstall, QBE toolchain assets and MoltenVK retention passed'
}
finally {
  if ((Test-Path -LiteralPath $workspace) -and
      $workspace.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $workspace) -like 'foo-npm-release-*') {
    Remove-Item -LiteralPath $workspace -Recurse -Force
  }
}
