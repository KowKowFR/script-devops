#!/usr/bin/env bash
# engine/tests/test_ssh_remote.sh — construction des commandes ssh/scp/docker,
# en particulier la prise en charge d'un port SSH non standard (target.port).
#
# Aucune connexion réseau réelle ici : ssh/scp/sshpass/docker sont shadowés
# pour capturer les arguments EXACTS qui leur seraient passés, plutôt que de
# dépendre d'une cible joignable. Le test contre la vraie VM Lima (preuve
# manuelle, cf. task-11-report.md) complète cette couverture.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

RT="$ENGINE_DIR/lib/runtime.sh"
CF="$ENGINE_DIR/lib/config.sh"
SR="$ENGINE_DIR/lib/ssh_remote.sh"
UI="$ENGINE_DIR/lib/ui.sh"

# _mkenv PORT_JSON_FRAGMENT — écrit un env.json minimal, avec ou sans
# target.port selon ce qu'on veut couvrir.
_mkenv() {
  local extra="$1" f
  f=$(mktemp)
  cat > "$f" <<EOF
{
  "target": {
    "host": "127.0.0.1",
    "user": "devops",
    "auth_method": "key",
    "ssh_key_path": "/tmp/fake_key",
    "password": "secret"
    ${extra:+, $extra}
  }
}
EOF
  printf '%s' "$f"
}

ENV_DEFAULT=$(_mkenv "")
ENV_PORT=$(_mkenv '"port": 60122')
ENV_PASSWORD=$(mktemp)
cat > "$ENV_PASSWORD" <<'EOF'
{
  "target": {
    "host": "127.0.0.1",
    "user": "devops",
    "auth_method": "password",
    "ssh_key_path": "",
    "password": "secret",
    "port": 2222
  }
}
EOF

# _capture_args ENV_JSON FUNC ARGS… — appelle FUNC (ssh_remote, scp_remote,
# ssh_remote_tty) avec ssh/scp/sshpass shadowés en simples "echo argv", et
# renvoie sur stdout la ligne d'arguments effectivement reçue par la commande
# réelle.
_capture_args() {
  local ej="$1" func="$2"; shift 2
  bash -c "
    source '$UI' >/dev/null 2>&1
    source '$RT'
    source '$CF'
    source '$SR'
    ENV_JSON='$ej'
    ssh()      { printf '%s\n' \"ssh \$*\";      }
    scp()      { printf '%s\n' \"scp \$*\";      }
    sshpass()  { printf '%s\n' \"sshpass \$*\";  }
    $func $*
  " 2>/dev/null
}

# ----- Port par défaut (absent de env.json → 22) ----------------------------
out=$(_capture_args "$ENV_DEFAULT" ssh_remote "devops@127.0.0.1 true")
assert_contains "$out" ' -p 22 ' "ssh_remote : port par défaut = 22 (target.port absent)"

out=$(_capture_args "$ENV_DEFAULT" scp_remote "f devops@127.0.0.1:f")
assert_contains "$out" ' -P 22 ' "scp_remote : port par défaut = 22 (target.port absent)"

# ----- Port non standard (target.port=60122, mode clé) ----------------------
out=$(_capture_args "$ENV_PORT" ssh_remote "devops@127.0.0.1 true")
assert_contains "$out" ' -p 60122 ' "ssh_remote : target.port=60122 propagé en '-p' minuscule"
assert_not_contains "$out" ' -P ' "ssh_remote : jamais de '-P' majuscule (c'est le piège scp)"

out=$(_capture_args "$ENV_PORT" ssh_remote_tty "devops@127.0.0.1")
assert_contains "$out" ' -p 60122 ' "ssh_remote_tty : target.port=60122 propagé en '-p' minuscule"

out=$(_capture_args "$ENV_PORT" scp_remote "f devops@127.0.0.1:f")
assert_contains "$out" ' -P 60122 ' "scp_remote : target.port=60122 propagé en '-P' MAJUSCULE (pas '-p')"
assert_not_contains "$out" ' -p ' "scp_remote : jamais de '-p' minuscule (le piège inverse)"

# ----- Mode mot de passe : même prise en charge du port ---------------------
out=$(_capture_args "$ENV_PASSWORD" ssh_remote "devops@127.0.0.1 true")
assert_contains "$out" "sshpass" "ssh_remote (password) : passe bien par sshpass"
assert_contains "$out" ' -p 2222 ' "ssh_remote (password) : target.port propagé en '-p' même via sshpass"

out=$(_capture_args "$ENV_PASSWORD" scp_remote "f devops@127.0.0.1:f")
assert_contains "$out" ' -P 2222 ' "scp_remote (password) : target.port propagé en '-P' même via sshpass"

# ----- docker_host_url : port dans l'URL ssh:// -----------------------------
url_default=$(bash -c "source '$RT'; source '$CF'; source '$SR'; ENV_JSON='$ENV_DEFAULT'; docker_host_url")
assert_eq "ssh://devops@127.0.0.1:22" "$url_default" \
  "docker_host_url : port par défaut 22 dans l'URL"

url_port=$(bash -c "source '$RT'; source '$CF'; source '$SR'; ENV_JSON='$ENV_PORT'; docker_host_url")
assert_eq "ssh://devops@127.0.0.1:60122" "$url_port" \
  "docker_host_url : target.port=60122 propagé dans l'URL ssh://"

rm -f "$ENV_DEFAULT" "$ENV_PORT" "$ENV_PASSWORD"
finish
