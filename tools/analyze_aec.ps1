# AEC output quality analysis (read-only; writes nothing)
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\analyze_aec.ps1 `
#       -Ref <ref.wav> -Mic <mic.wav> -Out <out.wav> [-Linear <linear.wav>]
param(
  [Parameter(Mandatory=$true)][string]$Ref,
  [Parameter(Mandatory=$true)][string]$Mic,
  [Parameter(Mandatory=$true)][string]$Out,
  [string]$Linear
)

# ---------- WAV reading (16-bit mono PCM only) ----------
function Read-Wav16Mono([string]$path) {
  $b = [System.IO.File]::ReadAllBytes($path)
  $pos = 12; $fmt = $null; $dataOff = 0; $dataLen = 0
  while ($pos -lt $b.Length - 8) {
    $id = [System.Text.Encoding]::ASCII.GetString($b, $pos, 4)
    $sz = [BitConverter]::ToUInt32($b, $pos + 4)
    if ($id -eq 'fmt ') { $fmt = $pos + 8 }
    if ($id -eq 'data') { $dataLen = $sz; $dataOff = $pos + 8; break }
    $pos += 8 + $sz + ($sz % 2)
  }
  if ($null -eq $fmt) { throw "no fmt chunk: $path" }
  $sr   = [BitConverter]::ToUInt32($b, $fmt + 4)
  $ch   = [BitConverter]::ToUInt16($b, $fmt + 2)
  $bits = [BitConverter]::ToUInt16($b, $fmt + 14)
  if ($ch -ne 1 -or $bits -ne 16) { throw "not 16-bit mono: $path (ch=$ch bits=$bits)" }
  $n = [int]($dataLen / 2)
  $s = New-Object 'double[]' $n
  for ($i = 0; $i -lt $n; $i++) { $s[$i] = [BitConverter]::ToInt16($b, $dataOff + $i * 2) / 32768.0 }
  $o = New-Object psobject
  $o | Add-Member NoteProperty Samples $s
  $o | Add-Member NoteProperty Rate $sr
  $o | Add-Member NoteProperty Count $n
  return $o
}

function Get-Rms($s, [int]$from, [int]$to) {
  $sum = 0.0
  for ($i = $from; $i -lt $to; $i++) { $sum += $s[$i] * $s[$i] }
  return [math]::Sqrt($sum / ($to - $from))
}

function To-Db([double]$x) {
  if ($x -le 1e-12) { return -240.0 }
  return 20.0 * [math]::Log10($x)
}

function Get-NormalizedCorr($a, $b, [int]$from, [int]$to, [int]$maxLag, [int]$decim) {
  # normalized cross-correlation peak over lag in [-maxLag, maxLag] *samples*
  # (a = reference, b = signal; b is shifted relative to a)
  $bestLag = 0; $best = 0.0
  for ($lag = -$maxLag; $lag -le $maxLag; $lag++) {
    $num = 0.0; $da = 0.0; $db = 0.0
    $lo = [math]::Max($from, $from + $lag)
    $hi = [math]::Min($to, $to + $lag)
    if (($hi - $lo) -lt (1000 * $decim)) { continue }
    for ($i = $lo; $i -lt $hi; $i += $decim) {
      $x = $a[$i]; $y = $b[$i - $lag]
      $num += $x * $y; $da += $x * $x; $db += $y * $y
    }
    if ($da -le 0 -or $db -le 0) { continue }
    $c = $num / [math]::Sqrt($da * $db)
    if ([math]::Abs($c) -gt [math]::Abs($best)) { $best = $c; $bestLag = $lag }
  }
  $o = New-Object psobject
  $o | Add-Member NoteProperty Corr $best
  $o | Add-Member NoteProperty Lag $bestLag
  return $o
}

function Get-ResidualDb($refS, $sigS, [int]$from, [int]$to, [int]$lag) {
  # least-squares projection of ref onto sig, then residual energy ratio in dB
  $num = 0.0; $den = 0.0
  for ($i = $from; $i -lt $to; $i++) { $x = $refS[$i]; $num += $x * $sigS[$i - $lag]; $den += $x * $x }
  if ($den -le 0) { return 0.0 }
  $a = $num / $den
  $res = 0.0; $tot = 0.0
  for ($i = $from; $i -lt $to; $i++) {
    $y = $sigS[$i - $lag]
    $e = $y - $a * $refS[$i]
    $res += $e * $e; $tot += $y * $y
  }
  if ($tot -le 0) { return 0.0 }
  return 10.0 * [math]::Log10($res / $tot)
}

function Get-SegmentRms($s, [int]$seg) {
  $res = New-Object System.Collections.ArrayList
  for ($i = 0; ($i + $seg) -le $s.Count; $i += $seg) { [void]$res.Add((Get-Rms $s $i ($i + $seg))) }
  return $res
}

# ---------- load ----------
$r = Read-Wav16Mono $Ref
$m = Read-Wav16Mono $Mic
$o = Read-Wav16Mono $Out
$l = $null
if ($Linear -and (Test-Path $Linear)) { $l = Read-Wav16Mono $Linear }

$n = [math]::Min([math]::Min($r.Count, $m.Count), $o.Count)

Write-Host "================ sample counts ================"
Write-Host ("ref    : " + $r.Count + "  (" + $r.Rate + " Hz)")
Write-Host ("mic    : " + $m.Count + "  (" + $m.Rate + " Hz)")
Write-Host ("out    : " + $o.Count + "  (" + $o.Rate + " Hz)")
if ($l) { Write-Host ("linear : " + $l.Count + "  (" + $l.Rate + " Hz)") }

# ---------- global RMS ----------
$rmsR = Get-Rms $r.Samples 0 $n
$rmsM = Get-Rms $m.Samples 0 $n
$rmsO = Get-Rms $o.Samples 0 $n

Write-Host ""
Write-Host "================ global RMS ================"
Write-Host ("ref     : " + (To-Db $rmsR).ToString("F2") + " dBFS")
Write-Host ("mic     : " + (To-Db $rmsM).ToString("F2") + " dBFS")
Write-Host ("out     : " + (To-Db $rmsO).ToString("F2") + " dBFS")
Write-Host ("out-mic : " + ((To-Db $rmsO) - (To-Db $rmsM)).ToString("F2") + " dB")
if ($l) {
  $ln = [math]::Min($l.Count, $n)
  $rmsL = Get-Rms $l.Samples 0 $ln
  Write-Host ("linear  : " + (To-Db $rmsL).ToString("F2") + " dBFS")
}

# ---------- echo correlation ----------
# decimate by 4 for speed; search +/-50 ms at 16 kHz -> maxLag = 200 * decim
$decim = 4
$maxLag = 200 * $decim
Write-Host ""
Write-Host "================ echo residual: corr(mic|ref) vs corr(out|ref) ================"
Write-Host "(search window +/- 50 ms, decimated 4x)"

$cM = Get-NormalizedCorr $r.Samples $m.Samples 0 $n $maxLag $decim
$cO = Get-NormalizedCorr $r.Samples $o.Samples 0 $n $maxLag $decim

$lagMsM = $cM.Lag / $r.Rate * 1000.0
$lagMsO = $cO.Lag / $r.Rate * 1000.0
Write-Host ("mic vs ref : corr = " + $cM.Corr.ToString("F4") + "   lag = " + $cM.Lag + " smp (" + $lagMsM.ToString("F2") + " ms)")
Write-Host ("out vs ref : corr = " + $cO.Corr.ToString("F4") + "   lag = " + $cO.Lag + " smp (" + $lagMsO.ToString("F2") + " ms)")

$suppression = 0.0
if ([math]::Abs($cM.Corr) -gt 1e-9) {
  $suppression = 20.0 * [math]::Log10([math]::Abs($cO.Corr) / [math]::Abs($cM.Corr))
}
Write-Host ("echo suppression (corr drop) = " + $suppression.ToString("F2") + " dB")

# ---------- least-squares residual ----------
Write-Host ""
Write-Host "================ linear-projection residual (lower = more ref removed) ================"
$eM = Get-ResidualDb $r.Samples $m.Samples 0 $n $cM.Lag
$eO = Get-ResidualDb $r.Samples $o.Samples 0 $n $cO.Lag
Write-Host ("mic residual : " + $eM.ToString("F2") + " dB")
Write-Host ("out residual : " + $eO.ToString("F2") + " dB")
Write-Host ("improvement  : " + ($eM - $eO).ToString("F2") + " dB")

# ---------- segment curve ----------
Write-Host ""
Write-Host "================ per-100ms RMS (first 30 segments) ================"
Write-Host "seg |    ref dB |    mic dB |    out dB | out-mic dB"
$seg = [int]($r.Rate / 10)
$srM = Get-SegmentRms $m.Samples $seg
$srO = Get-SegmentRms $o.Samples $seg
$srR = Get-SegmentRms $r.Samples $seg
$cnt = [math]::Min(30, $srM.Count)
for ($i = 0; $i -lt $cnt; $i++) {
  $dR = (To-Db $srR[$i]).ToString("F1").PadLeft(9)
  $dM = (To-Db $srM[$i]).ToString("F1").PadLeft(9)
  $dO = (To-Db $srO[$i]).ToString("F1").PadLeft(9)
  $dD = ((To-Db $srO[$i]) - (To-Db $srM[$i])).ToString("F2").PadLeft(9)
  Write-Host ($i.ToString().PadLeft(3) + " | " + $dR + " | " + $dM + " | " + $dO + " | " + $dD)
}

# ---------- sanity ----------
Write-Host ""
Write-Host "================ output sanity ================"
$zeros = 0; $maxAbs = 0.0
for ($i = 0; $i -lt $n; $i++) {
  $v = $o.Samples[$i]
  if ($v -eq 0.0) { $zeros++ }
  $a = [math]::Abs($v)
  if ($a -gt $maxAbs) { $maxAbs = $a }
}
Write-Host ("out zero samples : " + $zeros + " / " + $n)
Write-Host ("out peak         : " + $maxAbs.ToString("F4") + " (" + (To-Db $maxAbs).ToString("F2") + " dBFS)")

$same = $true
$chk = [math]::Min(10000, $n)
for ($i = 0; $i -lt $chk; $i++) {
  if ($o.Samples[$i] -ne $m.Samples[$i]) { $same = $false; break }
}
Write-Host ("out identical to mic in first " + $chk + " samples? " + $same)
