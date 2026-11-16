# Sourced by the deploy and measurement scripts (bash or zsh): where the test VM's Proxmox host is and how to reach
# it, from tools/local.env (not in git; copy tools/local.env.example).
_vgpu_env="${VGPU_ENV:-$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)/local.env}"
[ -f "$_vgpu_env" ] && . "$_vgpu_env"
if [ -z "${VGPU_HOST:-}" ]; then
  echo "set VGPU_HOST (root@your-proxmox-host) in tools/local.env; see tools/local.env.example" >&2
  exit 1
fi
_vgpu_opts=(-o BatchMode=yes -o ConnectTimeout=8)
[ -n "${VGPU_HOSTKEY_ALIAS:-}" ] && _vgpu_opts+=(-o "HostKeyAlias=$VGPU_HOSTKEY_ALIAS")
[ -n "${VGPU_SSH_KEY:-}" ] && _vgpu_opts+=(-i "$VGPU_SSH_KEY")
SSH=(ssh "${_vgpu_opts[@]}")
SCP=(scp -q "${_vgpu_opts[@]}")
HOST=$VGPU_HOST
H=$VGPU_HOST
