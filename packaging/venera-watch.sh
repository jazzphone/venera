#!/bin/bash
# venera-watch: keeps Venera's Metal driver where every process can load it, run by launchd as root
# (/Library/LaunchDaemons/local.venera.watch.plist: at boot, every 30 minutes, and when its folders change).
#
# The driver lives on the system volume (/System/Library/Extensions, packaging/sysvol.sh) because Safari's graphics
# process may only load code from there; /Library/GPUBundles/VirtioGPUMetal.bundle points at it. A macOS update
# replaces the system volume and takes the driver with it. Then this:
#   1. points /Library/GPUBundles at the copy kept in /Library/GPUBundles/Venera, so the desktop and every app
#      keep Metal at once (only Safari's WebGL waits);
#   2. asks the logged-in user whether to put the driver back on the system volume (it needs a restart), and does it
#      on yes; when it can't (authenticated root is on again, no copy kept), it says why and what to do;
#   3. asks once per macOS build: "Not now" is remembered until the build changes (`venera-watch.sh --ask` asks again).
# Everything it does goes to /Library/Application Support/Venera/watch.log.
set -u
V="/Library/Application Support/Venera"
KEEP=/Library/GPUBundles/Venera/VirtioGPUMetal.bundle   # under /Library/GPUBundles: WindowServer's sandbox maps code from there, not from $V
SYS=/System/Library/Extensions/VirtioGPUMetal.bundle
G=/Library/GPUBundles/VirtioGPUMetal.bundle
STATE="$V/watch-state"
LOG="$V/watch.log"
BUILD=$(sw_vers -buildVersion)
log() { echo "$(date '+%F %T') $*" >>"$LOG"; }
same() { cmp -s "$1/Contents/MacOS/VirtioGPUMetal" "$2/Contents/MacOS/VirtioGPUMetal"; }
point() {
  [ "$(readlink "$G" 2>/dev/null)" = "$1" ] && return
  [ -e "$G" ] && [ ! -L "$G" ] && { log "$G is a folder, not ours to replace"; return; }
  ln -sfn "$1" "$G" && log "$G -> $1"
}
state() { grep "^$1=" "$STATE" 2>/dev/null | tail -1 | cut -d= -f2-; }
set_state() { { grep -v "^$1=" "$STATE" 2>/dev/null; echo "$1=$2"; } >"$STATE.new" && mv "$STATE.new" "$STATE"; }
# dialog TEXT BUTTON... : shown to the console user; prints the button pressed ("" if nobody answered in an hour)
dialog() {
  local text=$1; shift
  local uid user buttons="" b
  uid=$(stat -f %u /dev/console)
  user=$(stat -f %Su /dev/console)
  [ "$uid" = 0 ] && return 1   # nobody logged in: ask later
  for b in "$@"; do buttons="$buttons${buttons:+, }\"$b\""; done
  launchctl asuser "$uid" sudo -u "$user" /usr/bin/osascript \
    -e "display dialog \"${text//\"/\\\"}\" buttons {$buttons} default button \"${*: -1}\" with title \"Venera\" with icon caution giving up after 3600" \
    2>/dev/null | sed -n 's/.*button returned:\([^,]*\).*/\1/p'
}

mkdir -p "$V"

# The translation pool (5d): every process keeps its own cache of translated shaders (in its own, often sandboxed,
# cache folder), so WindowServer, Safari's GPU process and each app translated the same Core Animation and RenderBox
# shaders again. Entries are named by a hash of what was translated, so any process's is right for any other: they go
# into one pool every process reads on a miss, and back into each process's own folder (for sandboxes that can't read
# the pool). Kept under 256 MB, oldest first.
POOL=/Library/GPUBundles/Venera/cache
pool_caches() {
  [ -d /Library/GPUBundles/Venera ] || return 0
  mkdir -p "$POOL" && chmod 755 "$POOL"
  local dirs d n=0
  dirs=$(find /private/var/folders /Users/*/Library/Containers -type d -path '*local.homelab.VirtioGPUMetal/spirv' 2>/dev/null)
  [ -n "$dirs" ] || return 0
  while IFS= read -r d; do
    find -E "$d" -maxdepth 1 -type f -regex '.*/[0-9a-f]{64}' -exec cp -n {} "$POOL"/ \; 2>/dev/null
  done <<<"$dirs"
  chmod 644 "$POOL"/* 2>/dev/null
  while IFS= read -r d; do
    for f in "$POOL"/*; do
      [ -e "$d/${f##*/}" ] || { cp "$f" "$d/" 2>/dev/null && n=$((n + 1)); }
    done
  done <<<"$dirs"
  # the cap: oldest entries out first
  while [ "$(du -sk "$POOL" | cut -f1)" -gt 262144 ]; do
    f=$(ls -tr "$POOL" | head -1)
    [ -n "$f" ] || break
    rm -f "$POOL/$f"
  done
  [ "$n" -gt 0 ] && log "translation pool: $(ls "$POOL" | wc -l | tr -d ' ') entries, $n copied into process caches"
  return 0
}
pool_caches

