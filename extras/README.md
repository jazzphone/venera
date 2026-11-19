# Extras

Optional settings for a macOS VM, with or without Venera: `venera-tune.sh`, in two sets. Each asks before every
change (with a suggestion: Enter takes it), says what it did, and keeps what was there before, so `undo` puts it back.

## Quieter macOS: fewer background services using the CPU

```bash
sudo ./venera-tune.sh quiet
```

| Setting | Suggested | What it does |
|---|---|---|
| No automatic macOS upgrades | yes | not downloaded, not installed: Venera is tested on each macOS release before it supports it (the Security Responses stay on) |
| No photo and media analysis | yes | `mediaanalysisd` and `photoanalysisd` off (faces, scenes and text in pictures and videos) |
| Siri off | yes | with its background helpers (`siriactionsd`, `siriknowledged`, `assistantd`); a VM has no microphone |
| Game Center off | yes | `gamed` |
| No diagnostics uploads | yes | to Apple and to app developers |
| Apple's power logging off | yes | `PerfPowerServices`: it held a whole core at ~90% in a VM, on QEMU's SMC (the VM script's Finish turns it off too) |
| Spotlight's indexing off | no | a new VM's first indexing takes hours of CPU; Spotlight then finds no files or apps (Finder and Launchpad still do) |
| Reduce transparency | no | no blur behind menus, the Dock and sidebars: less drawing for every frame |

## Server settings: always on

```bash
sudo ./venera-tune.sh server
```

| Setting | Suggested | What it does |
|---|---|---|
| Never sleep | yes | no idle sleep, disk sleep, standby or Power Nap (a Proxmox VM has no sleep state to go into) |
| No hibernation file | yes | `hibernatemode 0`, and `/var/vm/sleepimage` deleted: it takes as much disk as the VM has memory |
| No screen saver | yes | it draws the whole time it runs |
| Restart after a freeze | yes | macOS restarts by itself if it hangs |
| The clock from the network | yes | `time.apple.com`, set now and kept set |
| No App Nap | yes | apps in the background keep their full speed (servers, scripts in Terminal) |
| Automatic login | yes | macOS logs in at startup as the user who ran it, so the desktop, its apps and Screen Sharing come back after a restart. An account with no password needs nothing; one with a password asks for it (checked first; macOS keeps it scrambled in `/etc/kcpassword`, as System Settings does). With `--yes`, an account with a password is skipped. Not possible with FileVault on |
| Remote Login (SSH) | no | on, for every user who can log in |
| Screen Sharing | no | on (the Mac's Screen Sharing app, or VNC on port 5900) |

## Status and undo

```bash
sudo ./venera-tune.sh status   # each setting now, and which ones venera-tune changed
sudo ./venera-tune.sh undo     # everything venera-tune changed, back as it was
```

`--yes` takes the suggestions without asking. The user settings (Siri, the screen saver, App Nap) are the logged-in
user's, the one who ran `sudo`. Services turned off stop right away; some come back on only at the next login or
restart after `undo`. What was there before is kept in `/Library/Application Support/Venera/extras/undo`.

## Getting it

- **The Venera Tools CD**, in **Extras**: double-click **Quieter macOS** or **Server Settings** (Terminal opens and asks
  for your password), or run `"/Volumes/Venera Tools/Extras/venera-tune.sh"` in Terminal.
- **From GitHub**, in macOS's Terminal:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/jazzphone/venera/main/extras/venera-tune.sh -o /tmp/venera-tune.sh
  sudo bash /tmp/venera-tune.sh quiet
  ```
