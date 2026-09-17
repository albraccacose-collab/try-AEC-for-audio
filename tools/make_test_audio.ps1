# Generates a self-contained echo-cancellation test pair with a KNOWN echo path.
#
# Why this exists: the repo must not depend on third-party audio. Microsoft's
# AEC-Challenge "real" recordings turned out to be unusable for AEC validation
# (that machine's audio DSP had already removed the echo: measured
# corr(mic,ref) peak was only 0.0826 and ERL -0.5 dB). So we synthesise our own
# pair where the ground truth is known by construction.
#
# Produces, in -OutDir:
#   synth_farend_16k.wav   far-end / reference  -> feed as "参考音频"
#   synth_mic_16k.wav      simulated microphone -> feed as "麦克风录音"
#   synth_nearend_16k.wav  clean near-end target (for ERLE measurement only)
#
# Construction:
#   mic = echo + nearend + noise,   echo = farend * RIR
#   RIR = direct path at 32 ms plus 3 decaying reflections (ERL near -12 dB)
#   far-end : speech-like AM multi-tone, active 0..10 s with a couple of pauses
#   near-end: digitally silent for the first 3 s (pure single-talk window, so
#             ERLE there is unambiguous), active 3..8 s
#
# Uses System.Random with a fixed seed: reproducible on a given .NET runtime.
param(
  [string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'testdata'),
  [int]$Seconds = 10,
  [int]$Seed = 20240917
)

$ErrorActionPreference = 'Stop'
$fs = 16000
$n = $fs * $Seconds
$rng = New-Object System.Random($Seed)

function Write-Wav16Mono([string]$path, [double[]]$samples) {
  $byteCount = $samples.Length * 2
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  try {
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
    $bw.Write([uint32](36 + $byteCount))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('WAVE'))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('fmt '))
    $bw.Write([uint32]16)
    $bw.Write([uint16]1)          # PCM
    $bw.Write([uint16]1)          # mono
    $bw.Write([uint32]$fs)
    $bw.Write([uint32]($fs * 2))  # byte rate
    $bw.Write([uint16]2)          # block align
    $bw.Write([uint16]16)         # bits per sample
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
    $bw.Write([uint32]$byteCount)
    foreach ($v in $samples) {
      $x = [int][math]::Round($v)
      if ($x -gt 32767) { $x = 32767 }
      if ($x -lt -32768) { $x = -32768 }
      $bw.Write([int16]$x)
    }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($path, $ms.ToArray())
  } finally {
    $bw.Dispose()
    $ms.Dispose()
  }
}

$twopi = 2.0 * [math]::PI

# ---------------------------------------------------------------- far-end
Write-Host 'generating far-end / reference ...'
$farend = New-Object 'double[]' $n
$phase = 0.0
for ($i = 0; $i -lt $n; $i++) {
  $t = $i / [double]$fs
  $f0 = 150.0 + 40.0 * [math]::Sin($twopi * 0.31 * $t)      # pitch drift 110..190 Hz
  $phase += $twopi * $f0 / $fs
  $s = [math]::Sin($phase) `
     + 0.50 * [math]::Sin(2.0 * $phase + 0.3) `
     + 0.28 * [math]::Sin(3.0 * $phase + 1.1) `
     + 0.14 * [math]::Sin(5.0 * $phase + 2.2) `
     + 0.07 * [math]::Sin(8.0 * $phase + 0.7)
  $env = 0.55 + 0.45 * [math]::Sin($twopi * 3.7 * $t + 0.9)  # syllabic ~4 Hz
  $phrase = 0.35 + 0.65 * [math]::Sin($twopi * 0.23 * $t - 0.4)
  if ($phrase -lt 0.30) { $phrase = 0.30 }
  if (($t -gt 6.4 -and $t -lt 6.9) -or ($t -gt 8.8 -and $t -lt 9.1)) { $env = 0.0 }
  $farend[$i] = $s * $env * $phrase * 0.20
}

