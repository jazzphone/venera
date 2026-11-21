#!/bin/bash
# Venera installer: run inside the macOS guest, as root, from the unpacked release folder.
#
#   sudo ./install.sh [--level 4|2] [--video] [--no-app] [--no-agent] [--oc /Volumes/EFI] [--no-opencore]
#                     [--set-security] [--no-system-volume] [--dry-run]
#
# What it does (each step says what it changed; nothing is downloaded):
#   1. checks the guest: x86_64 macOS 26, a virtio-gpu device, SIP and AMFI as the driver needs them
#   2. OpenCore: copies VirtioGPU.kext (the core, which must load from the Boot KC) into EFI/OC/Kexts, adds or enables
#      its Kernel > Add entry and sets vgpuaccel=LEVEL in OpenCore's boot-args (config.plist is backed up first); with
#      --video, VeneraVideo.kext too (hardware video decoding and encoding through the host: the host half is install-host.sh)
#   3. /Library/Extensions: VirtioGPUFramebuffer.kext and VirtioGPUAccel.kext, then rebuilds the Auxiliary KC
#   4. the Metal driver (over Venus): kept in /Library/GPUBundles/Venera, copied onto the system volume
#      (/System/Library/Extensions, a new blessed snapshot: sysvol.sh) where Safari's sandboxed graphics process can
#      load it, and /Library/GPUBundles/VirtioGPUMetal.bundle pointing at it; and the watcher (local.venera.watch),
#      which keeps it there across macOS updates, asking before it reinstalls
#      ... and the Retina display override (/Library/Displays/.../DisplayVendorID-4914/DisplayProductID-1234)
#   5. the Venera app (/Applications/Venera.app, started at login by local.venera.helper): it asks the watcher's
#      questions as notifications and shows what runs; --no-app leaves it out (the watcher then asks in dialogs)
#   6. the guest agent (local.venera.agent): Proxmox's `qm agent` and `qm guest` (shutdown from the Proxmox page, the
#      VM's IP addresses, commands and files from the host); it takes the place of mac-guest-agent if that is there.
#      Its port's driver, VeneraConsole.kext, goes into OpenCore in step 2 (from the next restart). With it, the
#      clipboard agent (local.venera.clipboard, in each user's session): the Proxmox console's clipboard.
#      Installed in the first pass too (it needs no restart); --no-agent leaves it out, or takes it out
# Then reboot. ./uninstall.sh undoes all of it; ./status.sh shows what runs.
#
# When --set-security has to change SIP, steps 3-5 can't run until the restart (rebuilding the Auxiliary KC needs SIP's
# new settings): this pass writes only the security settings (and VeneraVideo.kext) into OpenCore and leaves a
# one-time job (local.venera.finish) that runs the install again at the next boot, as `install.sh --finish` with the
# same options, then restarts once more (by itself at the login window, or after asking whoever is logged in).
#
# The system-volume copy needs SIP's authenticated root off (csr bit 0x800): --set-security sets it with the rest
# (0xA03). Without it the driver runs from the kept copy (every app but Safari's WebGL), and the watcher offers the
# system-volume copy once authenticated root is off. --no-system-volume skips it (and leaves authenticated root on).
#
# Levels (boot-arg vgpuaccel): 4 = WindowServer composites the desktop with Metal on the host GPU (default);
# 2 = the virtio-gpu framebuffer with the software compositor, Metal only for allow-listed test tools.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PAYLOAD=$HERE/payload
LEVEL=4
OC_ROOT=
NO_OC=0
SET_SECURITY=0
NO_SYSVOL=0
DRY=0
FORCE=0
VIDEO=0
NO_APP=0
NO_AGENT=0
GUID=7C436110-AB2A-4BBB-A880-FE41995C9F82
MOUNTED=
V="/Library/Application Support/Venera"
FINISH_PLIST=/Library/LaunchDaemons/local.venera.finish.plist
FINISH=0
FIRST=0
if [ "${1:-}" = --finish ]; then   # the second pass (local.venera.finish, at the boot after the first)
  FINISH=1
  # the job left by the Venera Tools CD's install-venera (from macOS Recovery) runs as a first pass: SIP may not be
  # set for Venera yet, and this boot's pass sets it, then restarts by itself and finishes after that restart
  [ -e "$V/finish-first" ] && FIRST=1
  ARGS=()
  if [ -f "$V/finish-args" ]; then
    while IFS= read -r a; do ARGS+=("$a"); done <"$V/finish-args"
  elif [ -e "$V/finish-first" ]; then
    # Venera Stage.pkg (install-venera, before macOS was installed): the choices are the markers its choice packages
    # left, read as Install Venera.pkg's core reads its own. They go in with it, at the same first startup, and
    # install-venera gives them first; in case the installer took them after the stage (whose postinstall starts this),
    # a minute for the first marker and a few seconds for the rest (no markers at all: every choice was no)
    C="$V/.choices"
    w=0
    while [ ! -d "$C" ] && [ $w -lt 60 ]; do sleep 2; w=$((w + 2)); done
    [ -d "$C" ] && sleep 5
    ARGS=(--set-security)
    [ -e "$C/video" ] && ARGS+=(--video)
    [ -e "$C/app" ] || ARGS+=(--no-app)
    [ -e "$C/agent" ] || ARGS+=(--no-agent)
    if [ ! -e "$C/webgl" ] && ! csrutil authenticated-root status 2>/dev/null | grep -qi disabled; then
      ARGS+=(--no-system-volume)
    fi
    # kept as finish-args, for a try at a later boot
    printf '%s\n' "${ARGS[@]}" >"$V/finish-args" && chmod 600 "$V/finish-args" && rm -rf "$C"
  fi
  if [ ${#ARGS[@]} -gt 0 ]; then set -- "${ARGS[@]}"; else set --; fi
  # the job stays until the install succeeds (a failure tries again at the next boot), three boots at most
  TRIES=$(( $(cat "$V/finish-tries" 2>/dev/null || echo 0) + 1 ))
  echo $TRIES >"$V/finish-tries"
  printf '\n%s Venera: finishing the install after the restart, try %s of 3 (install.sh %s)\n' "$(date '+%F %T')" $TRIES "$*"
  if [ $TRIES -ge 3 ]; then
    rm -f "$FINISH_PLIST" "$V/finish-args" "$V/finish-tries"   # the last try: no job left whatever happens
  fi
fi
finish_done() { [ $FINISH = 1 ] && rm -f "$FINISH_PLIST" "$V/finish-args" "$V/finish-tries"; return 0; }
ORIG=("$@")

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  cleanup
  exit 1
}
cleanup() { [ -n "$MOUNTED" ] && diskutil unmount "$MOUNTED" >/dev/null 2>&1; MOUNTED=; }
restart_now() { # restart_now QUESTION: at the login window (or before Setup Assistant) right away, else ask whoever is logged in
  local cuid r
  cuid=$(stat -f %u /dev/console)
  if [ "$cuid" -ge 501 ] 2>/dev/null; then
    r=$(launchctl asuser "$cuid" sudo -u "$(stat -f %Su /dev/console)" /usr/bin/osascript \
      -e "display dialog \"$1\" buttons {\"Later\", \"Restart\"} default button \"Restart\" with title \"Venera\" giving up after 3600" 2>/dev/null)
    case $r in
    *Restart*) say "restarting, as asked"; shutdown -r now ;;
    *) say "not restarted: Venera goes on at the next restart" ;;
    esac
  else
    say "restarting (nobody is logged in)"
    shutdown -r now
  fi
}
run() { # run CMD...: print it, and run it unless --dry-run
  say "  + $*"
  [ $DRY = 1 ] || "$@"
}

