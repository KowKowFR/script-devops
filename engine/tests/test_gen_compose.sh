#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ENV_FIX="$TESTS_DIR/fixtures/env.min.json"
SPEC_FIX="$TESTS_DIR/fixtures/spec.multi.json"

# ------------------------------------------------------------------------
# Garde Docker : vérifie que le DÉMON répond, pas seulement que le binaire
# `docker` existe (`command -v docker` ne prouve rien de ça et laissait
# `docker compose config` pendre indéfiniment sur une machine où Docker
# Desktop n'est pas lancé). `timeout` n'existe pas sur cette machine
# (zsh/macOS) : on implémente un poll-and-kill manuel, borné, qui ne peut
# jamais bloquer la suite de tests.
# ------------------------------------------------------------------------
_docker_daemon_up() {
  command -v docker >/dev/null 2>&1 || return 1
  ( docker info >/dev/null 2>&1 ) &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    waited=$((waited + 1))
    if [[ "$waited" -ge 25 ]]; then   # ~5s au maximum, jamais indéfini
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 1
    fi
  done
  wait "$pid"
}

# _py_service_json COMPOSE_YML SERVICE_ID — dict JSON du service demandé, tel
# que PyYAML l'a réellement compris. On affirme sur la STRUCTURE parsée, pas
# sur l'apparence du texte : une injection réussie devient une assertion
# rouge (clé imprévue présente), pas une relecture visuelle du fichier.
_py_service_json() {
  python3 - "$1" "$2" <<'PY'
import sys, json, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
svc = (doc or {}).get("services", {}).get(sys.argv[2])
print(json.dumps(svc, ensure_ascii=False))
PY
}

# _run_gen_compose WORKDIR ENV_JSON SPEC_JSON [APP_NAME] — exécute gen_compose
# dans un process bash séparé (pas de `set -e` ici, volontairement : c'est la
# même absence de filet que dans l'invocation du golden path ci-dessous, donc
# ce qui est vérifié ici est bien ce qui protège réellement l'appelant), et
# renvoie le code de sortie DU PROCESS ENTIER sur stdout.
_run_gen_compose() {
  local w="$1" ej="$2" sj="$3" app="${4:-poc-app}"
  bash -c "
    source '$ENGINE_DIR/lib/ui.sh'
    source '$ENGINE_DIR/lib/runtime.sh'
    source '$ENGINE_DIR/lib/units.sh'
    source '$ENGINE_DIR/lib/config.sh'
    ENV_JSON='$ej'; SPEC_JSON='$sj'
    WORK_DIR='$w'; APP_NAME='$app'
    source '$ENGINE_DIR/lib/gen_compose.sh'
    gen_compose
  " >/dev/null 2>&1
  printf '%s' "$?"
}

# ==========================================================================
# Golden path (fixture existante)
# ==========================================================================
# La fixture n'a pas de port pour "db" — normal, il est interne.
bash -c "
  source '$ENGINE_DIR/lib/ui.sh'
  source '$ENGINE_DIR/lib/runtime.sh'
  source '$ENGINE_DIR/lib/units.sh'
  source '$ENGINE_DIR/lib/config.sh'
  ENV_JSON='$ENV_FIX'; SPEC_JSON='$SPEC_FIX'
  WORK_DIR='$WORK'; APP_NAME='multi-app'
  source '$ENGINE_DIR/lib/gen_compose.sh'
  gen_compose
" >/dev/null 2>&1

CY="$WORK/deploy/compose.yml"
assert_eq "1" "$([[ -f "$CY" ]] && echo 1 || echo 0)" "deploy/compose.yml est créé"
assert_eq "1" "$([[ -f "$WORK/deploy/.env" ]] && echo 1 || echo 0)" "deploy/.env est créé"
assert_eq "1" "$([[ -f "$WORK/deploy/.env.example" ]] && echo 1 || echo 0)" "deploy/.env.example est créé"

body=$(cat "$CY")

# IMAGE_TAG doit rester littéral pour que Compose l'interpole
assert_contains "$body" '${IMAGE_TAG}' "IMAGE_TAG reste littéral dans le YAML"
assert_eq "IMAGE_TAG=latest" "$(head -1 "$WORK/deploy/.env")" "deploy/.env fixe IMAGE_TAG=latest"

