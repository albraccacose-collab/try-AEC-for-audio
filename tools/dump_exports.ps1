# Dump a PE file's export table and machine type. Read-only.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\dump_exports.ps1 -Path <dll>
param(
  [Parameter(Mandatory=$true)][string]$Path,
  [string[]]$Expect
)

$b = [System.IO.File]::ReadAllBytes($Path)
$e = [BitConverter]::ToInt32($b, 0x3C)
if ([System.Text.Encoding]::ASCII.GetString($b, 0, 2) -ne 'MZ') { throw "not a PE file: $Path" }

$machine = [BitConverter]::ToUInt16($b, $e + 4)
$magic = [BitConverter]::ToUInt16($b, $e + 24)
$is64 = ($magic -eq 0x20B)
$ddOff = if ($is64) { $e + 24 + 112 } else { $e + 24 + 96 }

function RVA2Off([int]$rva) {
  $ns = [BitConverter]::ToInt16($b, $e + 6)
  $osz = [BitConverter]::ToInt16($b, $e + 20)
  $so = $e + 24 + $osz
  for ($i = 0; $i -lt $ns; $i++) {
    $s = $so + $i * 40
    $va = [BitConverter]::ToInt32($b, $s + 12)
    $vs = [BitConverter]::ToInt32($b, $s + 8)
    $rs = [BitConverter]::ToInt32($b, $s + 16)
    $rp = [BitConverter]::ToInt32($b, $s + 20)
    if ($rva -ge $va -and $rva -lt ($va + [math]::Max($vs, $rs))) { return $rp + ($rva - $va) }
  }
  return -1
}

$arch = switch ($machine) {
  0x8664 { 'x64' }
  0x14C  { 'x86' }
  0xAA64 { 'ARM64' }
  default { ('0x{0:X4}' -f $machine) }
}

Write-Host ("file       : " + (Resolve-Path $Path).Path)
Write-Host ("size       : " + $b.Length + " bytes")
Write-Host ("machine    : " + $arch)
Write-Host ("PE32+      : " + $is64)

$expRva = [BitConverter]::ToInt32($b, $ddOff)
$expSize = [BitConverter]::ToInt32($b, $ddOff + 4)

if ($expRva -eq 0) {
  Write-Host ""
  Write-Host "EXPORT DIRECTORY IS EMPTY - this DLL exports nothing."
  exit 2
}

$o = RVA2Off $expRva
$nNames = [BitConverter]::ToInt32($b, $o + 24)
$addrNames = RVA2Off ([BitConverter]::ToInt32($b, $o + 32))
$addrFuncs = RVA2Off ([BitConverter]::ToInt32($b, $o + 28))
$addrOrds = RVA2Off ([BitConverter]::ToInt32($b, $o + 36))

$names = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $nNames; $i++) {
  $nr = [BitConverter]::ToInt32($b, $addrNames + $i * 4)
  $no = RVA2Off $nr
  $sb = New-Object System.Text.StringBuilder
  while ($b[$no] -ne 0) { [void]$sb.Append([char]$b[$no]); $no++ }
  [void]$names.Add($sb.ToString())
}

Write-Host ""
Write-Host ("exported symbols (" + $names.Count + "):")
foreach ($nm in $names) {
  $mangled = $false
  if ($nm.StartsWith('?') -or $nm.Contains('@') -or $nm.Contains('@@')) { $mangled = $true }
  $flag = if ($mangled) { '  <-- MANGLED' } else { '' }
  Write-Host ("  " + $nm + $flag)
}

if ($Expect -and $Expect.Count -gt 0) {
  Write-Host ""
  Write-Host "expected symbol check:"
  $missing = 0
  foreach ($want in $Expect) {
    if ($names -contains $want) {
      Write-Host ("  OK      " + $want)
    } else {
      Write-Host ("  MISSING " + $want)
      $missing++
    }
  }
  if ($missing -gt 0) { exit 1 }
  Write-Host "all expected symbols present and unmangled."
}
