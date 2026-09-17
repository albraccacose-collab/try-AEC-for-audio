# One-command verification of the whole AEC3 -> C# pipeline.
# Read-only with respect to sources; it rebuilds and re-runs every check.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify_all.ps1
#
# Repo paths are derived from this script's own location, so the repo is
# relocatable. Test audio defaults to the synthesised pair in testdata\;
# make_test_audio.ps1 is invoked automatically when those files are missing.
param(
  [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
  [string]$AecRoot  = '',
  [string]$AppRoot  = '',
  [string]$Tools    = '',
  [string]$OutDir   = '',
  [string]$Ref      = '',
  [string]$Mic      = '',
  [string]$NearEnd  = '',
  [switch]$SkipRebuild
)

$ErrorActionPreference = 'Stop'
if (-not $AecRoot) { $AecRoot = Join-Path $RepoRoot 'AEC3-master' }
if (-not $AppRoot) { $AppRoot = Join-Path $RepoRoot 'AecToolApp_2' }
if (-not $Tools)   { $Tools   = Join-Path $RepoRoot 'tools' }
if (-not $OutDir)  { $OutDir  = Join-Path $AecRoot  'output\Debug_x64' }

# ---- test audio: synthesise on demand ---------------------------------
$testData = Join-Path $RepoRoot 'testdata'
if (-not $Ref)     { $Ref     = Join-Path $testData 'synth_farend_16k.wav' }
if (-not $Mic)     { $Mic     = Join-Path $testData 'synth_mic_16k.wav' }
if (-not $NearEnd) { $NearEnd = Join-Path $testData 'synth_nearend_16k.wav' }

if (-not (Test-Path $Ref) -or -not (Test-Path $Mic) -or -not (Test-Path $NearEnd)) {
  Write-Host 'test audio missing - generating with tools\make_test_audio.ps1'
  & (Join-Path $Tools 'make_test_audio.ps1') -OutDir $testData | Out-Null
}

$script:failures = 0
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# AEC3 writes informational RTC_LOG lines to stderr (delay adjustments, render
# underruns). Under ErrorActionPreference=Stop, PowerShell promotes native stderr
# output to a terminating error, so relax it for each native invocation.
function Invoke-Native {
  param([string]$Exe, [string[]]$Arguments)
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $Exe @Arguments 2>$null
    return @{ Output = @($out); ExitCode = $LASTEXITCODE }
  } finally {
    $ErrorActionPreference = $saved
  }
}

function Section([string]$t) { Write-Host ""; Write-Host ("=" * 62); Write-Host $t; Write-Host ("=" * 62) }
function Step([string]$t) { Write-Host ""; Write-Host "--- $t" }
function Check([string]$name, [bool]$ok, [string]$detail) {
  Write-Host (("  {0} {1}" -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $name.PadRight(52)) + $detail)
  if (-not $ok) { $script:failures++ }
}

function Find-MSBuild {
  # Do NOT use vswhere: it returns the install path through a pipe and any
  # non-ASCII characters in it get mangled by the console code page
  # (this machine's VS lives under a Chinese-named folder). Probe the
  # filesystem instead, which handles Unicode paths correctly.
  $candidates = New-Object System.Collections.ArrayList
  foreach ($base in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) {
    if ($base) { [void]$candidates.Add((Join-Path $base 'Microsoft Visual Studio')) }
  }
  # also probe drive roots for a relocated VS install
  foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
    if ($drive.Root -match '^[A-Za-z]:\\$') { [void]$candidates.Add($drive.Root) }
  }

  foreach ($c in $candidates) {
    if (-not (Test-Path $c)) { continue }
    $hit = Get-ChildItem -Path $c -Filter 'MSBuild.exe' -Recurse -File -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -match '\\MSBuild\\Current\\Bin\\MSBuild\.exe$' } |
           Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  throw 'MSBuild.exe not found on any probed root'
}

foreach ($f in @($Ref, $Mic, $NearEnd)) {
  if (-not (Test-Path $f)) { throw "test audio missing: $f" }
}
$scratch = Join-Path $OutDir 'scratch'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

$msb = Find-MSBuild

