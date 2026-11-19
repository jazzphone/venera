#!/bin/bash
# venera-tune: optional settings for a macOS VM, in two sets. Each asks before each change, says what it did, and
# keeps what was there before, so "undo" puts it back. For any macOS VM; Venera isn't needed.
#
#   sudo ./venera-tune.sh quiet    fewer background services using the CPU: no automatic macOS upgrades, no photo
#                                  and media analysis, Siri and Game Center off, no diagnostics upload, Apple's power
#                                  logging off; Spotlight's indexing and the blur behind menus if you want
#   sudo ./venera-tune.sh server   always on: no sleep, no hibernation file, no screen saver, restart after a freeze,
#                                  the clock from the network, no App Nap; SSH and Screen Sharing if you want
#   sudo ./venera-tune.sh status   each setting as it is now, and which ones this script changed
#   sudo ./venera-tune.sh undo     puts back everything this script changed, as it was
#   --yes                          takes each setting's suggestion without asking
#
# On the Venera Tools CD (Extras), or from GitHub, in macOS's Terminal:
#   curl -fsSL https://raw.githubusercontent.com/jazzphone/venera/main/extras/venera-tune.sh -o /tmp/venera-tune.sh
#   sudo bash /tmp/venera-tune.sh quiet
#
# The user settings (Siri, the screen saver, ...) are the logged-in user's (the one who ran sudo). macOS's bash 3.2.
set -u
[ "$(id -u)" = 0 ] || exec sudo /bin/bash "$0" "$@"

SET="" YES=0
for a in "$@"; do
  case $a in
    quiet | server | status | undo) SET=$a ;;
    --yes | -y) YES=1 ;;
    *) echo "usage: sudo $0 quiet|server|status|undo [--yes]"; exit 2 ;;
  esac
done
[ -n "$SET" ] || { echo "usage: sudo $0 quiet|server|status|undo [--yes]"; exit 2; }

STATE="/Library/Application Support/Venera/extras"
UNDO="$STATE/undo"          # one line per change: ITEM <tab> the command that puts it back
mkdir -p "$STATE"; touch "$UNDO"

# the user whose settings change: who ran sudo, else who is logged in at the screen
U=${SUDO_USER:-}
[ -n "$U" ] && [ "$U" != root ] || U=$(stat -f %Su /dev/console)
case $U in root | loginwindow | _* | "") U=""; UIDU="" ;; *) UIDU=$(id -u "$U") ;; esac

ITEM=""
say() { echo "   $*"; }
undo_add() { printf '%s\t%s\n' "$ITEM" "$*" >>"$UNDO"; }
done_before() { grep -q "^$1"$'\t' "$UNDO"; }
q() { printf '%q ' "$@"; }

# d user|host|system defaults-arguments...: the user's own, the user's for this Mac (-currentHost), or the system's
d() {
  local who=$1; shift
  case $who in
    user) sudo -u "$U" defaults "$@" ;;
    host) sudo -u "$U" defaults -currentHost "$@" ;;
    *) defaults "$@" ;;
  esac
}
# dset who domain key type value: writes it, with the old value (or its absence) for undo
dset() {
  local who=$1 dom=$2 key=$3 typ=$4 val=$5 old
  if [ "$who" != system ] && [ -z "$U" ]; then say "(skipped $key: nobody is logged in)"; return 0; fi
  if old=$(d "$who" read "$dom" "$key" 2>/dev/null); then
    [ "$typ" = -bool ] && { [ "$old" = 1 ] && old=true || old=false; }
    [ "$old" = "$val" ] && return 0   # so already
    undo_add "$(q d "$who" write "$dom" "$key" "$typ" "$old")"
  else
    undo_add "$(q d "$who" delete "$dom" "$key")"
  fi
  d "$who" write "$dom" "$key" "$typ" "$val" || say "! couldn't write $dom $key"
}
dnow() { d "$1" read "$2" "$3" 2>/dev/null || echo "-"; }