while [ $# -gt 0 ]; do
  case $1 in
  --level) LEVEL=$2; shift ;;
  --oc) OC_ROOT=$2; shift ;;
  --no-opencore) NO_OC=1 ;;
  --set-security) SET_SECURITY=1 ;;
  --no-system-volume) NO_SYSVOL=1 ;;
  --dry-run) DRY=1 ;;
  --force) FORCE=1 ;;
  --video) VIDEO=1 ;;
  --no-app) NO_APP=1 ;;
  --no-agent) NO_AGENT=1 ;;
  -h | --help) sed -n '2,34p' "$0"; exit 0 ;;
  *) die "unknown option $1 (--help)" ;;
  esac
  shift
done
case $LEVEL in 2 | 4) ;; *) die "--level is 4 (Metal desktop) or 2 (software desktop)" ;; esac

# ---- 1. the guest --------------------------------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "run as root: sudo $0"
for d in OpenCore/VirtioGPU.kext Extensions/VirtioGPUFramebuffer.kext Extensions/VirtioGPUAccel.kext \
  GPUBundles/VirtioGPUMetal.bundle Support/sysvol.sh Support/venera-watch.sh Support/local.venera.watch.plist; do
  [ -e "$PAYLOAD/$d" ] || die "payload/$d is missing: run this from the unpacked release folder"
done
# The host's video device in this VM (QEMU's ivshmem-doorbell, 1af4:1110) needs VeneraVideo.kext even when video
# decoding wasn't asked for: left to Apple's VirtIO driver, which takes every 1af4 device and hangs on this one, the
# boot never publishes the partitions of disks found after it (the OpenCore disk among them) -- round 11.
if [ $VIDEO = 0 ] && ioreg -r -c IOPCIDevice -d1 -w0 2>/dev/null | grep -q '"pci1af4,1110"'; then
  say "this VM has the host's video device: adding VeneraVideo.kext anyway (without it the boot loses disks;"
  say "  to do without hardware video, take the device out on the host: install-host.sh --remove-vm VMID)"
  VIDEO=1
fi
[ $VIDEO = 0 ] || [ -e "$PAYLOAD/OpenCore/VeneraVideo.kext" ] || die "payload/OpenCore/VeneraVideo.kext is missing"
[ "$(uname -m)" = x86_64 ] || die "x86_64 macOS only (this is $(uname -m))"
VER=$(sw_vers -productVersion)
BUILD=$(sw_vers -buildVersion)
case $VER in
26.*) ;;
*) [ $FORCE = 1 ] || die "macOS 26 (Tahoe) only; this is $VER ($BUILD). --force to try anyway" ;;
esac
[ "$BUILD" = 25G342 ] || warn "tested on macOS 26.7.3 (25G342); this is $VER ($BUILD). The Metal desktop checks the parts of
  CoreDisplay it depends on and falls back to the software desktop when they differ."