# ---------------------------------------------------------------- build
Section '1. BUILD'
if (-not $SkipRebuild) {
  Step 'MSBuild /t:Rebuild AEC3.sln (x64 Debug)'
  $log = & $msb (Join-Path $AecRoot 'AEC3.sln') /t:Rebuild /p:Configuration=Debug /p:Platform=x64 /m /v:m /nologo 2>&1
  $errs = @($log | Where-Object { $_ -match ': error' })
  Check 'solution rebuilds clean' ($errs.Count -eq 0 -and $LASTEXITCODE -eq 0) "$($errs.Count) error(s)"
  foreach ($e in $errs) { Write-Host "      $e" }

  Step 'rebuild native + C# test harnesses'
  $o1 = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tools 'build_native_test.ps1') 2>&1
  Check 'native harness built' ($LASTEXITCODE -eq 0) ($o1 | Select-Object -Last 1)
  $o2 = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tools 'build_cs_test.ps1') 2>&1
  Check 'C# harness built' ($LASTEXITCODE -eq 0) ($o2 | Select-Object -Last 1)

  Step 'rebuild WinForms app'
  $log2 = & $msb (Join-Path $AppRoot 'AecToolApp_2.csproj') /t:Rebuild /p:Configuration=Debug /p:Platform=x64 /v:m /nologo 2>&1
  $errs2 = @($log2 | Where-Object { $_ -match ': error' })
  Check 'WinForms app rebuilds clean' ($errs2.Count -eq 0 -and $LASTEXITCODE -eq 0) "$($errs2.Count) error(s)"
}

$dll = Join-Path $OutDir 'aec_api.dll'
if (-not (Test-Path $dll)) { throw "aec_api.dll missing: $dll" }
Copy-Item $dll (Join-Path $Tools 'aec_api.dll') -Force
Copy-Item $dll (Join-Path $AppRoot 'bin\x64\Debug\aec_api.dll') -Force

# ---------------------------------------------------------------- exports
Section '2. EXPORT TABLE'
Step 'aec_api.dll exports'
$expText = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tools 'dump_exports.ps1') -Path $dll 2>&1
$expText | Where-Object { $_ -match 'machine|PE32|exported symbol|^  AEC_' } | ForEach-Object { Write-Host "    $_" }
$wanted = @('AEC_Create', 'AEC_Destroy', 'AEC_GetAbortFlag', 'AEC_GetAudioFormat',
            'AEC_GetAudioInfo', 'AEC_GetMetrics', 'AEC_Process',
            'AEC_ProcessAudioFiles', 'AEC_ProcessAudioFilesEx', 'AEC_SetAudioBufferDelay')
$expJoined = ($expText -join "`n")
Check 'all 10 expected symbols exported' (($wanted | Where-Object { $expJoined -notmatch [regex]::Escape($_) }).Count -eq 0) ''
Check 'no mangled names' ($expJoined -notmatch 'MANGLED') ''
Check 'target is x64 PE32+' (($expJoined -match 'machine    : x64') -and ($expJoined -match 'PE32\+      : True')) ''

# --- regression guards against the old broken setup -------------------
Step 'regression guards'
$repoRoot = Split-Path $AecRoot -Parent

# The stale empty-shell api.dll (zero exports) used to sit in bin\Debug and could
# be picked up by a 32-bit build. It must not come back.
$shellHits = @(Get-ChildItem -Path $repoRoot -Recurse -File -Filter 'api.dll' -ErrorAction SilentlyContinue)
Check 'no stale api.dll anywhere' ($shellHits.Count -eq 0) (($shellHits | ForEach-Object { $_.FullName }) -join ', ')

# bin\Debug must not exist: it was the AnyCPU output that built a 32-bit process.
Check 'no AnyCPU bin\Debug output dir' (-not (Test-Path (Join-Path $AppRoot 'bin\Debug'))) ''

# Only x64 may be declared by the C# project. Match configuration *conditions*
# rather than the bare word: the csproj comment explains why AnyCPU was removed
# and must not trip this check.
$csprojText = Get-Content (Join-Path $AppRoot 'AecToolApp_2.csproj') -Raw
$anyCpuCond = [regex]::Matches($csprojText, "'[^']*\|AnyCPU'")
Check 'csproj declares no AnyCPU configuration' ($anyCpuCond.Count -eq 0) ("$($anyCpuCond.Count) condition(s)")
Check 'csproj defaults Platform to x64' ($csprojText -match '<Platform Condition[^>]*>x64</Platform>') ''

# The C# solution must not cross-reference the native project: the native
# projects resolve includes and outputs through $(SolutionDir), which points at
# the wrong directory when they are built from another solution.
$csSlnText = Get-Content (Join-Path $AppRoot 'AecToolApp_2.sln') -Raw
Check 'C# solution does not embed the native project' ($csSlnText -notmatch 'AEC3\.vcxproj') ''
Check 'C# solution only declares x64' (($csSlnText -notmatch 'Any CPU') -and ($csSlnText -notmatch 'x86')) ''

# The deployed DLL must be the one we just built.
$deployed = Join-Path $AppRoot 'bin\x64\Debug\aec_api.dll'
Check 'aec_api.dll deployed next to the app' (Test-Path $deployed) ''
if (Test-Path $deployed) {
  $same = (Get-FileHash $deployed -Algorithm SHA256).Hash -eq (Get-FileHash $dll -Algorithm SHA256).Hash
  Check 'deployed DLL matches the freshly built one' $same ''
}

