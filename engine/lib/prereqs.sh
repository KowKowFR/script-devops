#!/usr/bin/env bash
# engine/lib/prereqs.sh — vérification des outils requis côté engine.
#
# Non-interactif : aucune installation, aucun prompt. L'engine tourne dans un
# conteneur worker (jalon 2) où l'image apporte ses dépendances ; si un outil
# manque, c'est une erreur de build d'image, pas quelque chose à réparer à chaud.

check_prereqs() {
  local required=("git" "ssh" "scp" "curl" "jq" "docker")
  local missing=() tool count=0

  for tool in "${required[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      ui_ok "${tool} présent"
    else
      ui_err "${tool} manquant (requis)"
      missing+=("$tool")
    fi
    (( count++ ))
  done

  # docker compose est un plugin, pas un binaire du PATH.
  if docker compose version >/dev/null 2>&1; then
    ui_ok "docker compose présent"
  else
    ui_err "plugin 'docker compose' manquant (requis)"
    missing+=("docker-compose-plugin")
  fi
  (( count++ ))

  # gh n'est requis que si le bloc GitHub est activé.
  if cfg_bool github.enabled; then
    if command -v gh >/dev/null 2>&1; then
      ui_ok "gh présent (github.enabled=true)"
    else
      ui_err "gh manquant alors que github.enabled=true"
      missing+=("gh")
    fi
  else
    ui_skip "gh non vérifié (github.enabled=false)"
  fi
  (( count++ ))

  # sshpass n'est requis qu'en authentification par mot de passe.
  if [[ "$(cfg target.auth_method key)" == "password" ]]; then
    if command -v sshpass >/dev/null 2>&1; then
      ui_ok "sshpass présent (auth par mot de passe)"
    else
      ui_err "sshpass manquant alors que target.auth_method=password"
      missing+=("sshpass")
    fi
  fi
  (( count++ ))

  # ssh-keygen n'est requis que si GitHub est activé ET qu'on utilise une clé SSH.
  if cfg_bool github.enabled && [[ "$(cfg target.auth_method key)" == "key" ]]; then
    if command -v ssh-keygen >/dev/null 2>&1; then
      ui_ok "ssh-keygen présent (github.enabled=true ET target.auth_method=key)"
    else
      ui_err "ssh-keygen manquant alors que github.enabled=true et target.auth_method=key"
      missing+=("ssh-keygen")
    fi
  else
    ui_skip "ssh-keygen non vérifié (github.enabled=false ou target.auth_method!=key)"
  fi
  (( count++ ))

  if (( ${#missing[@]} > 0 )); then
    die "outils manquants : ${missing[*]}" 2
  fi

  emit_ok "$(jq -cn --argjson n "$count" '{checked: $n}')"
}