# Preuve 6 (renforcée) : vérification explicite via PyYAML, pas juste par
# grep sur le texte — le mécanisme de rollback du projet dépend entièrement
# du fait que Compose (pas bash) interpole cette valeur depuis deploy/.env.
api_image_parsed=$(_py_service_json "$CY" api | jq -r '.image')
assert_contains "$api_image_parsed" '${IMAGE_TAG}' \
  "golden path (PyYAML) : le champ 'image' du service api contient \${IMAGE_TAG} littéral après parsing"

# Ports : hôte:conteneur, hôte pris dans env.json, conteneur dans spec.json
assert_contains "$body" '0.0.0.0:10001:3000' "api publie port_hôte:port_conteneur"
assert_contains "$body" '0.0.0.0:10002:8080' "web publie port_hôte:port_conteneur"

# Le service interne ne publie AUCUN port
db_block=$(awk '/^  db:/{f=1} f && /^  [a-z]/ && !/^  db:/{f=0} f' "$CY")
assert_not_contains "$db_block" "ports:" "un service interne ne publie aucun port"

# Durcissement sur les services buildés uniquement
api_block=$(awk '/^  api:/{f=1} f && /^  [a-z]/ && !/^  api:/{f=0} f' "$CY")
assert_contains "$api_block" 'user: "1000:1000"'          "service buildé : user non-root"
assert_contains "$api_block" 'read_only: true'            "service buildé : read_only"
assert_contains "$api_block" 'no-new-privileges:true'     "service buildé : no-new-privileges"
assert_contains "$api_block" 'healthcheck:'               "service buildé : healthcheck"
assert_not_contains "$db_block" 'read_only: true'         "service image interne : pas de read_only"
assert_not_contains "$db_block" 'user: "1000:1000"'       "service image interne : pas de user forcé"

# Conversion des unités
assert_contains "$body" "cpus: \"0.2\"" "limite CPU convertie de 200m"
assert_contains "$body" "memory: 128m"  "limite mémoire convertie de 128Mi"

# Interdits absolus
assert_not_contains "$body" "network_mode"      "pas de network_mode"
assert_not_contains "$body" "/var/run/docker.sock" "pas de montage du socket Docker"
assert_not_contains "$body" "privileged"        "pas de privileged"

# Réseau dédié et volume déclaré
assert_contains "$body" "networks:"  "un réseau est déclaré"
assert_contains "$body" "pgdata:"    "le volume nommé du spec est déclaré"

# Le fichier généré doit rester du YAML valide au sens strict (PyYAML)
assert_exit_code 0 "golden path : compose.yml généré est du YAML valide (PyYAML)" -- \
  python3 -c "import yaml; yaml.safe_load(open('$CY'))"

# Compose lui-même doit accepter le fichier, et résoudre \${IMAGE_TAG} depuis
# deploy/.env (le mécanisme de rollback du projet).
if _docker_daemon_up; then
  rc=0
  (cd "$WORK/deploy" && docker compose config --quiet) >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "docker compose config --quiet accepte le fichier généré"

  resolved=$(cd "$WORK/deploy" && docker compose config 2>/dev/null \
    | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin); print(d['services']['api']['image'])")
  assert_eq "reguser/multi-app-api:latest" "$resolved" \
    "docker compose config résout \${IMAGE_TAG}=latest depuis deploy/.env"
else
  printf '  (démon Docker indisponible — validation docker compose sautée)\n'
fi

# ==========================================================================
# CRITICAL 1 — injection YAML (PoC de la revue), vecteur "volumes"
# ==========================================================================
# `jq --arg` protège contre l'exécution shell, pas contre la corruption de
# structure YAML : une entrée "volumes" contenant un retour à la ligne suivi
# de "  privileged: true" ne doit JAMAIS devenir une vraie clé de service.
POC1_WORK="$WORK/poc1"; mkdir -p "$POC1_WORK"
POC1_ENV="$WORK/poc1.env.json"
POC1_SPEC="$WORK/poc1.spec.json"
cat > "$POC1_ENV" <<'EOF'
{ "registry": { "user": "reguser" }, "ports": { "svc": 11000 } }
EOF
cat > "$POC1_SPEC" <<'EOF'
{"name":"poc","services":[
  {"id":"svc","build":"./s1","port":3000,"expose":"/",
   "volumes":["normal:/data\n    privileged: true"]}
]}
EOF

