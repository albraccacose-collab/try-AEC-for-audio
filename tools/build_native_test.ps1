# Build the native test harness without relying on vcvars64.bat (the installed one
# may be broken: exits 1 with "system cannot find the path specified").
# Toolchain paths are DISCOVERED, never hardcoded, so this file stays pure ASCII.
# Repo paths are derived from this script's own location, so the repo is relocatable.
param(
  [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
  [string]$AecRoot  = '',
  [string]$Tools    = '',
  [string]$OutDir   = '',
  [switch]$Release
)

$ErrorActionPreference = 'Stop'
if (-not $AecRoot) { $AecRoot = Join-Path $RepoRoot 'AEC3-master' }
if (-not $Tools)   { $Tools   = Join-Path $RepoRoot 'tools' }
if (-not $OutDir)  { $OutDir  = Join-Path $AecRoot  'output\Debug_x64' }

# ---- discover MSVC ------------------------------------------------
$clExe = $null
foreach ($drive in @('X:\', 'C:\', 'D:\')) {
  if (-not (Test-Path $drive)) { continue }
  $hit = Get-ChildItem -Path $drive -Filter 'cl.exe' -Recurse -File -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -match 'Hostx64\\x64\\cl\.exe$' } |
         Select-Object -First 1
  if ($hit) { $clExe = $hit.FullName; break }
}
if (-not $clExe) { throw 'cl.exe (Hostx64\x64) not found on any drive' }
$clDir = Split-Path $clExe -Parent
# ...\VC\Tools\MSVC\<ver>\bin\Hostx64\x64  ->  ...\VC\Tools\MSVC\<ver>
$msvcRoot = Split-Path (Split-Path (Split-Path $clDir -Parent) -Parent) -Parent
$msvcInc  = Join-Path $msvcRoot 'include'
$msvcLib  = Join-Path $msvcRoot 'lib\x64'
if (-not (Test-Path $msvcInc)) { throw "MSVC include not found at $msvcInc" }
if (-not (Test-Path $msvcLib)) { throw "MSVC lib not found at $msvcLib" }

# ---- discover Windows SDK ----------------------------------------
$sdkRoot = $null
foreach ($drive in @('X:\', 'C:\', 'D:\')) {
  $cand = Join-Path $drive 'Windows Kits\10'
  if (Test-Path (Join-Path $cand 'Include')) { $sdkRoot = $cand; break }
}
if (-not $sdkRoot) { throw 'Windows Kits\10 not found' }
$sdkVer = Get-ChildItem (Join-Path $sdkRoot 'Include') -Directory |
          Where-Object { $_.Name -match '^10\.' } |
          Sort-Object Name -Descending | Select-Object -First 1
if (-not $sdkVer) { throw 'no SDK version folder under Windows Kits\10\Include' }
$sdkV = $sdkVer.Name

$sdkInc   = Join-Path $sdkRoot "Include\$sdkV"
$sdkUcrtL = Join-Path $sdkRoot "Lib\$sdkV\ucrt\x64"
$sdkUmL   = Join-Path $sdkRoot "Lib\$sdkV\um\x64"
foreach ($p in @($sdkUcrtL, $sdkUmL)) {
  if (-not (Test-Path $p)) { throw "missing SDK lib dir: $p" }
}

Write-Host "cl       : $clExe"
Write-Host "MSVC     : $msvcRoot"
Write-Host "SDK      : $sdkRoot ($sdkV)"

# ---- environment --------------------------------------------------
$env:PATH = $clDir + ';' + $env:PATH
$env:INCLUDE = @(
  $msvcInc,
  (Join-Path $sdkInc 'ucrt'),
  (Join-Path $sdkInc 'shared'),
  (Join-Path $sdkInc 'um'),
  (Join-Path $sdkInc 'winrt'),
  (Join-Path $sdkInc 'cppwinrt')
) -join ';'
$env:LIB = @($msvcLib, $sdkUcrtL, $sdkUmL) -join ';'

# ---- compile ------------------------------------------------------
$src = Join-Path $Tools 'aec_c_api_test.c'
$exe = Join-Path $Tools 'aec_c_api_test.exe'
$obj = Join-Path $Tools 'aec_c_api_test.obj'
$dll = Join-Path $OutDir 'aec_api.dll'
if (-not (Test-Path $dll)) { throw "aec_api.dll not found at $dll - build the solution first" }

# wavreader/wavwriter are internal to the DLL, so compile them into the harness too.
$wavSrc = @(
  (Join-Path $AecRoot 'demo\wavreader.c'),
  (Join-Path $AecRoot 'demo\wavwriter.c')
)
foreach ($w in $wavSrc) { if (-not (Test-Path $w)) { throw "missing $w" } }

# Debug aec_api.dll links the debug CRT, so the harness must match.
$crt = if ($Release) { '/MD' } else { '/MDd' }
$extra = if ($Release) { @() } else { @('/D_DEBUG') }

$clArgs = @('/nologo', '/W3', $crt) + $extra + @(
  '/TC', $src
) + $wavSrc + @(
  ('/I' + (Join-Path $AecRoot 'api')),
  ('/I' + (Join-Path $AecRoot 'demo')),
  ('/Fe:' + $exe),
  ('/Fo:' + (Join-Path $Tools 'obj\')),
  '/link',
  ('/LIBPATH:' + $OutDir),
  'aec_api.lib', 'winmm.lib'
)

Write-Host ("crt      : " + $crt)
Write-Host 'compiling...'
$out = & $clExe @clArgs 2>&1
$out | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "compile/link failed (exit $LASTEXITCODE)" }

Remove-Item (Join-Path $Tools 'aec_api.dll') -Force -ErrorAction SilentlyContinue
Copy-Item $dll (Join-Path $Tools 'aec_api.dll') -Force
Write-Host "OK -> $exe"