if ! ioreg -rc IOPCIDevice -l | grep -q '"device-id" = <50100000>' ||
  ! ioreg -rc IOPCIDevice -l | grep -q '"vendor-id" = <f41a0000>'; then
  die "no virtio-gpu device (1af4:1050). The VM needs vga: virtio-gl (see INSTALL.md, host)"
fi
say "guest: macOS $VER ($BUILD), virtio-gpu present"

CSR=$(csrutil status 2>/dev/null)
SIP_OK=1
echo "$CSR" | grep -q 'Kext Signing: disabled' || SIP_OK=0
echo "$CSR" | grep -q 'Filesystem Protections: disabled' || SIP_OK=0
echo "$CSR" | grep -q 'System Integrity Protection status: disabled' && SIP_OK=1
RUN_SIP_OK=$SIP_OK   # what the running system allows now (the Auxiliary KC needs it); SIP_OK is what to write
ARGS=$(nvram boot-args 2>/dev/null | cut -f2-)
AMFI_OK=0
case " $ARGS " in *" amfi_get_out_of_my_way=1 "*) AMFI_OK=1 ;; esac
AUTHROOT_OFF=0
csrutil authenticated-root status 2>/dev/null | grep -qi disabled && AUTHROOT_OFF=1
if [ $SET_SECURITY = 1 ] && [ $NO_SYSVOL = 0 ] && [ $AUTHROOT_OFF = 0 ]; then
  SIP_OK=0   # write the csr value with the authenticated-root bit
fi
if [ $SIP_OK = 0 ] || [ $AMFI_OK = 0 ]; then
  if [ $SET_SECURITY = 1 ]; then
    [ $NO_OC = 1 ] && die "--set-security writes OpenCore's config.plist; it can't go with --no-opencore"
    say "security: will set csr-active-config $([ $NO_SYSVOL = 1 ] && echo 0x203 || echo 0xA03) and amfi_get_out_of_my_way=1 in OpenCore (effective at reboot)"
  else
    [ $SIP_OK = 0 ] && warn "SIP must allow unsigned kexts and an unrestricted file system (csr-active-config 0x203)"
    [ $AMFI_OK = 0 ] && warn "boot-args need amfi_get_out_of_my_way=1 (WindowServer loads the ad-hoc signed Metal bundle)"
    die "set them in OpenCore yourself, or run again with --set-security (INSTALL.md, \"Security\")"
  fi
fi
TWO_PASS=0
if [ $RUN_SIP_OK = 0 ]; then
  [ $FINISH = 1 ] && [ $FIRST = 0 ] && die "SIP still doesn't allow unsigned kexts and an unrestricted file system after the restart: was the
  VM started through OpenCore with the config.plist Venera changed? (csrutil status)"
  TWO_PASS=1
  say "security: the rest of the install needs SIP's new settings, which start at the restart: this pass changes only"
  say "  OpenCore's security settings; Venera finishes installing after the restart, then restarts once more"
fi

