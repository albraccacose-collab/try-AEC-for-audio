# Locate the echo delay using the pure-single-talk prefix (near-end digitally silent).
# Read-only.
param(
  [Parameter(Mandatory=$true)][string]$Ref,
  [Parameter(Mandatory=$true)][string]$Mic,
  [Parameter(Mandatory=$true)][string]$NearEnd,
  [int]$MaxLagMs = 1200,
  [double]$ZeroThreshDb = -100.0
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
function To-Db([double]$x) { if ($x -le 1e-15) { return -240.0 }; return 20.0 * [math]::Log10($x) }

$r  = Read-Wav16Mono $Ref
$m  = Read-Wav16Mono $Mic
$ne = Read-Wav16Mono $NearEnd
$fs = $r.Rate
$n = [math]::Min([math]::Min($r.Count, $m.Count), $ne.Count)

# find longest leading run of near-end zero samples
$zeroEnd = 0
for ($i = 0; $i -lt $n; $i++) { if ([math]::Abs($ne.Samples[$i]) -gt 1e-9) { break }; $zeroEnd = $i }
Write-Host "================ pure single-talk prefix ================"
Write-Host ("near-end is digitally zero for samples [0, " + $zeroEnd + ") = [0, " + ($zeroEnd / $fs).ToString("F3") + " s)")
if ($zeroEnd -lt ($fs / 2)) { Write-Host "prefix too short; abort"; exit 1 }

# analyse only [0, zeroEnd), leaving room for lag
$segEnd = $zeroEnd

Write-Host ""
Write-Host "================ wide delay search (decim 8, step 8) ================"
$decim = 8
$maxLag = [int]($fs * $MaxLagMs / 1000.0)
$bestC = 0.0; $bestLag = 0
for ($lag = -$maxLag; $lag -le $maxLag; $lag += 8) {
  $lo = [math]::Max(0, $lag); $hi = [math]::Min($segEnd, $segEnd + $lag)
  $num = 0.0; $da = 0.0; $db = 0.0
  for ($i = $lo; $i -lt $hi; $i += $decim) {
    $x = $r.Samples[$i]; $y = $m.Samples[$i - $lag]
    $num += $x * $y; $da += $x * $x; $db += $y * $y
  }
  if ($da -le 0 -or $db -le 0) { continue }
  $c = $num / [math]::Sqrt($da * $db)
  if ([math]::Abs($c) -gt [math]::Abs($bestC)) { $bestC = $c; $bestLag = $lag }
}
Write-Host ("coarse best : corr = " + $bestC.ToString("F4") + " at lag " + $bestLag + " (" + ($bestLag / $fs * 1000.0).ToString("F1") + " ms)")

# fine around coarse winner
$fine = $bestLag
for ($lag = $bestLag - 8; $lag -le $bestLag + 8; $lag++) {
  $lo = [math]::Max(0, $lag); $hi = [math]::Min($segEnd, $segEnd + $lag)
  $num = 0.0; $da = 0.0; $db = 0.0
  for ($i = $lo; $i -lt $hi; $i += 2) {
    $x = $r.Samples[$i]; $y = $m.Samples[$i - $lag]
    $num += $x * $y; $da += $x * $x; $db += $y * $y
  }
  if ($da -le 0 -or $db -le 0) { continue }
  $c = $num / [math]::Sqrt($da * $db)
  if ([math]::Abs($c) -gt [math]::Abs($bestC)) { $bestC = $c; $fine = $lag }
}
$bestLag = $fine
Write-Host ("refined     : corr = " + $bestC.ToString("F4") + " at lag " + $bestLag + " (" + ($bestLag / $fs * 1000.0).ToString("F2") + " ms)")

# correlation curve summary (top 8 distinct lags)
Write-Host ""
Write-Host "================ top correlation peaks (coarse) ================"
$peaks = New-Object System.Collections.ArrayList
for ($lag = -$maxLag; $lag -le $maxLag; $lag += 8) {
  $lo = [math]::Max(0, $lag); $hi = [math]::Min($segEnd, $segEnd + $lag)
  $num = 0.0; $da = 0.0; $db = 0.0
  for ($i = $lo; $i -lt $hi; $i += $decim) {
    $x = $r.Samples[$i]; $y = $m.Samples[$i - $lag]
    $num += $x * $y; $da += $x * $x; $db += $y * $y
  }
  if ($da -le 0 -or $db -le 0) { continue }
  [void]$peaks.Add((New-Object psobject | Add-Member NoteProperty Lag $lag -PassThru | Add-Member NoteProperty Corr ($num / [math]::Sqrt($da * $db)) -PassThru))
}
foreach ($p in ($peaks | Sort-Object { [math]::Abs($_.Corr) } -Descending | Select-Object -First 8)) {
  Write-Host ("  lag " + ($p.Lag / $fs * 1000.0).ToString("F1").PadLeft(8) + " ms : corr = " + $p.Corr.ToString("F4"))
}

# gain and ERL over the prefix at the refined lag
$num = 0.0; $den = 0.0
for ($i = [math]::Max(0, $bestLag); $i -lt [math]::Min($segEnd, $segEnd + $bestLag); $i++) {
  $num += $r.Samples[$i] * $m.Samples[$i - $bestLag]; $den += $r.Samples[$i] * $r.Samples[$i]
}
$a = 0.0
if ($den -gt 0) { $a = $num / $den }
$res = 0.0; $tot = 0.0
for ($i = [math]::Max(0, $bestLag); $i -lt [math]::Min($segEnd, $segEnd + $bestLag); $i++) {
  $y = $m.Samples[$i - $bestLag]
  $e = $y - $a * $r.Samples[$i]
  $res += $e * $e; $tot += $y * $y
}

Write-Host ""
Write-Host "================ echo path over single-talk prefix ================"
Write-Host ("prefix length    : " + (($segEnd - [math]::Max(0,$bestLag)) / $fs).ToString("F3") + " s")
Write-Host ("best-fit 1-tap a : " + $a.ToString("F7") + "  (" + (To-Db ([math]::Abs($a))).ToString("F2") + " dB)")
if ($tot -gt 0) {
  Write-Host ("ERL (1-tap LS)   : " + (10.0 * [math]::Log10($res / $tot)).ToString("F2") + " dB")
}
$totR = 0.0; $totM = 0.0
for ($i = [math]::Max(0, $bestLag); $i -lt [math]::Min($segEnd, $segEnd + $bestLag); $i++) {
  $totR += $r.Samples[$i] * $r.Samples[$i]; $totM += $m.Samples[$i - $bestLag] * $m.Samples[$i - $bestLag]
}
Write-Host ("ref RMS          : " + (To-Db ([math]::Sqrt($totR / ($segEnd - [math]::Max(0,$bestLag))))).ToString("F2") + " dBFS")
Write-Host ("mic(echo) RMS    : " + (To-Db ([math]::Sqrt($totM / ($segEnd - [math]::Max(0,$bestLag))))).ToString("F2") + " dBFS")
