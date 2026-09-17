# Bit-level and segment-level comparison of two 16-bit mono wav files. Read-only.
param(
  [Parameter(Mandatory=$true)][string]$A,
  [Parameter(Mandatory=$true)][string]$B,
  [int]$SegMs = 200
)

$ErrorActionPreference = 'Stop'

function Get-Pcm([string]$path) {
  $fs = [System.IO.File]::OpenRead($path)
  try {
    $br = New-Object System.IO.BinaryReader($fs)
    $null = $br.ReadBytes(12)                     # RIFF....WAVE
    $fmt = $null; $dataOff = 0; $dataLen = 0
    while ($fs.Position -lt $fs.Length - 8) {
      $idBytes = $br.ReadBytes(4)
      $id = [System.Text.Encoding]::ASCII.GetString($idBytes)
      $sz = $br.ReadUInt32()
      if ($id -eq 'fmt ') { $fmt = $fs.Position }
      if ($id -eq 'data') { $dataLen = $sz; $dataOff = $fs.Position; break }
      $fs.Position = $fs.Position + $sz + ($sz % 2)
    }
    if ($null -eq $fmt) { throw "no fmt chunk in $path" }
    $fs.Position = $dataOff
    $raw = $br.ReadBytes([int]$dataLen)
    $n = [int]($raw.Length / 2)
    $s = New-Object 'double[]' $n
    for ($i = 0; $i -lt $n; $i++) {
      $s[$i] = [BitConverter]::ToInt16($raw, $i * 2) / 32768.0
    }
    return , $s
  } finally {
    $fs.Dispose()
  }
}

function To-Db([double]$x) { if ($x -le 1e-15) { return -240.0 }; return 20.0 * [math]::Log10($x) }
function Get-Rms([double[]]$s, [int]$from, [int]$to) {
  if ($to -le $from) { return 0.0 }
  $t = 0.0
  for ($i = $from; $i -lt $to; $i++) { $t += $s[$i] * $s[$i] }
  return [math]::Sqrt($t / ($to - $from))
}

$sa = Get-Pcm $A
$sb = Get-Pcm $B
$na = [int]$sa.Length
$nb = [int]$sb.Length
$n  = [int][math]::Min($na, $nb)

Write-Host "================ inputs ================"
Write-Host ("A: " + (Split-Path $A -Leaf) + "  samples=" + $na)
Write-Host ("B: " + (Split-Path $B -Leaf) + "  samples=" + $nb)
Write-Host ("compared: " + $n)

Write-Host ""
Write-Host "================ pair-wise difference ================"
$diffCount = 0; $maxDiff = 0.0; $sumSq = 0.0; $sumA = 0.0; $sumB = 0.0
for ($i = 0; $i -lt $n; $i++) {
  $va = $sa[$i]; $vb = $sb[$i]
  $d = $va - $vb
  if ([math]::Abs($d) -gt 1e-9) { $diffCount++ }
  $ad = [math]::Abs($d)
  if ($ad -gt $maxDiff) { $maxDiff = $ad }
  $sumSq += $d * $d; $sumA += $va * $va; $sumB += $vb * $vb
}
$rmsD = [math]::Sqrt($sumSq / $n)
$rmsA = [math]::Sqrt($sumA / $n)
$rmsB = [math]::Sqrt($sumB / $n)

Write-Host ("samples differing : " + $diffCount + " / " + $n + "  (" + (100.0 * $diffCount / $n).ToString("F2") + "%)")
Write-Host ("max |A-B|         : " + $maxDiff.ToString("F6") + "  (" + (To-Db $maxDiff).ToString("F2") + " dB)")
Write-Host ("RMS(A-B)          : " + (To-Db $rmsD).ToString("F2") + " dBFS")
Write-Host ("RMS(A)            : " + (To-Db $rmsA).ToString("F2") + " dBFS")
Write-Host ("RMS(B)            : " + (To-Db $rmsB).ToString("F2") + " dBFS")
Write-Host ("residual rel. A   : " + ((To-Db $rmsD) - (To-Db $rmsA)).ToString("F2") + " dB")

Write-Host ""
Write-Host "================ first 15 differing pairs ================"
$shown = 0
for ($i = 0; $i -lt $n -and $shown -lt 15; $i++) {
  $va = $sa[$i]; $vb = $sb[$i]
  if ([math]::Abs($va - $vb) -gt 1e-9) {
    Write-Host ("  idx " + $i.ToString().PadLeft(7) + " : A=" + $va.ToString("F6").PadLeft(12) + "  B=" + $vb.ToString("F6").PadLeft(12) + "  d=" + ($va - $vb).ToString("F6"))
    $shown++
  }
}

Write-Host ""
Write-Host "================ per-segment RMS (first 25) ================"
$seg = [int](16000 * $SegMs / 1000)
$nseg = [int][math]::Floor($n / $seg)
Write-Host " t (s) |    A dB |    B dB |  A-B dB"
for ($k = 0; $k -lt [math]::Min(25, $nseg); $k++) {
  $f = $k * $seg; $t = $f + $seg
  $da = To-Db (Get-Rms $sa $f $t)
  $db = To-Db (Get-Rms $sb $f $t)
  Write-Host (($f / 16000.0).ToString("F2").PadLeft(6) + " | " + $da.ToString("F1").PadLeft(7) + " | " + $db.ToString("F1").PadLeft(7) + " | " + ($da - $db).ToString("F2").PadLeft(8))
}
