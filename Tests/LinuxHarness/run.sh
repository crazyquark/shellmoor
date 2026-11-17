#!/usr/bin/env bash
# Headless test of the SSH engine (SSHConnection + KeyManager) against a throwaway
# local sshd on 127.0.0.1:2222. Runs on Linux; needs openssh-server and ssh-keygen.
set -euo pipefail
cd "$(dirname "$0")"
K=$(mktemp -d)
trap 'kill $(cat "$K/sshd.pid" 2>/dev/null) 2>/dev/null || true; rm -rf "$K"' EXIT
( cd "$K"
  ssh-keygen -q -t ed25519 -N "" -f id_ed25519
  ssh-keygen -q -t ecdsa -b 256 -N "" -f id_ecdsa
  ssh-keygen -q -t rsa -b 2048 -N "" -f id_rsa
  ssh-keygen -q -t ed25519 -N secret -f id_enc
  ssh-keygen -q -t ed25519 -N "" -f host_ed25519
  ssh-keygen -lf id_ed25519.pub | awk '{print $2}' > fp.txt
  cat id_ed25519.pub id_ecdsa.pub > authorized_keys; chmod 600 authorized_keys
  cat > sshd_config <<CFG
Port 2222
ListenAddress 127.0.0.1
HostKey $K/host_ed25519
AuthorizedKeysFile $K/authorized_keys
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
StrictModes no
UsePAM no
PidFile $K/sshd.pid
# Plain shell: never run the user's login profile (it may attach to tmux).
ForceCommand /bin/bash --noprofile --norc -i
CFG
)
mkdir -p /run/sshd
/usr/sbin/sshd -f "$K/sshd_config" -E "$K/sshd.log"
sleep 0.5
swift build -q
.build/debug/Harness "$K" 2222 "$(whoami)"
