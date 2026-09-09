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

# ----- Wrapper ssh de docker_remote ------------------------------------------
# Défaut d'architecture corrigé : Docker (DOCKER_HOST=ssh://…) invoque en
# interne le binaire `ssh` du PATH SANS jamais lui fournir d'identité — mesuré
# contre la VM Lima (cf. commentaire de _docker_ssh_wrapper_bin_dir,
# lib/ssh_remote.sh). `_docker_ssh_wrapper_bin_dir` pose un wrapper `ssh`
# prioritaire qui injecte l'identité (mode clé) ou route par sshpass (mode
# mot de passe). Ici, ni docker ni le réseau ne sont sollicités : on appelle
# la fonction de construction du wrapper directement et on inspecte le script
# généré.

# _wrapper_dir_for ENV_JSON DECOY_DIR — appelle _docker_ssh_wrapper_bin_dir
# avec DECOY_DIR déjà en tête de PATH (simule un `ssh` déjà présent avant que
# la fonction ne construise quoi que ce soit) et renvoie le chemin du
# répertoire wrapper produit.
_wrapper_dir_for() {
  local ej="$1" decoy="$2"
  bash -c "
    source '$UI' >/dev/null 2>&1
    source '$RT'
    source '$CF'
    source '$SR'
    ENV_JSON='$ej'
    PATH=\"$decoy:\$PATH\"
    _docker_ssh_wrapper_bin_dir
  " 2>/dev/null
}

# Faux 'ssh' qui journalise simplement son appel, sans jamais se rappeler
# lui-même : sert à vérifier QUEL binaire le wrapper a capturé, et que
# l'invoquer ne boucle pas.
DECOY_DIR=$(mktemp -d)
cat > "$DECOY_DIR/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'decoy appelé avec : %s\n' "$*"
EOF
chmod +x "$DECOY_DIR/ssh"

# ----- Résolution du vrai ssh AVANT modification du PATH --------------------
wrapper_dir=$(_wrapper_dir_for "$ENV_DEFAULT" "$DECOY_DIR")
wrapper_content=$(cat "$wrapper_dir/ssh" 2>/dev/null)
assert_contains "$wrapper_content" "$DECOY_DIR/ssh" \
  "_docker_ssh_wrapper_bin_dir : capture le VRAI ssh (celui en tête de PATH au moment de l'appel)"

# Preuve qu'il n'y a pas de boucle : on exécute le wrapper généré en plaçant
# SON PROPRE répertoire en tête de PATH (la situation réelle une fois posé
# par docker_remote) — s'il refaisait un `command -v ssh`/appel bare "ssh" à
# l'exécution plutôt que d'utiliser le chemin absolu figé à la construction,
# il s'appellerait lui-même indéfiniment.
loop_out=$(PATH="${wrapper_dir}:${DECOY_DIR}:${PATH}" "$wrapper_dir/ssh" -i /tmp/fake_key some-host true 2>&1)
assert_contains "$loop_out" "decoy appelé avec" \
  "wrapper ssh généré : délègue au vrai binaire (chemin absolu figé), sans boucle"
assert_eq "1" "$(printf '%s\n' "$loop_out" | grep -c '^decoy appelé avec')" \
  "wrapper ssh généré : le décoy n'est appelé qu'UNE fois (pas de récursion)"

rm -rf "$wrapper_dir"

# ----- Mode clé : identité injectée ------------------------------------------
wrapper_dir=$(_wrapper_dir_for "$ENV_DEFAULT" "$DECOY_DIR")
wrapper_content=$(cat "$wrapper_dir/ssh" 2>/dev/null)
assert_contains "$wrapper_content" '-i "/tmp/fake_key"' \
  "wrapper (mode clé) : injecte target.ssh_key_path via -i"
assert_contains "$wrapper_content" 'BatchMode=yes' \
  "wrapper (mode clé) : BatchMode=yes (cohérent avec ssh_remote)"
assert_contains "$wrapper_content" 'StrictHostKeyChecking=accept-new' \
  "wrapper (mode clé) : StrictHostKeyChecking=accept-new (cohérent avec ssh_remote)"
assert_not_contains "$wrapper_content" 'sshpass' \
  "wrapper (mode clé) : ne passe jamais par sshpass"
rm -rf "$wrapper_dir"

# ----- Mode mot de passe : route par sshpass, mot de passe jamais en dur ----
wrapper_dir=$(_wrapper_dir_for "$ENV_PASSWORD" "$DECOY_DIR")
wrapper_content=$(cat "$wrapper_dir/ssh" 2>/dev/null)
assert_contains "$wrapper_content" 'exec sshpass -e' \
  "wrapper (mode mot de passe) : route par 'sshpass -e' (lit SSHPASS, jamais la ligne de commande)"
assert_contains "$wrapper_content" 'PreferredAuthentications=password' \
  "wrapper (mode mot de passe) : PreferredAuthentications=password (cohérent avec ssh_remote)"
assert_contains "$wrapper_content" 'PubkeyAuthentication=no' \
  "wrapper (mode mot de passe) : PubkeyAuthentication=no (cohérent avec ssh_remote)"
assert_not_contains "$wrapper_content" 'secret' \
  "wrapper (mode mot de passe) : le mot de passe (target.password) n'atterrit jamais dans le fichier"
rm -rf "$wrapper_dir"

rm -rf "$DECOY_DIR"

# ----- docker_remote : le wrapper est nettoyé après l'appel -----------------
# `docker` est shadowé pour imprimer le PATH reçu (premier élément = le
# répertoire wrapper) sans toucher au réseau. Après le retour de
# docker_remote, ce répertoire ne doit plus exister sur disque — aucun
# fichier temporaire ne doit survivre à l'appel, succès ou échec.
_docker_remote_wrapper_dir_after_cleanup() {
  local ej="$1" first_path_entry
  first_path_entry=$(bash -c "
    source '$UI' >/dev/null 2>&1
    source '$RT'
    source '$CF'
    source '$SR'
    ENV_JSON='$ej'
    docker() { printf '%s\n' \"\${PATH%%:*}\"; }
    docker_remote version
  " 2>/dev/null)
  printf '%s' "$first_path_entry"
}

captured_wrapper_dir=$(_docker_remote_wrapper_dir_after_cleanup "$ENV_DEFAULT")
assert_eq "0" "$([[ -d "$captured_wrapper_dir" ]] && echo 1 || echo 0)" \
  "docker_remote : le répertoire wrapper temporaire est supprimé après l'appel (rien ne traîne)"

rm -f "$ENV_DEFAULT" "$ENV_PORT" "$ENV_PASSWORD"
finish
