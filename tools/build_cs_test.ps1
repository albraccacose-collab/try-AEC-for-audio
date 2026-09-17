# Compile and run the C# interop test against aec_api.dll.
# Uses the in-box .NET Framework csc.exe, which is enough - no MSBuild needed.
# Repo paths are derived from this script's own location, so the repo is relocatable.
param(
  [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
  [string]$AecRoot  = '',
  [string]$AppRoot  = '',
  [string]$Tools    = '',
  [string]$OutDir   = ''
)

$ErrorActionPreference = 'Stop'
if (-not $AecRoot) { $AecRoot = Join-Path $RepoRoot 'AEC3-master' }
if (-not $AppRoot) { $AppRoot = Join-Path $RepoRoot 'AecToolApp_2' }
if (-not $Tools)   { $Tools   = Join-Path $RepoRoot 'tools' }
if (-not $OutDir)  { $OutDir  = Join-Path $AecRoot  'output\Debug_x64' }

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "csc.exe not found at $csc" }

$dll = Join-Path $OutDir 'aec_api.dll'
if (-not (Test-Path $dll)) { throw "aec_api.dll not found at $dll - build the solution first" }

$src      = Join-Path $Tools 'cs_interop_test.cs'
$interop  = Join-Path $AppRoot 'NativeAec.cs'
$exe      = Join-Path $Tools 'cs_interop_test.exe'
foreach ($f in @($src, $interop)) { if (-not (Test-Path $f)) { throw "missing source: $f" } }

# /platform:x64 is mandatory: the native DLL is 64-bit.
Write-Host "compiling C# interop test (x64)..."
$out = & $csc /nologo /platform:x64 /warnaserror- /out:$exe $src $interop 2>&1
$exit = $LASTEXITCODE
if ($out) { $out | ForEach-Object { Write-Host $_ } }
if ($exit -ne 0) {
  # Fail loudly: a stale exe silently passing tests is worse than no exe.
  throw "csc failed (exit $exit) - the existing $exe is STALE and must not be trusted"
}

Copy-Item $dll (Join-Path $Tools 'aec_api.dll') -Force
Write-Host "OK -> $exe"
