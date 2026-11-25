# Elara one-line installer (Windows PowerShell 5.1 or newer, no admin needed).
#   irm https://raw.githubusercontent.com/iooioioioi/elara-releases/main/install.ps1 | iex
# Downloads the latest release, checks its size and SHA-256, then hands over to Elara.exe, which opens its own install window.
# If anything does not match, it stops and installs nothing.
#
# Trust, honestly: this first install trusts HTTPS to GitHub (this script, the manifest and the zip all come from there; the size and
# SHA-256 check only catches a damaged or mismatched download, not a hijacked GitHub). Elara.exe then verifies the manifest signature
# itself with the public keys built into it, and every later update is checked against the same keys.
param(
  [string]$BaseUrl = "https://github.com/iooioioioi/elara-releases/releases/latest/download",
  [switch]$DryRun
)

# The whole body runs in a script block scope, so under `irm | iex` no preference, function or variable stays in the caller's session.
& {
  $ErrorActionPreference = "Stop"
  $ProgressPreference = "SilentlyContinue"   # the console progress bar makes Invoke-WebRequest very slow in 5.1
  $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
  try { [Net.ServicePointManager]::SecurityProtocol = $oldProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

  $work = $null
  $failed = $false

  function Say([string]$m) { Write-Host $m }

  function Test-Secure([Uri]$u) {
    $loop = ($u.Host -eq "127.0.0.1" -or $u.Host -eq "localhost" -or $u.Host -eq "[::1]" -or $u.Host -eq "::1")
    return ($u.Scheme -eq "https" -or ($u.Scheme -eq "http" -and $loop))
  }

  function Get-File([string]$url, [string]$dest, [string]$what) {
    Say "Downloading $what ..."
    $resp = $null
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest -PassThru
    } catch {
      throw "could not download $what from $url ($($_.Exception.Message))"
    }
    # Windows PowerShell 5.1: BaseResponse.ResponseUri; PowerShell 7: BaseResponse.RequestMessage.RequestUri
    $final = $null
    try { $final = $resp.BaseResponse.ResponseUri } catch { }
    if (-not $final) { try { $final = $resp.BaseResponse.RequestMessage.RequestUri } catch { } }
    if ($final -and -not (Test-Secure $final)) {
      Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
      throw "$what was redirected to an insecure (http) address ($final)"
    }
  }

  try {
    $BaseUrl = $BaseUrl.TrimEnd("/")
    $baseUri = $null
    if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$baseUri) -or -not (Test-Secure $baseUri)) { throw "-BaseUrl must be https (or http on this PC only): $BaseUrl" }
    $work = Join-Path ([IO.Path]::GetTempPath()) ("elara-install-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $work | Out-Null

    $manifestPath = Join-Path $work "manifest.json"
    $sigPath = Join-Path $work "manifest.json.sig"
    Get-File "$BaseUrl/manifest.json" $manifestPath "the release manifest"
    Get-File "$BaseUrl/manifest.json.sig" $sigPath "the manifest signature"
    if ((Get-Item -LiteralPath $sigPath).Length -eq 0) { throw "the manifest signature file is empty" }

    $manifest = $null
    try { $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { throw "the manifest is not valid JSON" }
    $art = $manifest.artifact
    if (-not $art -or -not $art.url -or $null -eq $art.size -or -not $art.sha256) { throw "the manifest does not describe a download (artifact url, size or sha256 missing)" }
    $artUrl = [string]$art.url
    $artSize = [int64]0
    if (-not [int64]::TryParse([string]$art.size, [ref]$artSize) -or $artSize -lt 0) { throw "the manifest holds a size that is not a number: $($art.size)" }
    $artSha = ([string]$art.sha256).ToLower()
    if ($artSha -notmatch "^[0-9a-f]{64}$") { throw "the manifest holds a malformed sha256" }
    $uri = $null
    if (-not [Uri]::TryCreate($artUrl, [UriKind]::Absolute, [ref]$uri)) { throw "the manifest holds a malformed download address" }
    if (-not (Test-Secure $uri)) { throw "the download address is not https: $artUrl" }

    $zipPath = Join-Path $work "Elara.zip"
    Say ("Elara {0} (update {1}), about {2:N1} MB" -f $manifest.version, $manifest.seq, ($artSize / 1MB))
    Get-File $artUrl $zipPath "Elara"

    $got = (Get-Item -LiteralPath $zipPath).Length
    if ($got -ne $artSize) { throw "the download is $got bytes but the manifest says $artSize" }
    Say "Checking the download ..."
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLower()
    if ($hash -ne $artSha) { throw "the download's SHA-256 does not match the manifest, so the file is not what was published" }

    Say "Unpacking ..."
    $appDir = Join-Path $work "app"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $appDir -Force
    $exe = Join-Path $appDir "Elara.exe"
    if (-not (Test-Path -LiteralPath $exe)) { throw "the download holds no Elara.exe" }

    $argLine = "--elara-install --zip `"$zipPath`" --manifest `"$manifestPath`" --sig `"$sigPath`""
    if ($DryRun) {
      Say "Dry run: stopping before the install. Would run:"
      Say "  `"$exe`" $argLine"
      Say "Files kept in $work"
      $work = $null
    } else {
      Say "Installing: Elara opens its own install window and checks the signature itself ..."
      $outFile = Join-Path $work "install-out.txt"
      $errFile = Join-Path $work "install-err.txt"
      $p = Start-Process -FilePath $exe -ArgumentList $argLine -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
      foreach ($f in @($outFile, $errFile)) { if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Encoding UTF8 | ForEach-Object { Say "  $_" } } }
      if ($p.ExitCode -ne 0) { throw "Elara's installer refused or failed (exit code $($p.ExitCode)), nothing was installed" }
      $dest = if ($env:ELARA_RELEASE_DIR) { $env:ELARA_RELEASE_DIR } else { Join-Path $env:LOCALAPPDATA "Elara" }
      Say ""
      Say "Elara is installed in $dest"
      Say "Open it from the Start menu (type Elara), or run $dest\Elara.cmd"
    }
  } catch {
    $failed = $true
    Write-Host ""
    Write-Host "Elara was NOT installed: $($_.Exception.Message)" -ForegroundColor Red
  } finally {
    if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    try { [Net.ServicePointManager]::SecurityProtocol = $oldProtocol } catch { }
  }
  # Under `irm | iex` there is no script path: do not close the user's window; as a file, report failure to the caller.
  if ($failed -and $PSCommandPath) { exit 1 }
}