# ---- 2. OpenCore ---------------------------------------------------------------------------------------------------
pl() { plutil "$@" "$CONFIG"; }
if [ $NO_OC = 0 ]; then
  # find_oc: the EFI partition with EFI/OC/config.plist (mounted for us when it wasn't) in FOUND, else empty
  find_oc() {
    FOUND=
    for p in $(diskutil list | awk '/ EFI / {print $NF}'); do
      mp=$(diskutil info "$p" | awk -F': *' '/Mount Point/ {print $2}')
      fresh=
      if [ -z "$mp" ]; then
        diskutil mount "$p" >/dev/null 2>&1 || continue
        mp=$(diskutil info "$p" | awk -F': *' '/Mount Point/ {print $2}')
        fresh=$p
      fi
      if [ -n "$mp" ] && [ -f "$mp/EFI/OC/config.plist" ]; then
        [ -n "$FOUND" ] && die "OpenCore on more than one EFI partition ($FOUND and $mp): say which with --oc"
        FOUND=$mp
        MOUNTED=$fresh
      elif [ -n "$fresh" ]; then
        diskutil unmount "$fresh" >/dev/null 2>&1
      fi
    done
  }
  if [ -z "$OC_ROOT" ]; then
    find_oc
    # the second pass runs early in the boot, before every disk is published: wait up to two minutes for OpenCore's
    tries=0
    while [ -z "$FOUND" ] && [ $FINISH = 1 ] && [ $tries -lt 24 ]; do
      sleep 5
      tries=$((tries + 1))
      find_oc
    done
    [ -n "$FOUND" ] || die "no EFI partition with EFI/OC/config.plist: mount OpenCore's and pass --oc, or --no-opencore"
    OC_ROOT=$FOUND
  fi
  CONFIG=$OC_ROOT/EFI/OC/config.plist
  [ -f "$CONFIG" ] || die "$CONFIG not found"
  plutil -lint "$CONFIG" >/dev/null || die "$CONFIG doesn't parse"
  say "OpenCore: $CONFIG"
  BACKUP=$CONFIG.venera-$(date +%Y%m%d-%H%M%S)
  run cp "$CONFIG" "$BACKUP"
  # oc_kext NAME COMMENT: NAME.kext copied into EFI/OC/Kexts, its Kernel > Add entry added or enabled
  oc_kext() {
    run rm -rf "$OC_ROOT/EFI/OC/Kexts/$1.kext"
    run cp -R "$PAYLOAD/OpenCore/$1.kext" "$OC_ROOT/EFI/OC/Kexts/"
    N=$(pl -extract Kernel.Add raw -o -) || die "config.plist has no Kernel > Add"
    IDX=
    i=0
    while [ $i -lt "$N" ]; do
      [ "$(pl -extract Kernel.Add.$i.BundlePath raw -o - 2>/dev/null)" = "$1.kext" ] && IDX=$i
      i=$((i + 1))
    done
    if [ -n "$IDX" ]; then
      run pl -replace Kernel.Add.$IDX.Enabled -bool YES
    else
      run pl -insert Kernel.Add.$N -json "{\"Arch\":\"x86_64\",\"BundlePath\":\"$1.kext\",\"Comment\":\"$2\",\"Enabled\":true,\"ExecutablePath\":\"Contents/MacOS/$1\",\"MaxKernel\":\"\",\"MinKernel\":\"\",\"PlistPath\":\"Contents/Info.plist\"}"
    fi
  }
  [ $TWO_PASS = 1 ] || oc_kext VirtioGPU "Venera core (virtio-gpu)"   # the first of two passes: the driver comes in the second
  [ $VIDEO = 1 ] && oc_kext VeneraVideo "Venera video decoding (through the host)"
  # the guest agent's port: VeneraConsole.kext in place of Apple's virtio console (which stalls when the host hangs
  # up mid-answer); off again with --no-agent
  CONSOLE=0
  if [ $NO_AGENT = 0 ] && [ -d "$PAYLOAD/OpenCore/VeneraConsole.kext" ]; then
    oc_kext VeneraConsole "Venera console (the guest agent's port)"
    CONSOLE=1
  elif [ $NO_AGENT = 1 ]; then
    i=0; N=$(pl -extract Kernel.Add raw -o -)
    while [ $i -lt "$N" ]; do
      [ "$(pl -extract Kernel.Add.$i.BundlePath raw -o - 2>/dev/null)" = VeneraConsole.kext ] && run pl -replace Kernel.Add.$i.Enabled -bool NO
      i=$((i + 1))
    done
  fi
  OCARGS=$(pl -extract "NVRAM.Add.$GUID.boot-args" raw -o - 2>/dev/null)
  NEW=
  for a in $OCARGS; do
    case $a in vgpuaccel=*) ;; *) NEW="$NEW $a" ;; esac
  done
  if [ $SET_SECURITY = 1 ]; then
    case " $NEW " in *" amfi_get_out_of_my_way=1 "*) ;; *) NEW="$NEW amfi_get_out_of_my_way=1" ;; esac
    if [ $NO_SYSVOL = 1 ]; then
      run pl -replace "NVRAM.Add.$GUID.csr-active-config" -data AwIAAA==   # 0x00000203, little-endian
    else
      run pl -replace "NVRAM.Add.$GUID.csr-active-config" -data AwoAAA==   # 0x00000A03: and authenticated root off
    fi
  fi
  [ $TWO_PASS = 1 ] || NEW="${NEW# } vgpuaccel=$LEVEL"
  run pl -replace "NVRAM.Add.$GUID.boot-args" -string "${NEW# }"
  # OpenCore writes NVRAM.Add only over variables NVRAM.Delete lists (or that don't exist yet)
  for k in boot-args csr-active-config; do
    [ $k = csr-active-config ] && [ $SET_SECURITY = 0 ] && continue
    if ! pl -extract "NVRAM.Delete.$GUID" raw -o - >/dev/null 2>&1; then
      run pl -insert "NVRAM.Delete.$GUID" -json "[\"$k\"]"
    elif ! pl -extract "NVRAM.Delete.$GUID" xml1 -o - | grep -q "<string>$k</string>"; then
      run pl -insert "NVRAM.Delete.$GUID.0" -string $k
    fi
  done
  [ $DRY = 1 ] || plutil -lint "$CONFIG" >/dev/null || {
    cp "$BACKUP" "$CONFIG"
    die "config.plist didn't validate after the edit; restored the backup"
  }
  if [ $TWO_PASS = 1 ]; then
    say "OpenCore: security settings$([ $VIDEO = 1 ] && echo ", VeneraVideo.kext")$([ $CONSOLE = 1 ] && echo ", VeneraConsole.kext"), boot-args \"${NEW# }\" (backup: $BACKUP)"
  else
    say "OpenCore: VirtioGPU.kext$([ $VIDEO = 1 ] && echo ", VeneraVideo.kext")$([ $CONSOLE = 1 ] && echo ", VeneraConsole.kext") enabled, boot-args \"${NEW# }\" (backup: $BACKUP)"
  fi
  cleanup
else
  say "OpenCore: skipped (--no-opencore). Add payload/OpenCore/VirtioGPU.kext to Kernel > Add and vgpuaccel=$LEVEL"
  say "  to boot-args yourself (INSTALL.md)."
  [ $VIDEO = 1 ] && say "  And payload/OpenCore/VeneraVideo.kext, for hardware video."
  [ $NO_AGENT = 0 ] && say "  And payload/OpenCore/VeneraConsole.kext, for the guest agent's port (it works without, more slowly to recover)."
fi

