# Elara one-line uninstaller (Windows PowerShell 5.1 or newer, no admin needed).
#   irm https://raw.githubusercontent.com/iooioioioi/elara-releases/main/uninstall.ps1 | iex
# Removes what install.ps1 put on this PC: Elara's AI connections, the Start Menu shortcut and the Elara folder.
# It never deletes your vault folders (your notes) and never touches anything outside the Elara folder except
# the Elara entries in the AI apps' config files and the Start Menu shortcut. It never kills a process.
#
# Piping to iex cannot pass flags. The one "Remove Elara? (y/N)" question is asked on the console, so just answer it.
# To skip the question (or to preview with -WhatIf):
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/iooioioioi/elara-releases/main/uninstall.ps1))) -Yes
# With no console (a pipe, a scheduled task) and no -Yes it refuses; ELARA_UNINSTALL_YES=1 counts as -Yes.
# It runs the installed Elara.exe --elara-reset first (disconnects every AI app, forgets the vaults, removes Elara's settings under ~/.ekv
# and its app profile). Your vault folders are kept unless you answer y to "Also delete these vault folders and their notes?" or pass -DeleteVaults.
param(
  [string]$Base,
  [switch]$WhatIf,
  [switch]$Yes,
  [switch]$DeleteVaults
)

# The whole body runs in a script block scope, so under `irm | iex` no preference, function or variable stays in the caller's session.
& {
  $ErrorActionPreference = "Stop"
  $failed = $false

  function Say([string]$m) { Write-Host $m }

  function Norm([string]$p) { return [IO.Path]::GetFullPath($p).TrimEnd("\", "/") }

  function Is-Under([string]$p, [string]$dir) {
    $a = (Norm $p) + "\"
    $b = (Norm $dir) + "\"
    return $a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase)
  }

  function Does-PointIntoBase($entry, [string]$base) {
    $vals = @()
    if ($entry -and $entry.command) { $vals += [string]$entry.command }
    if ($entry -and $entry.args) { foreach ($a in @($entry.args)) { $vals += [string]$a } }
    foreach ($v in $vals) {
      if ($v.Length -lt 3 -or $v -notmatch "^[A-Za-z]:[\\/]") { continue }
      try { if ((Norm $v) -ieq (Norm $base) -or (Is-Under $v $base)) { return $true } } catch { }
    }
    return $false
  }

  # Removes ekv* servers that point into the base from one MCP server table. Returns the removed names.
  function Remove-FromServers($servers, [string]$base) {
    $gone = @()
    if (-not $servers) { return $gone }
    foreach ($prop in @($servers.PSObject.Properties)) {
      if ($prop.Name -match "^ekv(-|$)" -and (Does-PointIntoBase $prop.Value $base)) { $gone += $prop.Name }
    }
    return $gone
  }

  # Edits one JSON config file in place (backup kept next to it). Returns the removed entry names (empty when nothing changed).
  function Clean-JsonConfig([string]$file, [string]$base, [bool]$dry) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return @() }
    $doc = $null
    try { $doc = [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { Say "  could not read $file as JSON, left alone"; return @() }
    if (-not $doc) { return @() }
    $removed = @()
    $tables = @()
    if ($doc.PSObject.Properties["mcpServers"]) { $tables += , @{ where = "user"; servers = $doc.mcpServers } }
    if ($doc.PSObject.Properties["projects"] -and $doc.projects) {
      foreach ($pp in @($doc.projects.PSObject.Properties)) {
        if ($pp.Value -and $pp.Value.PSObject.Properties["mcpServers"]) { $tables += , @{ where = "project $($pp.Name)"; servers = $pp.Value.mcpServers } }
      }
    }
    foreach ($t in $tables) {
      foreach ($n in (Remove-FromServers $t.servers $base)) {
        $removed += $n
        if (-not $dry) { $t.servers.PSObject.Properties.Remove($n) }
      }
    }
    if ($removed.Count -gt 0 -and -not $dry) {
      Copy-Item -LiteralPath $file -Destination "$file.elara-uninstall.bak" -Force
      $text = $doc | ConvertTo-Json -Depth 100
      $tmp = "$file.elara-uninstall-tmp"
      [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
      Move-Item -LiteralPath $tmp -Destination $file -Force
    }
    return $removed
  }

  # Edits ~/.claude/settings.json (CLAUDE_CONFIG_DIR respected): removes only hook entries whose command names the Elara folder, keeps every
  # other hook and the file valid JSON (backup next to it, temp file then move). Returns the number of hooks removed.
  function Clean-ClaudeHooks([string]$file, [string]$base, [bool]$dry) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return 0 }
    $doc = $null
    try { $doc = [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { Say "  could not read $file as JSON, left alone"; return 0 }
    if (-not $doc -or -not $doc.PSObject.Properties["hooks"] -or -not $doc.hooks) { return 0 }
    $needle = ($base.Replace("\", "/").TrimEnd("/") + "/")
    $count = 0
    foreach ($ev in @($doc.hooks.PSObject.Properties)) {
      $groups = @($ev.Value)
      $newGroups = @()
      $before = $count
      foreach ($g in $groups) {
        if (-not ($g -and $g.PSObject.Properties["hooks"])) { $newGroups += , $g; continue }
        $keep = @()
        foreach ($h in @($g.hooks)) {
          # old form: one shell string in command; exec form: the exe in command and the script path in args (no shell string)
          $cmd = if ($h -and $h.PSObject.Properties["command"]) { ([string]$h.command).Replace("\", "/") } else { "" }
          if ($h -and $h.PSObject.Properties["args"] -and $h.args) { $cmd = $cmd + " " + ((@($h.args) | ForEach-Object { ([string]$_).Replace("\", "/") }) -join " ") }
          if ($cmd -and $cmd.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $count++ } else { $keep += , $h }
        }
        if ($keep.Count -eq @($g.hooks).Count) { $newGroups += , $g }
        elseif ($keep.Count -gt 0) { $g.hooks = $keep; $newGroups += , $g }
      }
      if ($count -gt $before) {
        if ($newGroups.Count -eq 0) { $doc.hooks.PSObject.Properties.Remove($ev.Name) } else { $ev.Value = $newGroups }
      }
    }
    if ($count -gt 0 -and -not $dry) {
      if (@($doc.hooks.PSObject.Properties).Count -eq 0) { $doc.PSObject.Properties.Remove("hooks") }
      Copy-Item -LiteralPath $file -Destination "$file.elara-uninstall.bak" -Force
      $text = $doc | ConvertTo-Json -Depth 100
      $tmp = "$file.elara-uninstall-tmp"
      [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
      Move-Item -LiteralPath $tmp -Destination $file -Force
    }
    return $count
  }

  try {
    Say "Close Claude Code, Cursor and Claude Desktop first."
    $envBase = $null
    if ($Base) { $baseDir = $Base } elseif ($env:ELARA_RELEASE_DIR) { $baseDir = $env:ELARA_RELEASE_DIR; $envBase = $true }
    else {
      if (-not $env:LOCALAPPDATA) { throw "LOCALAPPDATA is not set; pass -Base <the Elara folder>" }
      $baseDir = Join-Path $env:LOCALAPPDATA "Elara"
    }
    $explicit = [bool]$Base -or [bool]$envBase
    $baseDir = Norm $baseDir
    $dry = [bool]$WhatIf
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    $pre = if ($dry) { "Would " } else { "" }

    # Never operate on a drive root, the home folder or a folder that holds the home folder.
    $root = [IO.Path]::GetPathRoot($baseDir).TrimEnd("\", "/")
    if ($baseDir -ieq $root) { throw "refusing to remove a drive root ($baseDir)" }
    foreach ($guard in @($homeDir, $env:LOCALAPPDATA, $env:APPDATA)) {
      if ($guard -and (Is-Under $guard $baseDir)) { throw "refusing to remove $baseDir (it is or contains your home or app-data folder); pass -Base <the Elara folder>" }
    }
    if (-not (Test-Path -LiteralPath $baseDir -PathType Container)) {
      Say "Elara is not installed in $baseDir. Nothing to remove."
      return
    }
    $looksLikeElara = (Test-Path -LiteralPath (Join-Path $baseDir "ELARA-RELEASES.json")) -or (Test-Path -LiteralPath (Join-Path $baseDir "runtime")) -or (Test-Path -LiteralPath (Join-Path $baseDir "current")) -or (@(Get-ChildItem -LiteralPath $baseDir -Directory -Filter "app-*" -ErrorAction SilentlyContinue).Count -gt 0)
    if (-not $looksLikeElara) { throw "$baseDir does not look like an Elara folder (no ELARA-RELEASES.json, runtime, current or app-* inside). Nothing removed." }

    # 1. A running Elara blocks everything. Nothing is killed.
    $running = @()
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
      $pp = $null
      try { $pp = $p.Path } catch { }
      if ($pp -and (Is-Under $pp $baseDir)) { $running += $p }
    }
    if ($running.Count -gt 0) {
      Say "Close Elara first: it is still running ($((@($running | ForEach-Object { "$($_.ProcessName) pid $($_.Id)" })) -join ', '))."
      Say "Nothing was removed."
      $failed = $true
      return
    }

    # The vault folders the person's notes live in (never deleted).
    $ekvHome = if ($env:EKV_HOME) { $env:EKV_HOME } elseif ($homeDir) { Join-Path $homeDir ".ekv" } else { $null }
    $registry = if ($ekvHome) { Join-Path $ekvHome "vaults.json" } else { $null }
    $manifests = @()
    if ($registry -and (Test-Path -LiteralPath $registry -PathType Leaf)) {
      try {
        $reg = [IO.File]::ReadAllText($registry) | ConvertFrom-Json
        foreach ($v in @($reg.vaults)) { if ($v -and $v.manifest) { $manifests += [string]$v.manifest } }
      } catch { }
    }
    foreach ($m in $manifests) {
      $vd = Split-Path -Parent $m
      if ($vd -and (Is-Under $vd $baseDir)) {
        Say "Your notes at $vd are inside the Elara folder. Move them out first; nothing was removed."
        $failed = $true
        return
      }
    }
    $dirs = @($manifests | ForEach-Object { Split-Path -Parent $_ } | Select-Object -Unique)
    if ($dirs.Count -gt 0 -and -not $DeleteVaults) { Say "Your notes are kept in: $($dirs -join '; ')" }
    elseif ($dirs.Count -gt 0) { Say "-DeleteVaults: these vault folders and their notes will be deleted: $($dirs -join '; ')" }
    $deleteVaults = [bool]$DeleteVaults

    # Ask once.
    Say "Elara folder: $baseDir"
    if ($dry) { Say "Dry run (-WhatIf): nothing will be changed." }
    elseif (-not ($Yes -or $env:ELARA_UNINSTALL_YES -eq "1")) {
      $noConsole = $false
      try { $noConsole = [Console]::IsInputRedirected } catch { $noConsole = $true }
      if ($noConsole) { throw "no console to ask on: run it in a PowerShell window, or pass -Yes. Nothing was removed" }
      $ans = Read-Host "Remove Elara? (y/N)"
      if ($ans -notmatch "^\s*[yY]") { Say "Cancelled. Nothing was removed."; return }
      if ($dirs.Count -gt 0 -and -not $deleteVaults) {
        Say "Registered vault folders:"
        foreach ($vd in $dirs) { Say "  $vd" }
        $ans2 = Read-Host "Also delete these vault folders and their notes? [y/N]"
        if ($ans2 -match "^\s*[yY]") { $deleteVaults = $true }
      }
    }

    # 1b. Elara's own reset (the installed Elara.exe --elara-reset): disconnects every AI app per vault, forgets the vaults, removes Elara's files under ~/.ekv,
    # the hook backups and the app profile. A GUI exe does not block under `&`, so it runs through Start-Process with its output in temp files.
    $resetExe = Join-Path $baseDir "current\Elara.exe"
    $resetOk = $false
    $resetStuck = $false
    $resetNote = ""
    if (Test-Path -LiteralPath $resetExe -PathType Leaf) {
      $so = Join-Path ([IO.Path]::GetTempPath()) ("elara-reset-" + [Guid]::NewGuid().ToString("N") + ".out")
      $se = "$so.err"
      $rargs = @("--elara-reset")
      if ($deleteVaults) { $rargs += "--delete-vaults" }
      if ($dry) { $rargs += "--dry-run" }
      $oldRun = $env:ELECTRON_RUN_AS_NODE
      Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
      try {
        Say "$($pre)Run Elara's reset: $resetExe $($rargs -join ' ')"
        $rp = Start-Process -FilePath $resetExe -ArgumentList $rargs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $so -RedirectStandardError $se
        $rcode = $rp.ExitCode
        $rlines = @()
        foreach ($f in @($so, $se)) { if (Test-Path -LiteralPath $f) { $rlines += @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() }) } }
        foreach ($l in $rlines) { Say "  $l" }
        if ($rcode -eq 0) { $resetOk = $true }
        else {
          $resetNote = "Elara's reset stopped with exit code $rcode."
          if (@($rlines | Where-Object { $_ -match "could not disconnect every AI app" }).Count -gt 0) { $resetStuck = $true }
        }
      } catch { $resetNote = "Elara.exe could not run the reset ($($_.Exception.Message))." }
      finally {
        if ($null -ne $oldRun) { $env:ELECTRON_RUN_AS_NODE = $oldRun }
        Remove-Item -LiteralPath $so, $se -Force -ErrorAction SilentlyContinue
      }
    } else { $resetNote = "There is no installed Elara.exe to run the reset ($resetExe)." }
    if ($resetStuck) {
      Say $resetNote
      Say "At least one vault could not be disconnected from its AI apps, so it is still registered and the Elara folder was NOT removed (Elara.exe is needed to retry)."
      Say "Close Claude Code, Cursor and Claude Desktop, then run this uninstaller again."
      $failed = $true
      return
    }
    if (-not $resetOk) { Say "$resetNote Removing the Elara entries from the AI apps' config files directly instead." }

    # 2. AI connections: only ekv* entries whose command or arguments point into the Elara folder.
    $home2 = $homeDir
    $files = @()
    if ($home2) {
      $files += [pscustomobject]@{ client = "Claude Code"; file = (Join-Path $home2 ".claude.json") }
      $files += [pscustomobject]@{ client = "Cursor"; file = (Join-Path $home2 ".cursor\mcp.json") }
    }
    $appdata = if ($env:APPDATA) { $env:APPDATA } elseif ($home2) { Join-Path $home2 "AppData\Roaming" } else { $null }
    if ($appdata) { $files += [pscustomobject]@{ client = "Claude Desktop"; file = (Join-Path $appdata "Claude\claude_desktop_config.json") } }
    if ($env:LOCALAPPDATA) {
      $pk = Join-Path $env:LOCALAPPDATA "Packages"
      if (Test-Path -LiteralPath $pk) {
        foreach ($d in @(Get-ChildItem -LiteralPath $pk -Directory -Filter "Claude*" -ErrorAction SilentlyContinue)) {
          $files += [pscustomobject]@{ client = "Claude Desktop (Store app)"; file = (Join-Path $d.FullName "LocalCache\Roaming\Claude\claude_desktop_config.json") }
        }
      }
    }
    $changed = @()
    foreach ($f in $files) {
      $gone = @(Clean-JsonConfig $f.file $baseDir $dry)
      if ($gone.Count -gt 0) { $changed += $f.client; Say "$($pre)Remove $($gone -join ', ') from $($f.client): $($f.file)" }
    }

    # Codex keeps TOML: the installed runtime removes its entries (once per registered vault) when its config names the Elara folder.
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } elseif ($home2) { Join-Path $home2 ".codex" } else { $null }
    $codexFile = if ($codexHome) { Join-Path $codexHome "config.toml" } else { $null }
    if ($codexFile -and (Test-Path -LiteralPath $codexFile -PathType Leaf)) {
      $toml = [IO.File]::ReadAllText($codexFile)
      if ($toml.IndexOf($baseDir, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $toml.Replace("\\", "\").IndexOf($baseDir, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $ekvMjs = Join-Path $baseDir "runtime\ekv.mjs"
        $exe = Join-Path $baseDir "current\Elara.exe"
        if (-not (Test-Path -LiteralPath $exe)) { $exe = $null }
        $ok = $false
        if ($dry) { Say "Would remove the Elara entries from Codex: $codexFile"; $changed += "Codex"; $ok = $true }
        elseif ($exe -and (Test-Path -LiteralPath $ekvMjs) -and $manifests.Count -gt 0) {
          $ok = $true
          $oldRun = $env:ELECTRON_RUN_AS_NODE
          $env:ELECTRON_RUN_AS_NODE = "1"
          try {
            foreach ($m in $manifests) {
              & $exe $ekvMjs disconnect --client codex --manifest $m 2>&1 | Out-Null
              if ($LASTEXITCODE -ne 0) { $ok = $false }
            }
          } catch { $ok = $false } finally { if ($null -eq $oldRun) { Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue } else { $env:ELECTRON_RUN_AS_NODE = $oldRun } }
          if ($ok) { $changed += "Codex"; Say "Removed the Elara entries from Codex: $codexFile" }
        }
        if (-not $ok) { Say "Codex still has an Elara entry in $codexFile (the runtime could not remove it). Delete the [mcp_servers.ekv-...] tables that name $baseDir by hand." }
      }
    }
    if ($changed.Count -gt 0) { Say "$($pre)Changed AI apps: $((@($changed | Select-Object -Unique)) -join ', '). Restart them so the Elara connection disappears." }
    else { Say "No Elara connections found in the AI apps." }

    # 2b. Without Elara's own reset: Elara's Claude Code hooks (only commands that name the Elara folder; every other hook stays).
    if (-not $resetOk -and $homeDir) {
      $csDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $homeDir ".claude" }
      $csFile = Join-Path $csDir "settings.json"
      $nHooks = Clean-ClaudeHooks $csFile $baseDir $dry
      if ($nHooks -gt 0) { Say "$($pre)Remove $nHooks Elara hook(s) from Claude Code: $csFile" }
      if ($dry) { Say "Would leave (the reset could not run): the vault list and Elara's settings under $ekvHome, and the settings.json.ekv-bak-* backups next to $csFile." }
      else {
        Say "Left on this PC because Elara's own reset could not run: the vault list and Elara's settings under $ekvHome, the settings.json.ekv-bak-* backups next to $csFile."
        Say "They are small files; delete vaults.json, elara-settings.json and the rules folder in $ekvHome if you want a fully clean start."
      }
    }

    # 2c. A claude command on PATH: remove any ekv-* server it still lists for the Elara folder.
    $claudeCmd = $null
    try { $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { }
    if ($claudeCmd) {
      $listing = ""
      try { $listing = (& claude mcp list 2>&1 | Out-String) } catch { }
      foreach ($ln in @($listing -split "\r?\n")) {
        if ($ln -match "^\s*(ekv-[A-Za-z0-9_-]+):" -and $ln.IndexOf($baseDir, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
          $nm = $Matches[1]
          if ($dry) { Say "Would run: claude mcp remove $nm -s user"; continue }
          try { & claude mcp remove $nm -s user 2>&1 | Out-Null; Say "Removed $nm from Claude Code (claude mcp remove)." } catch { }
        }
      }
    }

    # 2d. The app profile (%APPDATA%\Elara, or ELARA_USER_DATA). Elara's reset runs inside Electron, which may hold files in it on Windows.
    $profileDir = if ($env:ELARA_USER_DATA) { $env:ELARA_USER_DATA } elseif ($appdata) { Join-Path $appdata "Elara" } else { $null }
    if ($profileDir) {
      $profileDir = Norm $profileDir
      $pRoot = [IO.Path]::GetPathRoot($profileDir).TrimEnd("\", "/")
      $unsafeProfile = ($profileDir -ieq $pRoot) -or ($homeDir -and (Is-Under $homeDir $profileDir)) -or (Is-Under $profileDir $baseDir) -or (Is-Under $baseDir $profileDir)
      if ((Test-Path -LiteralPath $profileDir -PathType Container) -and -not $unsafeProfile) {
        Say "$($pre)Remove the Elara app profile: $profileDir"
        if (-not $dry) {
          try { Remove-Item -LiteralPath $profileDir -Recurse -Force }
          catch { Say "Could not remove $profileDir ($($_.Exception.Message)). Delete that folder by hand." }
        }
      }
    }

    # 3. Start Menu shortcut (same folder rule as Elara's installer: an explicit base needs ELARA_SHORTCUT_DIR).
    $lnkDir = $null
    if ($env:ELARA_SHORTCUT_DIR) { $lnkDir = $env:ELARA_SHORTCUT_DIR }
    elseif (-not $explicit -and $appdata) { $lnkDir = Join-Path $appdata "Microsoft\Windows\Start Menu\Programs" }
    if ($lnkDir) {
      $lnk = Join-Path $lnkDir "Elara.lnk"
      if (Test-Path -LiteralPath $lnk -PathType Leaf) {
        Say "$($pre)Remove the Start Menu shortcut: $lnk"
        if (-not $dry) { Remove-Item -LiteralPath $lnk -Force }
      }
    }

    # 4. The Elara folder. Links inside it (the `current` junction, anything a person linked in) are unlinked first,
    # so removing the folder can never follow one into a vault folder.
    Say "$($pre)Remove the Elara folder: $baseDir"
    if (-not $dry) {
      # (walks real folders only: it never steps through a link, so a link's target is never listed, let alone changed)
      $stack = New-Object Collections.Stack
      $stack.Push($baseDir)
      while ($stack.Count -gt 0) {
        $dir = [string]$stack.Pop()
        foreach ($sub in @(Get-ChildItem -LiteralPath $dir -Force -Directory -ErrorAction SilentlyContinue)) {
          if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { try { [IO.Directory]::Delete($sub.FullName, $false) } catch { } }
          else { $stack.Push($sub.FullName) }
        }
      }
      try { Remove-Item -LiteralPath $baseDir -Recurse -Force }
      catch { throw "could not remove everything in $baseDir ($($_.Exception.Message)). Close anything using it and run this again" }
    }

    # 5/6. Done.
    if ($dry) { Say "Dry run finished: nothing was changed." }
    elseif ($deleteVaults -and $resetOk) { Say "Elara is removed. Your vault folders were deleted as you asked (see the lines above for any it kept)." }
    elseif ($deleteVaults) { Say "Elara is removed. Your vault folders could not be deleted because Elara's reset did not run: your notes were not touched." }
    else { Say "Elara is removed. Your notes were not touched." }
  } catch {
    $failed = $true
    Write-Host ""
    Write-Host "Elara was NOT fully removed: $($_.Exception.Message)" -ForegroundColor Red
  } finally {
    # Under `irm | iex` there is no script path: do not close the user's window; as a file, report failure to the caller.
    if ($failed -and $PSCommandPath) { $script:exitCode = 1 }
  }
}
if ($script:exitCode) { exit $script:exitCode }