rc1=$(_run_gen_compose "$POC1_WORK" "$POC1_ENV" "$POC1_SPEC" "poc1")
assert_eq "0" "$rc1" "PoC volumes : gen_compose réussit (le YAML produit reste valide)"

POC1_CY="$POC1_WORK/deploy/compose.yml"
assert_exit_code 0 "PoC volumes : compose.yml est du YAML valide (PyYAML)" -- \
  python3 -c "import yaml; yaml.safe_load(open('$POC1_CY'))"

poc1_svc=$(_py_service_json "$POC1_CY" svc)
assert_eq "false" "$(printf '%s' "$poc1_svc" | jq 'has("privileged")')" \
  "PoC volumes : le service ne contient AUCUNE clé 'privileged' après parsing"
assert_eq "false" "$(printf '%s' "$poc1_svc" | jq 'has("network_mode")')" \
  "PoC volumes : le service ne contient AUCUNE clé 'network_mode' après parsing"
assert_eq "false" "$(printf '%s' "$poc1_svc" | jq 'has("pid")')" \
  "PoC volumes : le service ne contient AUCUNE clé 'pid' après parsing"

poc1_vol0=$(printf '%s' "$poc1_svc" | jq -r '.volumes[0]')
assert_eq "$(printf 'normal:/data\n    privileged: true')" "$poc1_vol0" \
  "PoC volumes : l'entrée de volume est la chaîne littérale complète, intacte"

if _docker_daemon_up; then
  rc=0
  (cd "$POC1_WORK/deploy" && docker compose config --quiet) >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "PoC volumes : docker compose config --quiet accepte aussi le fichier (aucune structure injectée à refuser ou résoudre)"
else
  printf '  (démon Docker indisponible — validation docker compose sautée)\n'
fi

# ==========================================================================
# CRITICAL 1 — même vecteur via "env" (tentative d'injection network_mode)
# ==========================================================================
POC2_WORK="$WORK/poc2"; mkdir -p "$POC2_WORK"
POC2_ENV="$WORK/poc2.env.json"
POC2_SPEC="$WORK/poc2.spec.json"
cat > "$POC2_ENV" <<'EOF'
{ "registry": { "user": "reguser" }, "ports": { "svc": 11000 } }
EOF
cat > "$POC2_SPEC" <<'EOF'
{"name":"poc","services":[
  {"id":"svc","build":"./s1","port":3000,"expose":"/",
   "env": {"EVIL":"x\n    network_mode: \"host\""}}
]}
EOF

rc2=$(_run_gen_compose "$POC2_WORK" "$POC2_ENV" "$POC2_SPEC" "poc2")
assert_eq "0" "$rc2" "PoC env : gen_compose réussit (le YAML produit reste valide)"

POC2_CY="$POC2_WORK/deploy/compose.yml"
assert_exit_code 0 "PoC env : compose.yml est du YAML valide (PyYAML)" -- \
  python3 -c "import yaml; yaml.safe_load(open('$POC2_CY'))"

poc2_svc=$(_py_service_json "$POC2_CY" svc)
assert_eq "false" "$(printf '%s' "$poc2_svc" | jq 'has("network_mode")')" \
  "PoC env : le service ne contient AUCUNE clé 'network_mode' après parsing"
assert_eq "false" "$(printf '%s' "$poc2_svc" | jq 'has("privileged")')" \
  "PoC env : le service ne contient AUCUNE clé 'privileged' après parsing"
assert_eq "false" "$(printf '%s' "$poc2_svc" | jq 'has("pid")')" \
  "PoC env : le service ne contient AUCUNE clé 'pid' après parsing"

poc2_env_evil=$(printf '%s' "$poc2_svc" | jq -r '.environment.EVIL')
assert_eq "$(printf 'x\n    network_mode: "host"')" "$poc2_env_evil" \
  "PoC env : la valeur d'environnement est la chaîne littérale complète, intacte"