# The app must be 64-bit, matching the DLL.
$exePath = Join-Path $AppRoot 'bin\x64\Debug\AecToolApp_2.exe'
if (Test-Path $exePath) {
  $eb = [System.IO.File]::ReadAllBytes($exePath)
  $ee = [BitConverter]::ToInt32($eb, 0x3C)
  $mach = [BitConverter]::ToUInt16($eb, $ee + 4)
  Check 'app binary is x64' ($mach -eq 0x8664) ("machine=0x{0:X4}" -f $mach)
}

# ---------------------------------------------------------------- native
Section '3. NATIVE BEHAVIOUR'
Step 'error codes'
$e1 = (Invoke-Native (Join-Path $Tools 'aec_c_api_test.exe') @('errors', $Ref)).Output
$e1 | Where-Object { $_ -match 'expect|ALL ERROR|SOME' } | ForEach-Object { Write-Host "    $_" }
Check 'all error cases return the documented codes' (($e1 -join "`n") -match 'ALL ERROR CASES OK') ''

Step 'cancellation'
$e2 = (Invoke-Native (Join-Path $Tools 'aec_c_api_test.exe') @('cancel', $Ref, $Mic, (Join-Path $scratch 'verify_cancel.wav'), '200')).Output
$e2 | Where-Object { $_ -match 'requested|returned code|stopped|rerun|ABORT SEM|unexpected' } | ForEach-Object { Write-Host "    $_" }
Check 'abort semantics correct' (($e2 -join "`n") -match 'ABORT SEMANTICS OK') ''

Step 'streaming == whole-file (byte-identical output)'
$s = Join-Path $scratch 'verify_stream.wav'
$f = Join-Path $scratch 'verify_file.wav'
$null = (Invoke-Native (Join-Path $Tools 'aec_c_api_test.exe') @('streaming-every', $Ref, $Mic, $s, '-', '0')).Output
$null = (Invoke-Native (Join-Path $Tools 'aec_c_api_test.exe') @('file', $Ref, $Mic, $f, '0')).Output
$hs = (Get-FileHash $s -Algorithm SHA256).Hash
$hf = (Get-FileHash $f -Algorithm SHA256).Hash
Check 'both modes produce the same bytes' ($hs -eq $hf) $hs.Substring(0, 24)

# ---------------------------------------------------------------- csharp
Section '4. C# INTEROP'
$cs = (Invoke-Native (Join-Path $Tools 'cs_interop_test.exe') @($Ref, $Mic, (Join-Path $scratch 'verify_cs.wav'))).Output
$cs | Where-Object { $_ -match 'FAIL|RESULT|^  OK' } | ForEach-Object { Write-Host "    $_" }
Check 'all C# interop tests pass' (($cs -join "`n") -match 'ALL C# INTEROP TESTS PASSED') ''

# ---------------------------------------------------------------- quality
Section '5. ECHO CANCELLATION QUALITY'
Step 'ERLE over the pure single-talk prefix (higher is better)'
$cmp = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tools 'compare_outputs.ps1') `
  -Mic $Mic -NearEnd $NearEnd `
  -Out ((Join-Path $scratch 'out_demo.wav') + ';' + $s) `
  -Label 'demo.exe;verify_all' 2>&1
$cmp | Where-Object { $_ -match 'demo|verify_all|mic \(echo' } | ForEach-Object { Write-Host "    $_" }

# Table columns are: <label> <out RMS dB> <ERLE dB> <out-mic dB>.
# Match "label <rms> <erle> <delta>" so the third number (ERLE) is captured.
$apiErle = $null
foreach ($line in $cmp) {
  if ($line -match '^verify_all\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)') {
    $apiErle = [double]$Matches[2]
    break
  }
}
Check 'ERLE >= 25 dB' ($null -ne $apiErle -and $apiErle -ge 25.0) ("ERLE = " + $apiErle + " dB")

# ---------------------------------------------------------------- gui
Section '6. GUI SMOKE TEST'
$exe = Join-Path $AppRoot 'bin\x64\Debug\AecToolApp_2.exe'
$p = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 4
$alive = -not $p.HasExited
$title = ''
if ($alive) { $p.Refresh(); $title = $p.MainWindowTitle; $p.Kill() }
Check 'process starts and stays alive' $alive ("title='" + $title + "'")
Check 'window title is the expected one' ($title -match 'AEC') ''

# ---------------------------------------------------------------- scratch
Get-ChildItem $scratch -Filter 'verify_*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

Section 'RESULT'
if ($script:failures -eq 0) {
  Write-Host '  ALL CHECKS PASSED'
  exit 0
} else {
  Write-Host ("  {0} CHECK(S) FAILED" -f $script:failures)
  exit 1
}
