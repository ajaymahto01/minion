#!/usr/bin/env bash
# Prepares SSH host keys and login credentials, then hands over to sshd.
#
# Runtime inputs (all optional):
#   SSH_AUTHORIZED_KEYS   one or more public keys (newline separated)
#   /authorized_keys      a mounted public-key file (alternative to the env var)
#   SSH_PASSWORD          password for login (image default: minion); set empty to disable
# If there is no key and the password is empty, a random one is generated and logged.
set -euo pipefail

user="${TESTBED_USER:-minion}"
home="$(getent passwd "$user" | cut -d: -f6)"
keydir=/etc/ssh/hostkeys
authconf=/etc/ssh/sshd_config.d/01-auth.conf

log() { echo "[testbed] $*"; }

# --- host keys: generate once, reuse if the directory is a persistent volume ---
mkdir -p "$keydir" /run/sshd
[ -f "$keydir/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$keydir/ssh_host_ed25519_key"
[ -f "$keydir/ssh_host_rsa_key" ]     || ssh-keygen -q -t rsa -b 4096 -N '' -f "$keydir/ssh_host_rsa_key"
chmod 600 "$keydir"/ssh_host_*_key

# --- public keys ---
install -d -m 0700 -o "$user" -g "$user" "$home/.ssh"
keys=""
[ -n "${SSH_AUTHORIZED_KEYS:-}" ] && keys+="${SSH_AUTHORIZED_KEYS}"$'\n'
[ -f /authorized_keys ] && keys+="$(cat /authorized_keys)"$'\n'
if [ -n "$keys" ]; then
  printf '%s' "$keys" > "$home/.ssh/authorized_keys"
  chown "$user:$user" "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
fi

have_keys=no
[ -s "$home/.ssh/authorized_keys" ] && have_keys=yes

# --- password ---
password="${SSH_PASSWORD:-}"
if [ -z "$password" ] && [ "$have_keys" = no ]; then
  password="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)"
  log "No SSH key or SSH_PASSWORD supplied. Generated password for '$user': $password"
fi

if [ -n "$password" ]; then
  echo "$user:$password" | chpasswd
  echo "PasswordAuthentication yes" > "$authconf"
  log "Password login enabled for '$user'."
else
  echo "PasswordAuthentication no" > "$authconf"
  log "Key-only login enabled for '$user'."
fi
unset password SSH_PASSWORD

/usr/sbin/sshd -t
log "Ready. Connect with: ssh -p <host-port> $user@<host>"
exec "$@"