if _docker_daemon_up; then
  rc=0
  (cd "$POC2_WORK/deploy" && docker compose config --quiet) >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "PoC env : docker compose config --quiet accepte aussi le fichier (aucun network_mode résolu)"
else
  printf '  (démon Docker indisponible — validation docker compose sautée)\n'
fi

# ==========================================================================
# Effet collatéral sans intention hostile : valeur "env" légitime avec
# guillemets, apostrophe, $, accent et retour à la ligne — doit rester du
# YAML parsable et ressortir INTACTE (comparaison de chaîne exacte).
# ==========================================================================
POC3_WORK="$WORK/poc3"; mkdir -p "$POC3_WORK"
POC3_ENV="$WORK/poc3.env.json"
POC3_SPEC="$WORK/poc3.spec.json"
cat > "$POC3_ENV" <<'EOF'
{ "registry": { "user": "reguser" }, "ports": { "svc": 11000 } }
EOF
cat > "$POC3_SPEC" <<'EOF'
{"name":"poc","services":[
  {"id":"svc","build":"./s1","port":3000,"expose":"/",
   "env": {"MSG":"il a dit \"salut\", c'est un $HOME café\nligne2"}}
]}
EOF

rc3=$(_run_gen_compose "$POC3_WORK" "$POC3_ENV" "$POC3_SPEC" "poc3")
assert_eq "0" "$rc3" "valeur env légitime avec caractères spéciaux : gen_compose réussit"

POC3_CY="$POC3_WORK/deploy/compose.yml"
assert_exit_code 0 "valeur env légitime : compose.yml est du YAML valide (PyYAML)" -- \
  python3 -c "import yaml; yaml.safe_load(open('$POC3_CY'))"

poc3_msg=$(_py_service_json "$POC3_CY" svc | jq -r '.environment.MSG')
expected_msg=$(printf 'il a dit "salut", c'"'"'est un $HOME café\nligne2')
assert_eq "$expected_msg" "$poc3_msg" \
  "valeur env légitime : guillemets/apostrophe/\$/accent/retour à la ligne préservés intacts"

# ==========================================================================
# CRITICAL 2 — écriture atomique : port hôte manquant en cours de boucle
# ==========================================================================
# Cas A : répertoire neuf → aucun compose.yml ne doit apparaître.
POC4A_WORK="$WORK/poc4a"; mkdir -p "$POC4A_WORK"
POC4_ENV="$WORK/poc4.env.json"
POC4_SPEC="$WORK/poc4.spec.json"
cat > "$POC4_ENV" <<'EOF'
{ "registry": { "user": "reguser" } }
EOF
cat > "$POC4_SPEC" <<'EOF'
{"name":"poc","services":[
  {"id":"svc","build":"./s1","port":3000,"expose":"/"}
]}
EOF

rc4a=$(_run_gen_compose "$POC4A_WORK" "$POC4_ENV" "$POC4_SPEC" "poc4a")
assert_eq "2" "$rc4a" "port hôte manquant pour un service exposé : code de sortie 2"
assert_eq "0" "$([[ -f "$POC4A_WORK/deploy/compose.yml" ]] && echo 1 || echo 0)" \
  "port hôte manquant : aucun compose.yml n'est laissé sur disque (répertoire neuf)"

# Cas B : un compose.yml existait déjà → il doit rester intact (pas tronqué).
POC4B_WORK="$WORK/poc4b"; mkdir -p "$POC4B_WORK/deploy"
printf 'ANCIEN CONTENU INTACT\n' > "$POC4B_WORK/deploy/compose.yml"
rc4b=$(_run_gen_compose "$POC4B_WORK" "$POC4_ENV" "$POC4_SPEC" "poc4b")
assert_eq "2" "$rc4b" "port hôte manquant (avec ancien fichier) : code de sortie 2"
assert_eq "ANCIEN CONTENU INTACT" "$(cat "$POC4B_WORK/deploy/compose.yml")" \
  "port hôte manquant : l'ancien compose.yml reste intact, jamais remplacé par une version tronquée"

