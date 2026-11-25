# Elara

Elara is a Windows app that keeps a vault of notes. AI apps such as Claude Code, Claude Desktop and Cursor read and write those notes through Elara, so they remember what you told them.

## Install

1. Open PowerShell: press Start, type PowerShell, press Enter.
2. Paste this line and press Enter:

```
irm https://raw.githubusercontent.com/iooioioioi/elara-releases/main/install.ps1 | iex
```

You do not need admin rights. The script downloads Elara, checks that the file is the one that was published, and installs it. When it finishes, open Elara from the Start menu (type Elara).

If anything does not match, it stops and installs nothing.

## If Windows shows a warning

Elara is not code-signed yet, so Windows may show a blue "Windows protected your PC" box when you start it. If it does, click More info, then Run anyway.

## Updates

Elara updates itself. When a new version is ready, a "Restart to update" button appears. Click it when you are ready.

Elara needs to go online at least once every 24 hours. If it cannot, it locks until it has been online again, and your AI apps cannot use the vault while it is locked. Your notes stay on your PC either way.

## Connect an AI

In Elara, open Settings and then the AIs page. Pick the AI app and connect it. Restart that app afterwards.

## Feedback

Elara never sends anything by itself in this test build. To get logs to the person who gave you Elara, open Settings, then Feedback, and click Save logs. It saves a zip to your Desktop. Send that zip to them. Logs hold event names, error words and timings, never your notes.

If your copy of Elara is set up with a feedback server, the same page shows a Send feedback form instead. You see what will be sent before you send it, and you can turn off "Share health data" there.

## Testing

Things worth trying:

1. Make a vault.
2. Import an Obsidian folder.
3. Connect Claude Code (Settings, then AIs), restart it, and ask it something about your notes.
4. Change a rule and see what Elara does differently.

To start over, run the uninstall line below, then the install line above again. Uninstall removes Elara's connections and settings, and asks before it deletes any vault folder. A vault folder you kept can be brought back after the reinstall: choose "Open a vault folder" and pick it.

To send logs, open Settings, then Feedback, click Save logs, and send the zip from your Desktop. If something looks wrong, also tell us the version: open Settings, then About, and click Copy next to the version.

### Smart App Control

On some Windows 11 PCs, Smart App Control blocks unsigned apps without the "More info" option above. Elara then does not open, or Windows says it blocked the app. Do not turn Smart App Control off for Elara (it cannot be turned back on without resetting Windows). Tell the person who gave you Elara instead, and send them the message Windows showed.

## Uninstall

Paste this into PowerShell. Close Elara, Claude Code, Claude Desktop and Cursor first.

```
irm https://raw.githubusercontent.com/iooioioioi/elara-releases/main/uninstall.ps1 | iex
```

It removes Elara, its Start menu shortcut and its entries in your AI apps' settings. It asks "Remove Elara? (y/N)" first, and asks again before it deletes any vault folder.

## Where things live

- The app: `%LOCALAPPDATA%\Elara`
- New vaults: `Documents\Elara`