# a launchd job off for good (and stopped now): system/LABEL or gui/UID/LABEL; nothing when it's off already
plist_of() { local f; for f in /System/Library/LaunchAgents/$1.plist /System/Library/LaunchDaemons/$1.plist; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }
is_off() { launchctl print-disabled "$1" 2>/dev/null | grep -q -E "\"$2\" => (disabled|true)"; }
lc_off() {
  local dom=$1 lab=$2
  plist_of "$lab" >/dev/null || [ "$lab" = com.openssh.sshd ] || return 0   # not in this macOS
  if [[ $dom == gui/* ]] && [ -z "$UIDU" ]; then say "(skipped $lab: nobody is logged in)"; return 0; fi
  is_off "$dom" "$lab" && return 0
  undo_add "$(q launchctl enable "$dom/$lab")"
  launchctl disable "$dom/$lab"; launchctl bootout "$dom/$lab" 2>/dev/null || true
}
lc_on() {   # a system daemon on for good (and started now)
  local lab=$1 plist=$2
  if is_off system "$lab" || ! launchctl print "system/$lab" >/dev/null 2>&1; then
    undo_add "$(q lc_stop "$lab")"
  fi
  launchctl enable "system/$lab"; launchctl bootstrap system "$plist" 2>/dev/null || true
}
lc_stop() { launchctl disable "system/$1"; launchctl bootout "system/$1" 2>/dev/null || true; }
lc_state() { if is_off "$1" "$2"; then echo off; else echo on; fi; }

# pmset: a setting this Mac has, changed only when different
pmnow() { pmset -g | awk -v k="$1" '$1 == k {print $2; exit}'; }
pm() {
  local old; old=$(pmnow "$1")
  [ -n "$old" ] && [ "$old" != "$2" ] || return 0
  undo_add "$(q pmset -a "$1" "$old")"; pmset -a "$1" "$2"
}
# systemsetup's On/Off settings: name (as in -getNAME / -setNAME) and on|off
ssnow() { systemsetup -get"$1" 2>/dev/null | awk -F': ' '{print tolower($2)}'; }
ss() {
  local old; old=$(ssnow "$1")
  [ -n "$old" ] || { say "! systemsetup can't read $1 here (Terminal may need Full Disk Access)"; return 0; }
  [ "$old" = "$2" ] && return 0
  undo_add "$(q systemsetup -set"$1" "$old")"; systemsetup -set"$1" "$2" >/dev/null
}

# ---- the settings: each NAME has a set, a suggestion, a line, a "now" and a "do" ------------------------------------
# quiet
T_updates="No automatic macOS upgrades: not downloaded, not installed (Venera is tested on each macOS release before it supports it; the Security Responses stay on)"
now_updates() { echo "download $(dnow system /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload), install macOS $(dnow system /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates)"; }
do_updates() {
  dset system /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
  dset system /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
}
T_analysis="No photo and media analysis (mediaanalysisd, photoanalysisd: faces, scenes and text in pictures and videos)"
now_analysis() { [ -n "$UIDU" ] && echo "mediaanalysisd $(lc_state gui/$UIDU com.apple.mediaanalysisd), photoanalysisd $(lc_state gui/$UIDU com.apple.photoanalysisd)" || echo "(nobody logged in)"; }
do_analysis() { lc_off gui/$UIDU com.apple.mediaanalysisd; lc_off gui/$UIDU com.apple.photoanalysisd; }
T_siri="Siri off, with its background helpers (siriactionsd, siriknowledged, assistantd; a VM has no microphone)"
now_siri() { echo "Siri $(dnow user com.apple.assistant.support 'Assistant Enabled'), siriactionsd $([ -n "$UIDU" ] && lc_state gui/$UIDU com.apple.siriactionsd)"; }
do_siri() {
  dset user com.apple.assistant.support "Assistant Enabled" -bool false
  dset user com.apple.Siri StatusMenuVisible -bool false
  local l; for l in com.apple.siriactionsd com.apple.siriknowledged com.apple.siriinferenced com.apple.assistantd com.apple.Siri.agent; do lc_off gui/$UIDU $l; done
}
T_gamecenter="Game Center off (gamed)"
now_gamecenter() { [ -n "$UIDU" ] && echo "gamed $(lc_state gui/$UIDU com.apple.gamed)" || echo "(nobody logged in)"; }
do_gamecenter() { lc_off gui/$UIDU com.apple.gamed; }
T_diagnostics="No diagnostics and usage data sent to Apple or to app developers"
DIAG="/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist"
now_diagnostics() { echo "to Apple $(dnow system "$DIAG" AutoSubmit), to developers $(dnow system "$DIAG" ThirdPartyDataSubmit)"; }
do_diagnostics() { dset system "$DIAG" AutoSubmit -bool false; dset system "$DIAG" ThirdPartyDataSubmit -bool false; }
T_powerlog="Apple's power logging off (PerfPowerServices: it held a whole core at ~90% in a VM, on QEMU's SMC)"
now_powerlog() { echo "PerfPowerServices $(lc_state system com.apple.PerfPowerServices)"; }
do_powerlog() { lc_off system com.apple.PerfPowerServices; }
T_spotlight="Spotlight's indexing off (a new VM's first indexing takes hours of CPU; Spotlight then finds no files or apps: Finder and Launchpad still do)"
now_spotlight() { mdutil -s / 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//'; }
do_spotlight() {
  mdutil -s / 2>/dev/null | grep -q 'Indexing enabled' || return 0
  undo_add "$(q mdutil -a -i on)"; mdutil -a -i off >/dev/null
}
T_transparency="Reduce transparency: no blur behind menus, the Dock and sidebars (less drawing for every frame)"
now_transparency() { echo "reduce transparency $(dnow user com.apple.universalaccess reduceTransparency)"; }
do_transparency() {
  dset user com.apple.universalaccess reduceTransparency -bool true
  [ "$(dnow user com.apple.universalaccess reduceTransparency)" = 1 ] ||
    say "! macOS kept this one: System Settings > Accessibility > Display > Reduce transparency"
}
# server
T_nosleep="Never sleep: no idle sleep, disk sleep, standby or Power Nap (a Proxmox VM has no sleep state to go into)"
now_nosleep() { echo "sleep $(pmnow sleep), disksleep $(pmnow disksleep), standby $(pmnow standby), powernap $(pmnow powernap)"; }
do_nosleep() { pm sleep 0; pm disksleep 0; pm standby 0; pm autopoweroff 0; pm powernap 0; }
T_hibernate="No hibernation file: hibernatemode 0, and /var/vm/sleepimage deleted (it takes as much disk as the VM has memory)"
now_hibernate() { echo "hibernatemode $(pmnow hibernatemode), sleepimage $(ls -lh /var/vm/sleepimage 2>/dev/null | awk '{print $5}' | grep . || echo none)"; }
do_hibernate() { pm hibernatemode 0; rm -f /var/vm/sleepimage; }
T_screensaver="No screen saver (it draws the whole time it runs)"
now_screensaver() { echo "starts after $(dnow host com.apple.screensaver idleTime) s"; }
do_screensaver() { dset host com.apple.screensaver idleTime -int 0; }
T_freeze="Restart by itself if macOS freezes"
now_freeze() { ssnow restartfreeze; }
do_freeze() { ss restartfreeze on; }
T_time="The clock from the network (time.apple.com), set now and kept set"
now_time() { ssnow usingnetworktime; }
do_time() { ss usingnetworktime on; sntp -sS time.apple.com >/dev/null 2>&1 || true; }
T_appnap="No App Nap: apps in the background keep their full speed (servers, scripts in Terminal)"
now_appnap() { echo "App Nap disabled: $(dnow user NSGlobalDomain NSAppSleepDisabled)"; }
do_appnap() { dset user NSGlobalDomain NSAppSleepDisabled -bool true; }
T_ssh="Remote Login (SSH) on, for every user who can log in"
now_ssh() { lc_state system com.openssh.sshd; }
do_ssh() { lc_on com.openssh.sshd /System/Library/LaunchDaemons/ssh.plist; }
T_screensharing="Screen Sharing on (the Mac's Screen Sharing app, or VNC, on port 5900)"
now_screensharing() { lc_state system com.apple.screensharing; }
do_screensharing() { lc_on com.apple.screensharing /System/Library/LaunchDaemons/com.apple.screensharing.plist; }

QUIET="updates:y analysis:y siri:y gamecenter:y diagnostics:y powerlog:y spotlight:n transparency:n"
SERVER="nosleep:y hibernate:y screensaver:y freeze:y time:y appnap:y ssh:n screensharing:n"

text() { eval "echo \"\$T_$1\""; }

case $SET in
status)
  for set in quiet server; do
    echo "== $set"
    list=$QUIET; [ $set = server ] && list=$SERVER
    for it in $list; do
      n=${it%%:*}
      printf '  %-14s %s%s\n' "$n" "$(now_$n)" "$(done_before "$n" && echo "   (changed by venera-tune)")"
    done
  done
  [ -n "$U" ] || echo "  (nobody is logged in: the user settings show '-')"
  exit 0 ;;
undo)
  [ -s "$UNDO" ] || { echo "Nothing to undo: venera-tune hasn't changed anything here."; exit 0; }
  echo "== putting back what venera-tune changed"
  tail -r "$UNDO" | while IFS=$'\t' read -r it cmd; do
    eval "$cmd" >/dev/null 2>&1 && echo "   $it: $cmd" || echo "   ! $it: $cmd failed"
  done
  : >"$UNDO"
  echo "== Done. Some services start again only at the next login or restart."
  exit 0 ;;
esac

list=$QUIET; [ $SET = server ] && list=$SERVER
echo "== venera-tune $SET${U:+ (user settings: $U)}: each change can be undone (sudo $0 undo)"
CHOSEN=""
for it in $list; do
  n=${it%%:*} def=${it#*:}
  echo
  echo "  $(text "$n")"
  echo "    now: $(now_$n)"
  if done_before "$n"; then echo "    (changed by venera-tune already)"; continue; fi
  if [ $YES = 1 ]; then a=$def
  else
    read -r -p "    Change it? [$([ "$def" = y ] && echo Y/n || echo y/N)]: " a </dev/tty
    a=${a:-$def}
  fi
  case $a in [Yy]*) CHOSEN="$CHOSEN $n" ;; esac
done
[ -n "$CHOSEN" ] || { echo; echo "Nothing changed."; exit 0; }
echo; echo "== changing:$CHOSEN"
for n in $CHOSEN; do
  ITEM=$n
  do_$n
  if done_before "$n"; then echo "   $n: $(now_$n)"; else echo "   $n: so already, nothing changed"; fi
done
echo "== Done. Undo: sudo $0 undo. Some changes take hold at the next login or restart."