# ---- 6. the guest agent (runs in either pass: it needs no restart) -----------------------------------------------
AGENT_PLIST=/Library/LaunchDaemons/local.venera.agent.plist
CLIP_PLIST=/Library/LaunchAgents/local.venera.clipboard.plist
# the clipboard agent runs in each logged-in user's session: (re)started in the console user's now, the others' at login
clip_restart() {
  local u; u=$(stat -f %u /dev/console)
  [ "$u" -ge 501 ] 2>/dev/null && [ $DRY = 0 ] || return 0
  launchctl bootout "gui/$u/local.venera.clipboard" 2>/dev/null
  [ -f "$CLIP_PLIST" ] && launchctl bootstrap "gui/$u" "$CLIP_PLIST"
  return 0
}
OLD_AGENT=/Library/LaunchDaemons/com.macos.guest-agent.plist
SWAP_PLIST=/Library/LaunchDaemons/local.venera.agent-swap.plist
# The agent can be carrying this very install (the VM script's Upgrade runs it through the agent): stopping it now
# would end this script with it (launchd stops a job's whole process group). A one-time job of its own makes the
# switch once no install.sh runs any more (and at least ten seconds from now), after the host has read how it went.
agent_switch_later() {   # $1: the agent to start then ("" for none); stops both agents first
  [ $DRY = 1 ] && { say "  + (once this has finished) stop the running agent${1:+, start $1}"; return; }
  local start=""
  [ -n "$1" ] && start="launchctl bootstrap system '$1';"
  cat >"$SWAP_PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.venera.agent-swap</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string>
  <string>sleep 10; while pgrep -f "Venera/release/install.sh|uninstall.sh|/usr/sbin/installer " >/dev/null; do sleep 2; done; launchctl bootout system/com.macos.guest-agent 2>/dev/null; launchctl bootout system/local.venera.agent 2>/dev/null; sleep 1; $start rm -f '$SWAP_PLIST'; launchctl bootout system/local.venera.agent-swap</string></array>
  <key>RunAtLoad</key><true/>
  <key>LaunchOnlyOnce</key><true/>
</dict></plist>
PL
  chown root:wheel "$SWAP_PLIST" && chmod 644 "$SWAP_PLIST"
  launchctl bootout system/local.venera.agent-swap 2>/dev/null
  launchctl bootstrap system "$SWAP_PLIST"
}
agent_running() { launchctl print system/local.venera.agent >/dev/null 2>&1 || launchctl print system/com.macos.guest-agent >/dev/null 2>&1; }
agent_step() {
  # the choice, for the VM script's Upgrade (it installs again with the same choices)
  if [ $NO_AGENT = 1 ]; then run mkdir -p "$V"; run touch "$V/NO_AGENT"; else run rm -f "$V/NO_AGENT"; fi
  if [ $NO_AGENT = 1 ]; then
    if [ -f "$CLIP_PLIST" ]; then
      run rm -f "$CLIP_PLIST" "$V/venera-clipboard"
      clip_restart
      say "clipboard agent: taken out (--no-agent)"
    fi
    if [ -f "$AGENT_PLIST" ]; then
      run rm -f "$AGENT_PLIST" "$V/venera-agent"
      local back=""
      if [ -f "$V/replaced/com.macos.guest-agent.plist" ]; then run mv "$V/replaced/com.macos.guest-agent.plist" "$OLD_AGENT"; back=$OLD_AGENT; fi
      agent_switch_later "$back"
      say "guest agent: taken out (--no-agent)${back:+; mac-guest-agent back}"
    else
      say "guest agent: not installed (--no-agent)"
    fi
    return 0
  fi
  [ -x "$PAYLOAD/Support/venera-agent" ] || { warn "this release has no guest agent: left as it is"; return 0; }
  local same=0 was=0
  agent_running && was=1
  cmp -s "$PAYLOAD/Support/venera-agent" "$V/venera-agent" && cmp -s "$PAYLOAD/Support/local.venera.agent.plist" "$AGENT_PLIST" &&
    launchctl print system/local.venera.agent >/dev/null 2>&1 && same=1
  run mkdir -p "$V"
  # in place by a rename, executable before launchd sees it (a job it can't start, it stops trying)
  run cp "$PAYLOAD/Support/venera-agent" "$V/venera-agent.new"
  run chown root:wheel "$V/venera-agent.new"
  run chmod 755 "$V/venera-agent.new"
  run mv -f "$V/venera-agent.new" "$V/venera-agent"
  run cp "$PAYLOAD/Support/local.venera.agent.plist" "$AGENT_PLIST"
  run chown root:wheel "$AGENT_PLIST"
  run chmod 644 "$AGENT_PLIST"
  local note=""
  if [ -f "$OLD_AGENT" ]; then   # both would take the agent port
    run mkdir -p "$V/replaced"
    run mv -f "$OLD_AGENT" "$V/replaced/"
    note="; mac-guest-agent set aside ($V/replaced; uninstall.sh puts it back)"
  fi
  # the Proxmox console's clipboard: a LaunchAgent in each user's session (VeneraConsole.kext's com.redhat.spice.0)
  if [ -x "$PAYLOAD/Support/venera-clipboard" ]; then
    run cp "$PAYLOAD/Support/venera-clipboard" "$V/venera-clipboard.new"
    run chown root:wheel "$V/venera-clipboard.new"
    run chmod 755 "$V/venera-clipboard.new"
    run mv -f "$V/venera-clipboard.new" "$V/venera-clipboard"
    run cp "$PAYLOAD/Support/local.venera.clipboard.plist" "$CLIP_PLIST"
    run chown root:wheel "$CLIP_PLIST"
    run chmod 644 "$CLIP_PLIST"
    clip_restart
    say "clipboard agent: local.venera.clipboard, in each user's session (the Proxmox console's clipboard)"
  fi
  if [ $same = 1 ] && [ -z "$note" ]; then
    say "guest agent: local.venera.agent running, unchanged"
  elif [ $was = 1 ]; then
    agent_switch_later "$AGENT_PLIST"
    say "guest agent: local.venera.agent, starting in place of the running one once this has finished$note"
  else
    run launchctl bootstrap system "$AGENT_PLIST"
    say "guest agent: local.venera.agent running$note"
  fi
}

