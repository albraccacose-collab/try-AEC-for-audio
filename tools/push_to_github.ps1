# Push this repository to GitHub as albraccacose-collab.
#
# Why a script: the first push attempt failed with
#   remote: Permission to albraccacose-collab/try-AEC-for-audio.git denied to wondersmaker.
# because Git Credential Manager had a cached credential for a DIFFERENT account.
# This walks through switching the account and verifies each step, so a wrong
# login is caught before the push instead of after.
#
# Run in YOUR OWN terminal (not through an agent) - step 2 needs an interactive
# login and possibly a browser window.

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

$repo   = 'albraccacose-collab/try-AEC-for-audio'
$remote = "https://github.com/$repo.git"
$gcm    = 'E:\git\mingw64\bin\git-credential-manager.exe'
if (-not (Test-Path $gcm)) {
  $gcm = (Get-Command git-credential-manager -ErrorAction SilentlyContinue).Source
}
if (-not $gcm) { throw 'git-credential-manager not found; adjust $gcm manually' }

Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ' step 0 / state check'
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ("  commit : " + (git log -1 --format='%h %an <%ae>'))
Write-Host ("  branch : " + (git branch --show-current))
Write-Host ("  files  : " + (git ls-files | Measure-Object).Count)
Write-Host ("  remote : " + (git remote get-url origin))

Write-Host ''
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ' step 1 / inspect the cached GitHub account'
Write-Host '==============================================================' -ForegroundColor Cyan
$raw = "protocol=https`nhost=github.com`n`n" | & $gcm get 2>&1
$cachedUser = ($raw | Where-Object { $_ -match '^username=' }) -replace '^username=', ''
if ($cachedUser) {
  Write-Host ("  cached account: " + $cachedUser) -ForegroundColor Yellow
  if ($cachedUser -ne 'albraccacose-collab') {
    Write-Host '  -> this is NOT the account that owns the repo; it must be replaced.' -ForegroundColor Yellow
  }
} else {
  Write-Host '  no cached credential for github.com'
}

Write-Host ''
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ' step 2 / sign in as the repository owner'
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host '  A browser (or device-code prompt) will open. Sign in as'
Write-Host ("  " + $repo.Split('/')[0]) -ForegroundColor Green
Write-Host '  and grant repository access.'
Write-Host ''
Read-Host '  press Enter to start the login'
& $gcm github login

Write-Host ''
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ' step 3 / verify the account actually changed'
Write-Host '==============================================================' -ForegroundColor Cyan
$raw2 = "protocol=https`nhost=github.com`n`n" | & $gcm get 2>&1
$newUser = ($raw2 | Where-Object { $_ -match '^username=' }) -replace '^username=', ''
Write-Host ("  account now: " + $newUser)
if ($newUser -ne 'albraccacose-collab') {
  Write-Host '' 
  Write-Host '  !! Still not the repo owner. Pushing now would fail again with 403.' -ForegroundColor Red
  Write-Host '     Options:' -ForegroundColor Red
  Write-Host '       a) run: git credential-manager github logout' -ForegroundColor Red
  Write-Host '          then re-run this script and sign in as the owner' -ForegroundColor Red
  Write-Host '       b) sign in to GitHub in the browser as the owner first,' -ForegroundColor Red
  Write-Host '          then re-run the login step' -ForegroundColor Red
  throw 'wrong GitHub account; aborting before push'
}

Write-Host ''
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ' step 4 / push'
Write-Host '==============================================================' -ForegroundColor Cyan
git push -u origin main
if ($LASTEXITCODE -ne 0) { throw "push failed (exit $LASTEXITCODE)" }

Write-Host ''
Write-Host '==============================================================' -ForegroundColor Green
Write-Host ' done'
Write-Host '==============================================================' -ForegroundColor Green
Write-Host ("  repository : https://github.com/" + $repo)
Write-Host ("  remote head: " + (git ls-remote --heads origin))
Write-Host ''
Write-Host '  The remote is a plain URL with no embedded token, so nothing' 
Write-Host '  secret was written into .git/config.'
