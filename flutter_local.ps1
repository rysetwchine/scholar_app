param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$FlutterArgs
)

$candidateRoots = @(
  'C:\Users\Userr\flutter',
  "$env:USERPROFILE\flutter",
  'C:\src\flutter',
  (Join-Path $PSScriptRoot '.flutter-sdk')
)

$flutterRoot = $null
$flutterBat = $null

foreach ($candidate in $candidateRoots) {
  if (-not $candidate) { continue }
  $candidateBat = Join-Path $candidate 'bin\flutter.bat'
  if (Test-Path $candidateBat) {
    $flutterRoot = $candidate
    $flutterBat = $candidateBat
    break
  }
}

if (-not $flutterBat) {
  $installRoot = 'C:\Users\Userr\flutter'
  $installBat = Join-Path $installRoot 'bin\flutter.bat'

  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "Flutter SDK not found, and git is unavailable for automatic install."
    exit 1
  }

  Write-Host "Flutter SDK not found. Installing stable Flutter to $installRoot ..."
  if (-not (Test-Path $installRoot)) {
    git clone https://github.com/flutter/flutter.git -b stable $installRoot
  }

  if (-not (Test-Path $installBat)) {
    Write-Error "Flutter install did not complete successfully."
    exit 1
  }

  $flutterRoot = $installRoot
  $flutterBat = $installBat
}

$base = 'C:\Users\Userr\flutter-home'
$tmp = 'C:\Users\Userr\flutter-temp'
$pub = 'C:\Users\Userr\flutter-pub-cache'
$appRoam = Join-Path $base 'AppData\Roaming'
$appLocal = Join-Path $base 'AppData\Local'

foreach ($path in @($base, $tmp, $pub, $appRoam, $appLocal)) {
  if (-not (Test-Path $path)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }
}

$env:TEMP = $tmp
$env:TMP = $tmp
$env:PUB_CACHE = $pub
$env:APPDATA = $appRoam
$env:LOCALAPPDATA = $appLocal
$env:HOME = $base
$env:USERPROFILE = $base

if (-not $FlutterArgs -or $FlutterArgs.Count -eq 0) {
  Write-Host "Usage: .\flutter_local.ps1 <flutter command>"
  Write-Host "Examples:"
  Write-Host "  .\flutter_local.ps1 --version"
  Write-Host "  .\flutter_local.ps1 pub get"
  Write-Host "  .\flutter_local.ps1 analyze"
  Write-Host "  .\flutter_local.ps1 test"
  Write-Host "  .\flutter_local.ps1 run"
  exit 0
}

& $flutterBat @FlutterArgs
exit $LASTEXITCODE
