# shellcheck shell=bash
# Stand-ins for a Proxmox host's commands, for test-install-host.sh (inside a throwaway Debian container).
mkdir -p /etc/pve/qemu-server /dev/dri /shim /var/log/shim
touch /dev/dri/renderD128
cat >/shim/qm <<'SH'
#!/bin/bash
f=/etc/pve/qemu-server/$2.conf
case $1 in
config) [ -f "$f" ] && cat "$f" ;;
status) [ -f "$f" ] && echo "status: running" ;;
set)
  [ -f "$f" ] || exit 2
  if [ "$3" = --delete ]; then sed -i '/^args: /d' "$f"
  elif grep -q '^args: ' "$f"; then A="$4" awk '/^args: / {print "args: " ENVIRON["A"]; next} {print}' "$f" >"$f.new" && mv "$f.new" "$f"
  else sed -i "1i args: $4" "$f"; fi ;;
esac
SH
cat >/shim/pveversion <<'SH'
#!/bin/bash
echo "pve-manager/9.1.1/test (running kernel: 6.17.2-1-pve)"
SH
cat >/shim/systemctl <<'SH'
#!/bin/bash
echo "systemctl $*" >>/var/log/shim/systemctl
case $1 in
enable) shift; for u; do case $u in --*) ;; *) touch "/var/log/shim/enabled.$u" ;; esac; done ;;
disable) shift; for u; do case $u in --*) ;; *) rm -f "/var/log/shim/enabled.$u" ;; esac; done ;;
list-units) for f in /var/log/shim/enabled.*; do [ -e "$f" ] && echo "${f#/var/log/shim/enabled.} loaded active running x"; done ;;
is-active) u=${@: -1}; if [ -e "/var/log/shim/enabled.$u" ]; then s=active; else s=inactive; fi
  case " $* " in *" --quiet "*) ;; *) echo $s ;; esac; [ $s = active ] || exit 3 ;;
esac
exit 0
SH
cat >/shim/apt-get <<'SH'
#!/bin/bash
echo "apt-get $*" >>/var/log/shim/apt
case $1 in
install) shift; for p; do case $p in -*) ;; *) echo "$p" >>/var/log/shim/installed ;; esac; done ;;
remove) shift; for p; do case $p in -*) ;; *) sed -i "/^$p\$/d" /var/log/shim/installed ;; esac; done ;;
esac
SH
cat >/shim/dpkg-query <<'SH'
#!/bin/bash
p=${@: -1}
grep -qx "$p" /var/log/shim/installed 2>/dev/null || exit 1
case "$*" in *Status*) echo "install ok installed" ;; *) echo "1.0-test" ;; esac
SH
chmod 755 /shim/*
echo libva-drm2 >/var/log/shim/installed   # there before; intel-media-va-driver isn't
export PATH=/shim:$PATH
