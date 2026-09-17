# Final check: is there ANY linear echo path between ref and mic? (read-only)
# Coarse-to-fine alignment search (fast), then block-wise least-squares fit.
param(
  [Parameter(Mandatory=$true)][string]$Ref,
  [Parameter(Mandatory=$true)][string]$Mic,
  [int]$MaxLagMs = 300,
  [int]$BlockMs = 100
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
  if (($hi - $lo) -lt (200 * $decim)) { return 0.0 }
  for ($i = $lo; $i -lt $hi; $i += $decim) {
    $x = $a[$i]; $y = $b[$i - $lag]
    $num += $x * $y; $da += $x * $x; $db += $y * $y
  }
  if ($da -le 0 -or $db -le 0) { return 0.0 }
  return $num / [math]::Sqrt($da * $db)
}

$r = Read-Wav16Mono $Ref
$m = Read-Wav16Mono $Mic
$fs = $r.Rate
$n = [math]::Min($r.Count, $m.Count)

# ---- stage 1: coarse scan, decim 8, lag step 8 ----
$decimC = 8; $stepC = 8
$maxLag = [int]($fs * $MaxLagMs / 1000.0)
$bestC = 0.0; $bestLagC = 0
for ($lag = -$maxLag; $lag -le $maxLag; $lag += $stepC) {
  $c = Get-CorrAtLag $r.Samples $m.Samples 0 $n $lag $decimC
  if ([math]::Abs($c) -gt [math]::Abs($bestC)) { $bestC = $c; $bestLagC = $lag }
}

# ---- stage 2: fine scan around coarse peak, decim 4, lag step 1 ----
$decimF = 4
$lo = $bestLagC - $stepC; $hi = $bestLagC + $stepC
$bestF = 0.0; $bestLag = $bestLagC
for ($lag = $lo; $lag -le $hi; $lag++) {
  if ([math]::Abs($lag) -gt $maxLag) { continue }
  $c = Get-CorrAtLag $r.Samples $m.Samples 0 $n $lag $decimF
  if ([math]::Abs($c) -gt [math]::Abs($bestF)) { $bestF = $c; $bestLag = $lag }
}

Write-Host "================ best global alignment ================"
Write-Host ("coarse peak : corr = " + $bestC.ToString("F4") + " at lag " + $bestLagC + " (" + ($bestLagC / $fs * 1000.0).ToString("F1") + " ms)")
Write-Host ("refined     : corr = " + $bestF.ToString("F4") + " at lag " + $bestLag + " (" + ($bestLag / $fs * 1000.0).ToString("F2") + " ms)")
Write-Host ("|corr| max  : " + [math]::Abs($bestF).ToString("F4"))

# ---- stage 3: per-block LS fit at refined alignment ----
Write-Host ""
Write-Host "================ per-block LS fit at refined alignment ================"
Write-Host "real echo path => stable slope, ERL approx -5..-40 dB"
Write-Host "  t (s) |   slope | ERL dB |   corr"
$blk = [int]($fs * $BlockMs / 1000.0)
$start = [math]::Max(0, $bestLag)
$nb = [int]([math]::Floor(($n - $start) / $blk))
$slopes = New-Object System.Collections.ArrayList
$erls = New-Object System.Collections.ArrayList
for ($k = 0; $k -lt $nb; $k++) {
  $f = $start + $k * $blk; $t = $f + $blk
  $num = 0.0; $den = 0.0; $cN = 0.0; $cD1 = 0.0; $cD2 = 0.0
  for ($i = $f; $i -lt $t; $i++) {
    $x = $r.Samples[$i]; $y = $m.Samples[$i - $bestLag]
    $num += $x * $y; $den += $x * $x
    $cN += $x * $y; $cD1 += $x * $x; $cD2 += $y * $y
  }
  if ($den -le 0) { continue }
  $a = $num / $den
  $res = 0.0; $tot = 0.0
  for ($i = $f; $i -lt $t; $i++) {
    $x = $r.Samples[$i]; $y = $m.Samples[$i - $bestLag]
    $e = $y - $a * $x
    $res += $e * $e; $tot += $y * $y
  }
  [void]$slopes.Add($a)
  $erl = To-Db ([math]::Sqrt($res / $tot))
  [void]$erls.Add($erl)
  $cc = 0.0
  if ($cD1 -gt 0 -and $cD2 -gt 0) { $cc = $cN / [math]::Sqrt($cD1 * $cD2) }
  if ($k -lt 15) {
    Write-Host (($f / $fs).ToString("F2").PadLeft(7) + " | " + $a.ToString("F4").PadLeft(7) + " | " + $erl.ToString("F1").PadLeft(6) + " | " + $cc.ToString("F4"))
  }
}

# ---- verdict ----
Write-Host ""
Write-Host "================ verdict ================"
$erlArr = @($erls)
$slopeArr = @($slopes)
$erlMean = ($erlArr | Measure-Object -Average).Average
$erlMin = ($erlArr | Measure-Object -Minimum).Minimum
$erlMax = ($erlArr | Measure-Object -Maximum).Maximum
$slopeMean = ($slopeArr | Measure-Object -Average).Average
$slopeStd = 0.0
if ($slopeArr.Count -gt 1) {
  $acc = 0.0
  foreach ($s in $slopeArr) { $acc += ($s - $slopeMean) * ($s - $slopeMean) }
  $slopeStd = [math]::Sqrt($acc / ($slopeArr.Count - 1))
}
Write-Host ("blocks analysed  : " + $slopeArr.Count)
Write-Host ("|corr| max       : " + [math]::Abs($bestF).ToString("F4"))
Write-Host ("ERL mean/min/max : " + $erlMean.ToString("F1") + " / " + $erlMin.ToString("F1") + " / " + $erlMax.ToString("F1") + " dB")
Write-Host ("slope mean/std   : " + $slopeMean.ToString("F5") + " / " + $slopeStd.ToString("F5"))
Write-Host ""
if ([math]::Abs($bestF) -lt 0.2) {
  Write-Host "VERDICT: NO detectable linear echo path between ref and mic."
  Write-Host "         These files are NOT a valid echo-cancellation test pair."
} else {
  Write-Host "VERDICT: a coherent linear relationship exists; this pair may be usable."
}