# ---------------------------------------------------------------- near-end
Write-Host 'generating near-end speech ...'
$nearend = New-Object 'double[]' $n
$silentUntil = [int](3.0 * $fs)
$phase2 = 0.0
for ($i = 0; $i -lt $n; $i++) {
  if ($i -lt $silentUntil) { continue }        # stays exactly 0.0
  $t = ($i - $silentUntil) / [double]$fs
  $f0 = 205.0 + 55.0 * [math]::Sin($twopi * 0.44 * $t + 1.7)
  $phase2 += $twopi * $f0 / $fs
  $s = [math]::Sin($phase2) `
     + 0.42 * [math]::Sin(2.0 * $phase2 + 0.8) `
     + 0.22 * [math]::Sin(4.0 * $phase2 + 1.9)
  $env = 0.5 + 0.5 * [math]::Sin($twopi * 4.3 * $t + 0.2)
  if ($i -gt [int](8.0 * $fs)) { $env = 0.0 }
  $nearend[$i] = $s * $env * 0.16
}

# ---------------------------------------------------------------- echo path
Write-Host 'applying synthetic echo path ...'
$taps = @(
  @{ Delay = [int](0.032 * $fs); Gain =  0.30 },
  @{ Delay = [int](0.048 * $fs); Gain = -0.13 },
  @{ Delay = [int](0.071 * $fs); Gain =  0.07 },
  @{ Delay = [int](0.095 * $fs); Gain = -0.04 }
)
$echo = New-Object 'double[]' $n
foreach ($tap in $taps) {
  $d = [int]$tap.Delay
  $g = [double]$tap.Gain
  for ($i = $d; $i -lt $n; $i++) { $echo[$i] += $g * $farend[$i - $d] }
}

# ---------------------------------------------------------------- mic
Write-Host 'mixing microphone signal ...'
$mic = New-Object 'double[]' $n
for ($i = 0; $i -lt $n; $i++) {
  $noise = ($rng.NextDouble() - 0.5) * 2.0 * 0.0015   # ~ -56 dBFS floor
  $mic[$i] = $echo[$i] + $nearend[$i] + $noise
}

# ---------------------------------------------------------------- write
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
function To-S16([double[]]$x) {
  $o = New-Object 'double[]' $x.Length
  for ($i = 0; $i -lt $x.Length; $i++) { $o[$i] = $x[$i] * 32768.0 }
  return , $o
}

$pFar = Join-Path $OutDir 'synth_farend_16k.wav'
$pMic = Join-Path $OutDir 'synth_mic_16k.wav'
$pNe  = Join-Path $OutDir 'synth_nearend_16k.wav'
Write-Wav16Mono $pFar (To-S16 $farend)
Write-Wav16Mono $pMic (To-S16 $mic)
Write-Wav16Mono $pNe  (To-S16 $nearend)

# ---------------------------------------------------------------- report
function Get-Rms([double[]]$s, [int]$from, [int]$to) {
  $t = 0.0
  for ($i = $from; $i -lt $to; $i++) { $t += $s[$i] * $s[$i] }
  return [math]::Sqrt($t / ($to - $from))
}
function To-Db([double]$x) { if ($x -le 1e-12) { return -240.0 }; return 20.0 * [math]::Log10($x) }

$from = [int](0.5 * $fs)         # skip 0.5 s so the adaptive filter can converge
$to = $silentUntil
$micRms  = Get-Rms $mic $from $to
$farRms  = Get-Rms $farend $from $to
$echoRms = Get-Rms $echo $from $to

Write-Host ''
Write-Host '================ generated ================'
foreach ($p in @($pFar, $pMic, $pNe)) {
  $fi = Get-Item $p
  Write-Host ("  {0,-24} {1,8} bytes" -f $fi.Name, $fi.Length)
}
Write-Host ''
Write-Host '================ expected characteristics ================'
Write-Host ("  format                        : {0} Hz / mono / 16 bit, {1} s" -f $fs, $Seconds)
Write-Host ("  pure single-talk window       : 0.500 s .. {0:F3} s" -f ($silentUntil / [double]$fs))
Write-Host ("  far-end RMS there             : {0,7:F2} dBFS" -f (To-Db $farRms))
Write-Host ("  echo    RMS there             : {0,7:F2} dBFS" -f (To-Db $echoRms))
Write-Host ("  mic     RMS there             : {0,7:F2} dBFS" -f (To-Db $micRms))
Write-Host ("  echo-to-farend gain           : {0,7:F2} dB" -f ((To-Db $echoRms) - (To-Db $farRms)))
Write-Host ("  ERL (echo vs mic)             : {0,7:F2} dB" -f ((To-Db $echoRms) - (To-Db $micRms)))
Write-Host ''
Write-Host '  A working AEC should reach roughly 25-35 dB ERLE inside that window.'
Write-Host ''