ASK=0
[ "${1:-}" = --ask ] && ASK=1
if [ ! -d "$KEEP" ]; then
  exit 0   # not installed by install.sh: nothing to keep
fi
case "$(readlink "$G" 2>/dev/null)" in
/Library/GPUBundles/Venera/dev/*) exit 0 ;;   # a developer's build (tools/deploy.sh devmetal): left alone
esac
if [ -d "$SYS" ] && same "$SYS" "$KEEP"; then
  point "$SYS"
  [ -n "$(state pending)" ] && set_state pending ""   # the reinstall took
  exit 0
fi

# The system copy is gone or isn't this version: every app keeps Metal from the kept copy.
point "$KEEP"
WHY="the Metal driver is no longer on the system volume"
[ -d "$SYS" ] && WHY="the Metal driver on the system volume is a different version from the one installed"
[ "$ASK" = 0 ] && [ "$(state declined)" = "$BUILD" ] && exit 0
[ "$(state pending)" = "$BUILD" ] && exit 0   # reinstalled, waiting for the restart
TESTED=$(cat "$V/TESTED_BUILD" 2>/dev/null)
NOTE=""
[ -n "$TESTED" ] && [ "$TESTED" != "$BUILD" ] &&
  NOTE=" This macOS build ($BUILD) is not the one Venera was tested on ($TESTED); if the desktop misbehaves after the restart, the driver falls back to the software desktop by itself."
if ! csrutil authenticated-root status 2>/dev/null | grep -qi disabled; then
  log "$WHY; authenticated root is on, so it can't go back yet"
  r=$(dialog "Venera: $WHY (a macOS update replaces the system volume). Apps still use the driver, but Safari's graphics process can only load it from the system volume, so WebGL in Safari is off.

Putting it back needs SIP's authenticated root off: in Terminal run
sudo \"$V/sysvol.sh\" csr
then restart, and Venera will ask again.$NOTE" "OK")
  [ -n "$r" ] && set_state declined "$BUILD"
  exit 0
fi
r=$(dialog "Venera: $WHY (a macOS update replaces the system volume). Apps still use the driver, but WebGL in Safari is off until it is back on the system volume.

Reinstall it now? It takes effect after a restart.$NOTE" "Not now" "Reinstall")
case "$r" in
Reinstall)
  log "reinstalling on the system volume ($BUILD), as the user asked"
  if out=$("$V/sysvol.sh" install "$KEEP" 2>&1); then
    log "$out"
    set_state pending "$BUILD"
    point "$KEEP"   # sysvol points it at the system copy, which this boot doesn't have yet
    r=$(dialog "Venera is back on the system volume. Restart to use it?" "Later" "Restart")
    [ "$r" = Restart ] && { log "restarting, as the user asked"; shutdown -r now; }
  else
    log "reinstall failed: $out"
    dialog "Venera couldn't reinstall the driver on the system volume:

$(echo "$out" | tail -3)

Apps still use the driver; Safari's WebGL stays off. The log is $LOG." "OK" >/dev/null
    set_state declined "$BUILD"
  fi
  ;;
"Not now") log "the user said not now ($BUILD)"; set_state declined "$BUILD" ;;
*) ;;   # unanswered: ask again next time
esac
exit 0
