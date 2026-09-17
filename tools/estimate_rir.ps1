# Wide, fine-grained echo delay search restricted to the pure-single-talk prefix.
# Read-only.
param(
  [Parameter(Mandatory=$true)][string]$Ref,
  [Parameter(Mandatory=$true)][string]$Mic,
  [Parameter(Mandatory=$true)][string]$NearEnd,
  [double]$PrefixSec = 0,          # 0 = auto-detect from NearEnd leading zeros
  [int]$MaxLagMs = 3000
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

if ($PrefixSec -gt 0) {
  $segEnd = [int]($fs * $PrefixSec)
} else {
  $segEnd = 0
  for ($i = 0; $i -lt $n; $i++) { if ([math]::Abs($ne.Samples[$i]) -gt 1e-9) { break }; $segEnd = $i }
}
Write-Host ("prefix used : [0, " + ($segEnd / $fs).ToString("F3") + " s)  (" + $segEnd + " samples)")

# ---- coherent averaging: estimate the impulse response up to kRirMs ----
# h[k] = sum_t ref[t] * mic[t+k] / sum_t ref[t]^2   (k >= 0 means mic delayed)
$kRirMs = 400
$kMax = [int]($fs * $kRirMs / 1000.0)
$den = 0.0
for ($t = 0; $t -lt $segEnd - $kMax; $t++) { $den += $r.Samples[$t] * $r.Samples[$t] }
if ($den -le 0) { Write-Host "no reference energy in prefix"; exit 1 }

Write-Host ""
Write-Host "================ cross-correlation gain profile h[k] (0..$kRirMs ms) ================"
$h = New-Object 'double[]' ($kMax + 1)
$hMax = 0.0; $hArg = 0
for ($k = 0; $k -le $kMax; $k++) {
  $acc = 0.0
  for ($t = 0; $t -lt $segEnd - $kMax; $t++) { $acc += $r.Samples[$t] * $m.Samples[$t + $k] }
  $h[$k] = $acc / $den
  if ([math]::Abs($h[$k]) -gt $hMax) { $hMax = [math]::Abs($h[$k]); $hArg = $k }
}
Write-Host ("peak |h| = " + $hMax.ToString("F6") + " (" + (To-Db $hMax).ToString("F1") + " dB) at k = " + $hArg + " samples (" + ($hArg / $fs * 1000.0).ToString("F2") + " ms)")

Write-Host ""
Write-Host "first 40 taps (every 4th), value and dB:"
for ($k = 0; $k -le [math]::Min(160, $kMax); $k += 4) {
  Write-Host ("  k=" + $k.ToString().PadLeft(4) + " (" + ($k / $fs * 1000.0).ToString("F2").PadLeft(6) + " ms) : " + $h[$k].ToString("F7").PadLeft(12) + "  " + (To-Db ([math]::Abs($h[$k]))).ToString("F1").PadLeft(7) + " dB")
}

# ---- ERL from the estimated IR ----
# echo energy predicted = |h|^2 * ref energy ; measure over prefix
$echoPred = 0.0
for ($k = 0; $k -le $kMax; $k++) { $echoPred += $h[$k] * $h[$k] }
$refPow = $den / ($segEnd - $kMax)
$echoPow = $echoPred * $refPow
$micPow = 0.0
for ($t = 0; $t -lt $segEnd - $kMax; $t++) { $micPow += $m.Samples[$t] * $m.Samples[$t] }
$micPow = $micPow / ($segEnd - $kMax)

Write-Host ""
Write-Host "================ echo path summary ================"
Write-Host ("ref power        : " + (To-Db ([math]::Sqrt($refPow))).ToString("F2") + " dBFS")
Write-Host ("mic power        : " + (To-Db ([math]::Sqrt($micPow))).ToString("F2") + " dBFS")
Write-Host ("predicted echo   : " + (To-Db ([math]::Sqrt($echoPow))).ToString("F2") + " dBFS")
if ($micPow -gt 0) {
  Write-Host ("ERL (IR-based)   : " + (10.0 * [math]::Log10($echoPow / $micPow)).ToString("F2") + " dB")
  Write-Host ("  -> means echo accounts for " + (100.0 * $echoPow / $micPow).ToString("F1") + "% of mic power in prefix")
}
