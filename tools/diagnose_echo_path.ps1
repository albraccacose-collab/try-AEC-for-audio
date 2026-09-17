# Diagnostic: characterize the ref/mic relationship before judging AEC quality (read-only)
param(
  [Parameter(Mandatory=$true)][string]$Ref,
  [Parameter(Mandatory=$true)][string]$Mic,
  [string]$Out,
  [int]$MaxLagMs = 1500
)

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
  $sr = [BitConverter]::ToUInt32($b, $fmt + 4)
  $n = [int]($dataLen / 2)
  $s = New-Object 'double[]' $n
  for ($i = 0; $i -lt $n; $i++) { $s[$i] = [BitConverter]::ToInt16($b, $dataOff + $i * 2) / 32768.0 }
  $o = New-Object psobject
  $o | Add-Member NoteProperty Samples $s
  $o | Add-Member NoteProperty Rate $sr
  $o | Add-Member NoteProperty Count $n
  return $o
}

function To-Db([double]$x) { if ($x -le 1e-12) { return -240.0 }; return 20.0 * [math]::Log10($x) }

function Get-CorrAtLag($a, $b, [int]$from, [int]$to, [int]$lag, [int]$decim) {
  $num = 0.0; $da = 0.0; $db = 0.0
  $lo = [math]::Max($from, $from + $lag); $hi = [math]::Min($to, $to + $lag)
  if (($hi - $lo) -lt 400) { return 0.0 }
  for ($i = $lo; $i -lt $hi; $i += $decim) {
    $x = $a[$i]; $y = $b[$i - $lag]
    $num += $x * $y; $da += $x * $x; $db += $y * $y
  }
  if ($da -le 0 -or $db -le 0) { return 0.0 }
  return $num / [math]::Sqrt($da * $db)
}

function Get-Rms($s, [int]$from, [int]$to) {
  $sum = 0.0
  for ($i = $from; $i -lt $to; $i++) { $sum += $s[$i] * $s[$i] }
  return [math]::Sqrt($sum / ($to - $from))
}

function Get-MaxAbs($s, [int]$from, [int]$to) {
  $mx = 0.0
  for ($i = $from; $i -lt $to; $i++) { $a = [math]::Abs($s[$i]); if ($a -gt $mx) { $mx = $a } }
  return $mx
}

$r = Read-Wav16Mono $Ref
$m = Read-Wav16Mono $Mic
$o = $null
if ($Out -and (Test-Path $Out)) { $o = Read-Wav16Mono $Out }

$n = [math]::Min($r.Count, $m.Count)
$fs = $r.Rate
$decim = 4

Write-Host "================ A. sample statistics ================"
Write-Host ("ref : n=" + $r.Count + "  rms=" + (To-Db (Get-Rms $r.Samples 0 $r.Count)).ToString("F2") + " dBFS  peak=" + (To-Db (Get-MaxAbs $r.Samples 0 $r.Count)).ToString("F2") + " dBFS")
Write-Host ("mic : n=" + $m.Count + "  rms=" + (To-Db (Get-Rms $m.Samples 0 $m.Count)).ToString("F2") + " dBFS  peak=" + (To-Db (Get-MaxAbs $m.Samples 0 $m.Count)).ToString("F2") + " dBFS")
if ($o) { Write-Host ("out : n=" + $o.Count + "  rms=" + (To-Db (Get-Rms $o.Samples 0 $o.Count)).ToString("F2") + " dBFS  peak=" + (To-Db (Get-MaxAbs $o.Samples 0 $o.Count)).ToString("F2") + " dBFS") }

Write-Host ""
Write-Host "================ B. corr(mic|ref) vs lag  (coarse, decim=" + $decim + ") ================"
Write-Host "positive lag = mic delayed relative to ref"
Write-Host "   lag ms |    corr"
$maxLag = [int]($fs * $MaxLagMs / 1000.0)
$step = 20 * $decim
$prof = New-Object System.Collections.ArrayList
for ($lag = -$maxLag; $lag -le $maxLag; $lag += $step) {
  $c = Get-CorrAtLag $r.Samples $m.Samples 0 $n $lag $decim
  [void]$prof.Add((New-Object psobject | Add-Member NoteProperty Lag $lag -PassThru | Add-Member NoteProperty Corr $c -PassThru))
}
$best = $prof | Sort-Object { [math]::Abs($_.Corr) } -Descending | Select-Object -First 6
foreach ($p in $best) {
  Write-Host (($p.Lag / $fs * 1000.0).ToString("F1").PadLeft(9) + " | " + $p.Corr.ToString("F4").PadLeft(8))
}

Write-Host ""
Write-Host "================ C. corr at a few fixed lags ================"
foreach ($lagMs in @(-100, -50, -20, -10, 0, 10, 20, 50, 100, 200, 500)) {
  $lag = [int]($lagMs * $fs / 1000.0)
  $c = Get-CorrAtLag $r.Samples $m.Samples 0 $n $lag $decim
  Write-Host ($lagMs.ToString().PadLeft(6) + " ms : corr = " + $c.ToString("F4"))
}

Write-Host ""
Write-Host "================ D. energy ratio mic/ref per 500ms ================"
Write-Host "  t (s) |  ref dB |  mic dB | mic-ref dB"
$seg = [int]($fs / 2)
$nseg = [int]([math]::Floor($n / $seg))
for ($k = 0; $k -lt [math]::Min(12, $nseg); $k++) {
  $f = $k * $seg; $t = $f + $seg
  $dr = To-Db (Get-Rms $r.Samples $f $t)
  $dm = To-Db (Get-Rms $m.Samples $f $t)
  Write-Host (($f / $fs).ToString("F1").PadLeft(7) + " | " + $dr.ToString("F1").PadLeft(7) + " | " + $dm.ToString("F1").PadLeft(7) + " | " + ($dm - $dr).ToString("F1").PadLeft(10))
}

Write-Host ""
Write-Host "================ E. correlation matrix (global) ================"
$cRM = Get-CorrAtLag $r.Samples $m.Samples 0 $n 0 $decim
Write-Host ("corr(ref, mic) @0        = " + $cRM.ToString("F4"))
if ($o) {
  $cRO = Get-CorrAtLag $r.Samples $o.Samples 0 $n 0 $decim
  $cMO = Get-CorrAtLag $m.Samples $o.Samples 0 $n 0 $decim
  Write-Host ("corr(ref, out) @0        = " + $cRO.ToString("F4"))
  Write-Host ("corr(mic, out) @0        = " + $cMO.ToString("F4") + "   (how much of mic survived)")
}
