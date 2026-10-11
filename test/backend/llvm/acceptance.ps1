param(
  [string]$Nim = '',
  [string]$Root = '.artifacts/llvm-acceptance',
  [string]$Cache = '',
  [switch]$VerifyReportsOnly
)
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
Set-Location $repository
if ($env:FOO_LLVM_CASE) { throw 'Clear FOO_LLVM_CASE: acceptance requires the complete fixture matrix.' }
if (-not $Nim) {
  $command = Get-Command nim -ErrorAction SilentlyContinue
  if ($command) { $Nim = $command.Source }
  else { $Nim = Join-Path $env:USERPROFILE '.choosenim/toolchains/nim-2.2.12/bin/nim.exe' }
}
if (-not (Test-Path -LiteralPath $Nim)) { throw "Nim not found: $Nim" }
foreach ($tool in @('clang', 'lld-link')) { $null = Get-Command $tool -ErrorAction Stop }
$Root = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($Root)) { $Root } else { Join-Path $repository $Root }))
if (-not $Cache) { $Cache = Join-Path $Root 'nimcache' }
$null = New-Item -ItemType Directory -Force -Path $Root
$summaryPath = Join-Path $Root 'acceptance.json'
$checks = [Collections.Generic.List[object]]::new()
$sources = @(
  'test/types/coerce.nim', 'test/types/checker.nim', 'test/types/layout.nim',
  'test/types/borrow.nim', 'test/types/escape.nim', 'test/types/exhaust.nim',
  'test/ir/valid.nim', 'test/ir/lower.nim', 'test/ir/eval.nim',
  'test/ir/monomorph.nim', 'test/ir/reach.nim',
  'test/backend/c/emitter.nim', 'test/backend/zig/emitter.nim',
  'test/backend/llvm/slice.nim', 'test/backend/llvm/optimization.nim',
  'test/backend/llvm/ircore.nim', 'test/backend/llvm/core.nim'
)
if ($VerifyReportsOnly) {
  $previous = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
  foreach ($source in $sources) {
    $checked = @($previous.checks | Where-Object { $_.source -eq $source -and $_.passed })
    if ($checked.Count -ne 1) { throw "Missing successful check: $source" }
    $checks.Add($checked[0])
  }
}
$summary = [ordered]@{ format = 'foo.llvm.batch2.acceptance.v1'; passed = $false; complete = $false; checks = $checks }
$summary | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath $summaryPath
function Run-Check([string]$Source) {
  $name = $Source.Replace('/', '_').Replace('.nim', '')
  $binary = Join-Path $Root ($name + '.exe')
  $log = Join-Path $Root ($name + '.log')
  Write-Host "Checking $Source"
  $ErrorActionPreference = 'Continue'
  & $Nim c --cc:clang --mm:refc --hints:off "--nimcache:$Cache" "-o:$binary" $Source *> $log
  $compiled = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($compiled -ne 0) { Get-Content -LiteralPath $log -Tail 30; throw "Compilation failed: $Source" }
  $ErrorActionPreference = 'Continue'
  & $binary >> $log 2>&1
  $executed = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($executed -ne 0) { Get-Content -LiteralPath $log -Tail 30; throw "Check failed: $Source" }
  $checks.Add([ordered]@{ source = $Source; passed = $true; log = $log })
  $summary | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath $summaryPath
}
try {
  $env:FOOTESTID = 'batch2-acceptance'
  $env:FOO_LLVM_IRROOT = Join-Path $Root 'typed-ir'
  if (-not $VerifyReportsOnly) {
    foreach ($source in $sources[0..15]) { Run-Check $source }
  }
  $env:FOO_LLVM_ROOT = Join-Path $Root 'core'
  if (-not $VerifyReportsOnly) { Run-Check 'test/backend/llvm/core.nim' }
  $core = Get-Content -LiteralPath (Join-Path $env:FOO_LLVM_ROOT 'report.json') -Raw | ConvertFrom-Json
  $ir = Get-Content -LiteralPath (Join-Path $env:FOO_LLVM_IRROOT 'report.json') -Raw | ConvertFrom-Json
  $fixtures = Get-Content -LiteralPath 'test/backend/llvm/fixtures/cases.json' -Raw | ConvertFrom-Json
  $expected = $fixtures.Count * 6
  if (-not $core.complete -or -not $core.passed -or -not $core.fullSuite -or
      $core.observations -ne $expected -or -not $ir.complete -or -not $ir.passed -or
      $ir.observations -ne 24 -or $ir.abiRejections -ne 2 -or $ir.runtimeRejections -ne 1) {
    throw 'Incomplete differential matrix'
  }
  $rows = Get-Content -LiteralPath (Join-Path $env:FOO_LLVM_ROOT 'results.json') -Raw | ConvertFrom-Json
  if ($rows.Count -ne $expected -or @($rows | Where-Object { -not $_.passed }).Count) { throw 'Failed or missing source observations' }
  foreach ($fixture in $fixtures) {
    $hash = (Get-FileHash -Algorithm SHA1 -LiteralPath "test/backend/llvm/fixtures/$($fixture.name).iv").Hash
    foreach ($mode in @('dev', 'release')) {
      foreach ($backend in @('c', 'zig', 'llvm')) {
        $matchingRows = @($rows | Where-Object { $_.fixture -eq $fixture.name -and $_.mode -eq $mode -and $_.backend -eq $backend })
        if ($matchingRows.Count -ne 1 -or $matchingRows[0].sourceHash -ne $hash) { throw "Stale or incomplete fixture: $($fixture.name)/$mode/$backend" }
      }
    }
  }
  if ($core.manifestHash -ne (Get-FileHash -Algorithm SHA1 -LiteralPath 'test/backend/llvm/fixtures/cases.json').Hash) { throw 'Stale fixture manifest' }
  $summary.core = $core
  $summary.typedIr = $ir
  $summary.passed = $true
  $summary.complete = $true
  Write-Host "Batch 2 acceptance passed: $($core.observations) source observations, $($ir.observations) typed IR observations."
} catch {
  $summary.error = $_.Exception.Message
  $summary.complete = $true
  throw
} finally {
  $summary | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath $summaryPath
}