agent_step

# ---- the first of two passes ends here: the next boot runs the rest ------------------------------------------------
if [ $TWO_PASS = 1 ]; then
  run mkdir -p "$V"
  run chown root:wheel "$V"
  run chmod 755 "$V"
  if ! [ "$HERE" -ef "$V/release" ]; then   # the package runs from there already; a command-line install doesn't
    run rm -rf "$V/release"
    run cp -R "$HERE" "$V/release"
    run chown -R root:wheel "$V/release"
    run chmod -R go-w "$V/release"
  fi
  if [ $DRY = 0 ]; then
    rm -f "$V/finish-tries"
    if [ ${#ORIG[@]} -gt 0 ]; then printf '%s\n' "${ORIG[@]}" >"$V/finish-args"; else : >"$V/finish-args"; fi
    cat >"$FINISH_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.venera.finish</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$V/release/install.sh</string><string>--finish</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$V/install.log</string>
  <key>StandardErrorPath</key><string>$V/install.log</string>
</dict>
</plist>
PLIST
    chown root:wheel "$FINISH_PLIST" "$V/finish-args"
    chmod 644 "$FINISH_PLIST"
    chmod 600 "$V/finish-args"
  fi
  say "  + $FINISH_PLIST (runs once, at the next boot)"
  say ""
  if [ $FINISH = 1 ] && [ $DRY = 0 ]; then   # install-venera's first pass, at boot: restart into the settings
    rm -f "$V/finish-first"
    cleanup
    restart_now "Venera set its security settings. Restart to finish installing it?"
    exit 0
  fi
  say "Restart now: Venera finishes installing after the restart (a minute or two), then restarts once more."
  exit 0
fi

# ---- 3. the Auxiliary KC -------------------------------------------------------------------------------------------
# a first install whose KC rebuild fails takes its kexts out again: left in /Library/Extensions, macOS adds them to
# the KC by itself at the next boot, and an accelerator with no Metal driver in place leaves WindowServer failing at
# start (a black screen; round 12)
FRESH_AUX=1
[ -e /Library/Extensions/VirtioGPUAccel.kext ] && FRESH_AUX=0
kc_die() {
  if [ $FRESH_AUX = 1 ]; then
    rm -rf /Library/Extensions/VirtioGPUFramebuffer.kext /Library/Extensions/VirtioGPUAccel.kext
    say "  (took VirtioGPUFramebuffer.kext and VirtioGPUAccel.kext out of /Library/Extensions again)"
  fi
  die "$@"
}
for k in VirtioGPUFramebuffer VirtioGPUAccel; do
  run rm -rf "/Library/Extensions/$k.kext"
  run cp -R "$PAYLOAD/Extensions/$k.kext" /Library/Extensions/
  run chown -R root:wheel "/Library/Extensions/$k.kext"
  run chmod -R 755 "/Library/Extensions/$k.kext"
done
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
say "Auxiliary KC: rebuilding (a minute or two)"
if [ $DRY = 0 ]; then
  # not a fixed /tmp name: anyone could have planted a symlink there for root to write through
  KLOG=$(mktemp /private/var/run/venera-kmutil.XXXXXX) || die "can't make a log file in /private/var/run"
  kmutil create -n aux --volume-root / --allow-missing-kdk --kernel /System/Library/Kernels/kernel \
    -B /System/Library/KernelCollections/BootKernelExtensions.kc \
    -S /System/Library/KernelCollections/SystemKernelExtensions.kc \
    --repository /Library/Extensions -A "$KC.venera-new" -z >"$KLOG" 2>&1 ||
    { tail -20 "$KLOG"; kc_die "kmutil failed (log: $KLOG)"; }
  for k in VirtioGPUFramebuffer VirtioGPUAccel; do
    kmutil inspect -a x86_64 -A "$KC.venera-new" 2>/dev/null | grep -q "homelab\.${k}[^A-Za-z]" ||
      { tail -20 "$KLOG"; rm -f "$KC.venera-new"; kc_die "kmutil left $k out (log: $KLOG)"; }
  done
  mv -f "$KC.venera-new" "$KC" || kc_die "couldn't replace $KC (SIP file system protection still on?)"
fi
say "Auxiliary KC: VirtioGPUFramebuffer and VirtioGPUAccel in"

# ---- 4. the Metal driver -------------------------------------------------------------------------------------------
# the kept copy lives under /Library/GPUBundles: WindowServer's sandbox maps code from there, not from $V
K=/Library/GPUBundles/Venera
run mkdir -p "$V" "$K"
# the watcher (root) keeps its files here and the app's answer file inside it: root's, and nobody else's to change
run chown root:wheel "$V" "$K"
run chmod 755 "$V" "$K"
run rm -rf "$K/VirtioGPUMetal.bundle"
run cp -R "$PAYLOAD/GPUBundles/VirtioGPUMetal.bundle" "$K/"
run chown -R root:wheel "$K/VirtioGPUMetal.bundle"
run chmod -R go-w,a+rX "$K/VirtioGPUMetal.bundle"
for f in sysvol.sh venera-watch.sh; do run cp "$PAYLOAD/Support/$f" "$V/" && run chmod 755 "$V/$f"; done
for f in uninstall.sh status.sh; do [ "$HERE/$f" -ef "$V/$f" ] || { run cp "$HERE/$f" "$V/" && run chmod 755 "$V/$f"; }; done
[ $DRY = 1 ] || { cp "$HERE/VERSION" "$V/VERSION" 2>/dev/null; echo 25G342 >"$V/TESTED_BUILD"; }
if [ $VIDEO = 1 ]; then run touch "$V/VIDEO"; else run rm -f "$V/VIDEO"; fi   # what the app checks video against
# the translation pool's seed: Core Animation's shaders translated already (a fresh install's first boot otherwise
# spends minutes of WindowServer's CPU translating them). A translation is named by the hash of the translator and the
# shader's own text, so the seed is right on any macOS build: a shader a build changed just isn't found in it, and
# the ones it kept are. Entries already there stay; only files named by a translation's hash are taken.
if [ -f "$PAYLOAD/Support/pool.tar.gz" ]; then
  if [ $DRY = 1 ]; then
    say "  + seed the translation pool $K/cache from the package"
  else
    T=$(mktemp -d /private/var/tmp/venera-seed.XXXXXX) && tar -xzf "$PAYLOAD/Support/pool.tar.gz" -C "$T" &&
      mkdir -p "$K/cache" && chmod 755 "$K/cache" && n=0 &&
      for f in "$T"/*; do
        b=${f##*/}
        [[ $b =~ ^[0-9a-f]{64}$ ]] && [ -f "$f" ] && [ ! -L "$f" ] && [ ! -e "$K/cache/$b" ] || continue
        chown root:wheel "$f" && chmod 644 "$f" && mv "$f" "$K/cache/$b" && n=$((n + 1))
      done
    rm -rf "$T"
    say "translation pool: $n translations from the package (made on macOS $(tr '+' ' ' <"$PAYLOAD/Support/pool.build" 2>/dev/null); this is $BUILD)"
  fi
fi
# without the system-volume copy by choice (the package's "Safari WebGL" unticked): the watcher doesn't offer it
if [ $NO_SYSVOL = 1 ]; then run touch "$V/NO_SYSVOL"; else run rm -f "$V/NO_SYSVOL"; fi
# /Library/GPUBundles' bundle is a symlink from now on: to the kept copy until the system-volume copy is in
[ -L /Library/GPUBundles/VirtioGPUMetal.bundle ] || run rm -rf /Library/GPUBundles/VirtioGPUMetal.bundle
run ln -sfn "$K/VirtioGPUMetal.bundle" /Library/GPUBundles/VirtioGPUMetal.bundle
SYSVOL="kept copy only (--no-system-volume)"
if [ $NO_SYSVOL = 0 ]; then
  if [ $AUTHROOT_OFF = 1 ]; then
    say "system volume: copying the driver into /System/Library/Extensions and blessing a new snapshot"
    run "$V/sysvol.sh" install "$K/VirtioGPUMetal.bundle" || die "the system-volume copy failed (sysvol.sh above)"
    run ln -sfn "$K/VirtioGPUMetal.bundle" /Library/GPUBundles/VirtioGPUMetal.bundle   # the system copy is there after the reboot; the watcher switches
    SYSVOL="on the system volume after the reboot"
    # until then the booted system has the old copy (or none): the watcher must not take that for an update's doing
    if [ $DRY = 0 ]; then
      ST="$V/watch-state"
      { grep -v '^pending=' "$ST" 2>/dev/null; echo "pending=$BUILD"; } >"$ST.new" && mv "$ST.new" "$ST"
    fi
  else
    SYSVOL="kept copy until authenticated root is off (then the watcher offers the system-volume copy; Safari's WebGL needs it)"
  fi
fi
# Retina: macOS's display override for QEMU's display (vendor 0x4914 "RHT", product 0x1234) with scale-resolutions,
# so the framebuffer's larger modes are offered at twice the pixels too (2560x1600 as "looks like 1280x800")
OVR=/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-4914
run mkdir -p "$OVR"
if [ $DRY = 0 ]; then
  cat >"$OVR/DisplayProductID-1234" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>DisplayProductName</key><string>Venera (QEMU display)</string>
  <key>DisplayVendorID</key><integer>18708</integer>
  <key>DisplayProductID</key><integer>4660</integer>
  <key>scale-resolutions</key>
  <array>
    <data>AAAKAAAABaAAAAABACAAAA==</data>
    <data>AAAKAAAABkAAAAABACAAAA==</data>
    <data>AAALQAAABwgAAAABACAAAA==</data>
    <data>AAAPAAAACHAAAAABACAAAA==</data>
  </array>
</dict>
</plist>
PLIST
  chmod 644 "$OVR/DisplayProductID-1234"
fi
# the watcher
run cp "$PAYLOAD/Support/local.venera.watch.plist" /Library/LaunchDaemons/
run chown root:wheel /Library/LaunchDaemons/local.venera.watch.plist
run chmod 644 /Library/LaunchDaemons/local.venera.watch.plist
[ $DRY = 1 ] || launchctl bootout system/local.venera.watch 2>/dev/null
run launchctl bootstrap system /Library/LaunchDaemons/local.venera.watch.plist
say "Metal driver: kept in $K; $SYSVOL; watcher local.venera.watch running"
# The login screen's copy of each user's wallpaper (/var/db/Wallpapers/UUID, WallpaperAgent's export): one made from a
# moving wallpaper before 0.1.10 is black (the driver passed only 64 of VideoToolbox's function constants, and its
# stills came out empty), and macOS keeps it while the wallpaper doesn't change. Moved aside once, so each user's next
# login exports it again; macOS makes one when there is none.
if [ ! -e "$V/wallpaper-exports-redone" ] && [ -d /var/db/Wallpapers ]; then
  moved=0
  for d in /var/db/Wallpapers/*/; do
    [ -f "$d/Metadata.plist" ] || continue
    plutil -p "$d/Metadata.plist" 2>/dev/null | grep -q 'com.apple.wallpaper.choice.aerials' || continue
    run mkdir -p "$V/old-wallpaper-exports"
    run mv "${d%/}" "$V/old-wallpaper-exports/$(basename "$d")-$(date +%Y%m%d%H%M%S)" && moved=$((moved + 1))
  done
  run touch "$V/wallpaper-exports-redone"
  [ $moved = 0 ] || say "login screen: $moved moving wallpaper's copy set aside (made again at its user's next login)"
fi
# The Memoji picker's saved pictures (~/Library/Caches/Animoji, one per animal): drawn by 0.1.10 they came out striped
# and mixed up, and the picker shows them again rather than drawing them. Moved aside once; the picker draws new ones.
if [ ! -e "$V/animoji-caches-redone" ]; then
  moved=0
  for d in /Users/*/Library/Caches/Animoji; do
    [ -d "$d" ] || continue
    u=$(basename "$(dirname "$(dirname "$(dirname "$d")")")")
    run mkdir -p "$V/old-animoji-caches"
    run mv "$d" "$V/old-animoji-caches/$u-$(date +%Y%m%d%H%M%S)" && moved=$((moved + 1))
  done
  run touch "$V/animoji-caches-redone"
  [ $moved = 0 ] || say "Memoji picker: $moved user's saved pictures set aside (drawn again when the picker opens)"
fi

# ---- 5. the Venera app ---------------------------------------------------------------------------------------------
CUID=$(stat -f %u /dev/console)
if [ -f /Library/LaunchAgents/local.venera.helper.plist ] && [ "$CUID" != 0 ] && [ $DRY = 0 ]; then
  launchctl bootout "gui/$CUID/local.venera.helper" 2>/dev/null
fi
[ $DRY = 1 ] || pkill -x Venera 2>/dev/null
if [ $NO_APP = 0 ] && [ -d "$PAYLOAD/Apps/Venera.app" ]; then
  run rm -rf /Applications/Venera.app
  run cp -R "$PAYLOAD/Apps/Venera.app" /Applications/
  run chown -R root:wheel /Applications/Venera.app
  run chmod -R go-w,a+rX /Applications/Venera.app
  run cp "$PAYLOAD/Support/local.venera.helper.plist" /Library/LaunchAgents/
  run chown root:wheel /Library/LaunchAgents/local.venera.helper.plist
  run chmod 644 /Library/LaunchAgents/local.venera.helper.plist
  # a user's session only: not the login window's or Setup Assistant's (_mbsetupuser, 248) at an install at startup
  [ "$CUID" -ge 501 ] 2>/dev/null && run launchctl bootstrap "gui/$CUID" /Library/LaunchAgents/local.venera.helper.plist
  say "Venera app: /Applications/Venera.app, started at login (local.venera.helper)"
else
  run rm -rf /Applications/Venera.app /Library/LaunchAgents/local.venera.helper.plist
  say "Venera app: not installed$([ $NO_APP = 1 ] && echo " (--no-app)")"
fi

say ""
say "Installed Venera $(cat "$HERE/VERSION" 2>/dev/null) (level $LEVEL$([ $VIDEO = 1 ] && echo ", hardware video")). Reboot to start it: sudo shutdown -r now"
say "If the desktop doesn't come back, the driver falls back to the software desktop by itself after two WindowServer"
say "failures; INSTALL.md, \"Recovery\", has the rest. ./status.sh shows what runs."
# the second pass restarts by itself: at the login window right away, else after asking whoever is logged in
finish_done
rm -f "$V/finish-first"
if [ $FINISH = 1 ] && [ $DRY = 0 ]; then
  restart_now "Venera finished installing. Restart to start it?"
fi
exit 0   # (a bare `[ ] && ...` last line made a finished install exit 1, and Installer report the package failed)
