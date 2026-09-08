#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ENV_FIX="$TESTS_DIR/fixtures/env.min.json"
SPEC_FIX="$TESTS_DIR/fixtures/spec.multi.json"

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

# Compose lui-même doit accepter le fichier
if command -v docker >/dev/null 2>&1; then
  rc=0
  (cd "$WORK/deploy" && docker compose config --quiet) >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "docker compose config --quiet accepte le fichier généré"
else
  printf '  (docker absent — validation compose sautée)\n'
fi

finish
