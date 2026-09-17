# Compare AEC outputs using the pure single-talk prefix (near-end digitally silent).
# During that prefix the microphone contains ONLY echo, so ERLE = mic_rms - out_rms
# is a direct, ground-truth-free measure of echo cancellation.
# Also reports near-end damage over the whole file.
param(
  [Parameter(Mandatory=$true)][string]$Mic,
  [Parameter(Mandatory=$true)][string]$NearEnd,
  [Parameter(Mandatory=$true)][string]$Out,      # ';'-separated list of wav paths
  [string]$Label = ''                            # ';'-separated labels, same order
)

$OutList = @($Out -split ';' | Where-Object { $_ -ne '' })
$LabelList = @($Label -split ';' | Where-Object { $_ -ne '' })

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
  $n = [int]($dataLen / 2)
  $s = New-Object 'double[]' $n
  for ($i = 0; $i -lt $n; $i++) { $s[$i] = [BitConverter]::ToInt16($b, $dataOff + $i * 2) / 32768.0 }
  $o = New-Object psobject
  $o | Add-Member NoteProperty Samples $s
  $o | Add-Member NoteProperty Count $n
  return $o
}
function To-Db([double]$x) { if ($x -le 1e-15) { return -240.0 }; return 20.0 * [math]::Log10($x) }
function Rms($s, [int]$from, [int]$to) {
  if ($to -le $from) { return 0.0 }
  $t = 0.0; for ($i = $from; $i -lt $to; $i++) { $t += $s[$i] * $s[$i] }
  return [math]::Sqrt($t / ($to - $from))
}

$m  = Read-Wav16Mono $Mic
$ne = Read-Wav16Mono $NearEnd

# prefix where nearend is digitally zero
$zeroEnd = 0
for ($i = 0; $i -lt $ne.Count; $i++) { if ([math]::Abs($ne.Samples[$i]) -gt 1e-9) { break }; $zeroEnd = $i }
# leave a margin so the adaptive filter has converged
$conv = [int](16000 * 0.5)
$pFrom = $conv
$pTo = $zeroEnd

Write-Host "================ measurement windows ================"
Write-Host ("pure-echo prefix   : [0, " + ($zeroEnd / 16000.0).ToString("F3") + " s)")
Write-Host ("measured window    : [" + ($pFrom / 16000.0).ToString("F3") + ", " + ($pTo / 16000.0).ToString("F3") + " s)  (0.5 s convergence margin skipped)")
Write-Host ""

$micPow = Rms $m.Samples $pFrom $pTo
Write-Host ("mic (echo only) RMS: " + (To-Db $micPow).ToString("F2") + " dBFS")
Write-Host ""
Write-Host "file                                       out RMS dB   ERLE dB   vs mic"
Write-Host "--------------------------------------------------------------------------"

$i = 0
foreach ($f in $OutList) {
  if (-not (Test-Path $f)) { Write-Host ("  MISSING: " + $f); $i++; continue }
  $o = Read-Wav16Mono $f
  $to = [math]::Min($pTo, $o.Count)
  $oPow = Rms $o.Samples $pFrom $to
  $erle = (To-Db $micPow) - (To-Db $oPow)
  $name = if ($LabelList.Count -gt $i) { $LabelList[$i] } else { Split-Path $f -Leaf }
  Write-Host ($name.PadRight(42) + " " + (To-Db $oPow).ToString("F2").PadLeft(10) + " " + $erle.ToString("F2").PadLeft(10) + "   " + ((To-Db $oPow) - (To-Db $micPow)).ToString("F2").PadLeft(8))
  $i++
}

Write-Host ""
Write-Host "ERLE = mic_echo_RMS - out_RMS over the pure-echo window."
Write-Host "Higher is better. The theoretical ceiling is set by how much of the mic is echo."