# Aucun fichier temporaire de génération ne doit traîner après ces échecs.
leftover=$(find "$POC4A_WORK/deploy" "$POC4B_WORK/deploy" -name '.compose.yml.*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$leftover" "port hôte manquant : aucun fichier temporaire de compose.yml ne traîne sur disque"

# ==========================================================================
# IMPORTANT — id de service invalide : rejeté avec code 2 et message clair
# ==========================================================================
POC5_ENV="$WORK/poc5.env.json"
cat > "$POC5_ENV" <<'EOF'
{ "registry": { "user": "reguser" } }
EOF

_poc5_case() {
  local label="$1" badid="$2"
  local w spec
  w="$WORK/poc5-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_')"
  mkdir -p "$w"
  spec="$w.spec.json"
  cat > "$spec" <<EOF
{"name":"poc","services":[{"id":"${badid}","image":"alpine"}]}
EOF
  local rc msg
  rc=$(_run_gen_compose "$w" "$POC5_ENV" "$spec" "poc5")
  assert_eq "2" "$rc" "id de service invalide (${label}) : code de sortie 2"

  # die()/emit_fail impriment le message d'erreur en JSON sur STDOUT (c'est le
  # contrat du projet, cf. runtime.sh) : on le capture là, pas sur stderr.
  msg=$(bash -c "
    source '$ENGINE_DIR/lib/runtime.sh'
    source '$ENGINE_DIR/lib/config.sh'
    SPEC_JSON='$spec'
    spec_init
  " 2>/dev/null)
  assert_contains "$msg" "id(s) de service invalide" \
    "id de service invalide (${label}) : message d'erreur clair"
}

_poc5_case "espace"      "svc bad"
_poc5_case "substitution" 'svc$(id)'
_poc5_case "slash"       "svc/evil"

# ==========================================================================
# Revue round 2, finding A — id vide : aucun service ne peut disparaître
# en silence. spec_init doit mourir (déjà couvert dans test_config.sh) ; ici
# on vérifie le comportement de bout en bout via gen_compose : pas de succès
# partiel, le service valide voisin d'un id vide n'est PAS silencieusement
# généré.
# ==========================================================================
POC6_WORK="$WORK/poc6"; mkdir -p "$POC6_WORK"
POC6_ENV="$WORK/poc6.env.json"
POC6_SPEC="$WORK/poc6.spec.json"
cat > "$POC6_ENV" <<'EOF'
{ "registry": { "user": "reguser" } }
EOF
cat > "$POC6_SPEC" <<'EOF'
{"name":"poc","services":[{"id":"","image":"alpine"},{"id":"good","image":"alpine"}]}
EOF
rc6=$(_run_gen_compose "$POC6_WORK" "$POC6_ENV" "$POC6_SPEC" "poc6")
assert_eq "2" "$rc6" "id vide + id valide : gen_compose échoue en code 2 (pas de succès partiel)"
assert_eq "0" "$([[ -f "$POC6_WORK/deploy/compose.yml" ]] && echo 1 || echo 0)" \
  "id vide + id valide : le service valide n'est PAS silencieusement généré (aucun compose.yml)"

# ==========================================================================
# Revue round 2, finding B — les `mv -f` finaux doivent être vérifiés.
# ==========================================================================
# _run_gen_compose_broken_mv WORKDIR ENV_JSON SPEC_JSON APP_NAME SUFFIXE [STDOUT_FILE]
# — comme _run_gen_compose, mais shadow la commande `mv` : tout appel dont un
# des arguments se TERMINE exactement par SUFFIXE échoue (simule un
# renommage impossible, ex. permission refusée). Correspondance sur le
# SUFFIXE exact d'un argument (pas une sous-chaîne de "$*") pour ne pas
# confondre "/.env" et "/.env.example", qui partagent un préfixe.
_run_gen_compose_broken_mv() {
  local w="$1" ej="$2" sj="$3" app="$4" suffix="$5" outfile="${6:-/dev/null}"
  bash -c "
    source '$ENGINE_DIR/lib/ui.sh'
    source '$ENGINE_DIR/lib/runtime.sh'
    source '$ENGINE_DIR/lib/units.sh'
    source '$ENGINE_DIR/lib/config.sh'
    ENV_JSON='$ej'; SPEC_JSON='$sj'
    WORK_DIR='$w'; APP_NAME='$app'
    source '$ENGINE_DIR/lib/gen_compose.sh'
    mv() {
      local __a
      for __a in \"\$@\"; do
        case \"\$__a\" in
          *'$suffix') return 1 ;;
        esac
      done
      command mv \"\$@\"
    }
    gen_compose
  " >"$outfile" 2>/dev/null
  printf '%s' "$?"
}

# --- Preuve 4 : renommage de compose.yml impossible ------------------------
POC7_WORK="$WORK/poc7"; mkdir -p "$POC7_WORK/deploy"
printf 'ANCIEN CONTENU COMPOSE\n' > "$POC7_WORK/deploy/compose.yml"
POC7_OUT="$WORK/poc7.stdout"
rc7=$(_run_gen_compose_broken_mv "$POC7_WORK" "$ENV_FIX" "$SPEC_FIX" "poc7" "/compose.yml" "$POC7_OUT")
assert_eq "2" "$rc7" "renommage compose.yml impossible : code de sortie 2"
assert_eq "ANCIEN CONTENU COMPOSE" "$(cat "$POC7_WORK/deploy/compose.yml")" \
  "renommage compose.yml impossible : l'ancien fichier reste en place (pas de faux succès)"
poc7_stdout=$(cat "$POC7_OUT")
assert_contains "$poc7_stdout" '"ok":false' \
  "renommage compose.yml impossible : le JSON annonce l'échec (aucun faux ui_ok)"
assert_contains "$poc7_stdout" "échec du renommage atomique" \
  "renommage compose.yml impossible : message clair"
leftover7=$(find "$POC7_WORK/deploy" -name '.compose.yml.*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$leftover7" "renommage compose.yml impossible : le fichier temporaire est nettoyé"

# --- Preuve 5 : renommage de .env impossible après un compose.yml réussi ---
# (état mixte : le message doit dire explicitement ce qui a été écrit et ce
# qui ne l'a pas été, plutôt que de laisser l'appelant deviner)
POC8_WORK="$WORK/poc8"; mkdir -p "$POC8_WORK/deploy"
printf 'ANCIEN .env\n' > "$POC8_WORK/deploy/.env"
POC8_OUT="$WORK/poc8.stdout"
rc8=$(_run_gen_compose_broken_mv "$POC8_WORK" "$ENV_FIX" "$SPEC_FIX" "poc8" "/.env" "$POC8_OUT")
assert_eq "2" "$rc8" "renommage .env impossible (après compose.yml réussi) : code de sortie 2"
assert_eq "1" "$([[ -f "$POC8_WORK/deploy/compose.yml" ]] && echo 1 || echo 0)" \
  "renommage .env impossible : compose.yml, lui, a bien été écrit à jour (état mixte réel)"
assert_eq "ANCIEN .env" "$(cat "$POC8_WORK/deploy/.env")" \
  "renommage .env impossible : l'ancien .env reste en place"
poc8_stdout=$(cat "$POC8_OUT")
assert_contains "$poc8_stdout" "MIXTE" \
  "renommage .env impossible : le message dit explicitement l'état mixte"
assert_contains "$poc8_stdout" "compose.yml a bien" \
  "renommage .env impossible : le message précise ce qui a réussi"
leftover8=$(find "$POC8_WORK/deploy" -name '.env.??????' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$leftover8" "renommage .env impossible : le fichier temporaire .env est nettoyé"

# --- Non-régression : le suffixe ".env" ne doit pas casser .env.example ----
# (garde-fou pour ce test lui-même : vérifie que le mv() de substitution ne
# confond pas les deux fichiers avant de s'y fier pour les preuves 4 et 5)
POC9_WORK="$WORK/poc9"; mkdir -p "$POC9_WORK"
rc9=$(_run_gen_compose_broken_mv "$POC9_WORK" "$ENV_FIX" "$SPEC_FIX" "poc9" "/aucun-fichier-ne-finit-comme-ca")
assert_eq "0" "$rc9" "garde-fou du test : un suffixe qui ne correspond à rien laisse gen_compose réussir normalement"
assert_eq "1" "$([[ -f "$POC9_WORK/deploy/.env.example" ]] && echo 1 || echo 0)" \
  "garde-fou du test : .env.example est bien généré (le mv() de substitution ne le bloque pas par erreur)"

finish
