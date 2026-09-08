#!/usr/bin/env bash
# lib/ssh_remote.sh — Wrappers SSH/SCP unifiés (clé OU mot de passe).
#
# La méthode est choisie via OVH_AUTH_METHOD (key|password) :
#   - "password" : passe par sshpass, désactive BatchMode et PubkeyAuth
#   - "key"      : utilise OVH_SSH_KEY_PATH avec BatchMode=yes
#
# Trois entrées (toutes prennent les mêmes args que ssh/scp) :
#   ssh_remote      [args...] user@host "cmd"   — usage standard non-interactif
#   ssh_remote_tty  [args...] user@host         — TTY alloué (sudo interactif, heredoc avec input)
#   scp_remote      [args...] src... user@host:dst

_ssh_password_opts=(
  -o StrictHostKeyChecking=accept-new
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
)

ssh_remote() {
  if [[ "${OVH_AUTH_METHOD:-key}" == "password" ]]; then
    SSHPASS="$OVH_PASSWORD" sshpass -e ssh "${_ssh_password_opts[@]}" "$@"
  else
    ssh -i "$OVH_SSH_KEY_PATH" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "$@"
  fi
}

ssh_remote_tty() {
  # Identique à ssh_remote, mais alloue un TTY (pour sudo interactif).
  if [[ "${OVH_AUTH_METHOD:-key}" == "password" ]]; then
    SSHPASS="$OVH_PASSWORD" sshpass -e ssh -t "${_ssh_password_opts[@]}" "$@"
  else
    ssh -t -i "$OVH_SSH_KEY_PATH" \
        -o StrictHostKeyChecking=accept-new \
        "$@"
  fi
}

scp_remote() {
  if [[ "${OVH_AUTH_METHOD:-key}" == "password" ]]; then
    SSHPASS="$OVH_PASSWORD" sshpass -e scp "${_ssh_password_opts[@]}" "$@"
  else
    scp -i "$OVH_SSH_KEY_PATH" \
        -o StrictHostKeyChecking=accept-new \
        "$@"
  fi
}
