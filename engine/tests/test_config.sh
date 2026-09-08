#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

RT="$ENGINE_DIR/lib/runtime.sh"
CF="$ENGINE_DIR/lib/config.sh"
FIX="$TESTS_DIR/fixtures/env.min.json"

run_cfg() { bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; $*" 2>/dev/null; }

assert_eq "demo-app"   "$(run_cfg 'cfg app.name')"        "cfg lit un chemin pointé"
assert_eq "192.0.2.10" "$(run_cfg 'cfg target.host')"     "cfg lit un chemin imbriqué"
assert_eq ""           "$(run_cfg 'cfg absent.total')"    "cfg renvoie vide si absent"
assert_eq "repli"      "$(run_cfg 'cfg absent.total repli')" "cfg applique le défaut"
assert_eq ""           "$(run_cfg 'cfg target.password')" "cfg renvoie vide sur chaîne vide"

# La valeur ne doit jamais être interprétée par le shell : c'est tout l'intérêt
# du passage au JSON. Un token contenant des guillemets doit ressortir intact.
assert_eq 'tok"avec"guillemets' "$(run_cfg 'cfg registry.token')" \
  "cfg ne réinterprète pas les guillemets"

# Une valeur contenant une substitution de commande doit ressortir littérale.
tmp=$(mktemp); printf '{"x":"$(touch /tmp/deploymatic_pwned)"}' > "$tmp"
bash -c "source '$RT'; source '$CF'; ENV_JSON='$tmp'; cfg x" >/dev/null 2>&1
assert_eq "0" "$([[ -f /tmp/deploymatic_pwned ]] && echo 1 || echo 0)" \
  "cfg n'exécute pas une substitution de commande présente dans la valeur"
rm -f "$tmp" /tmp/deploymatic_pwned

# cfg_req
assert_exit_code 0 "cfg_req passe quand la clé existe" -- \
  bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; cfg_req app.name"
assert_exit_code 2 "cfg_req meurt en code 2 si absente" -- \
  bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; cfg_req rien.du.tout"

# cfg_bool
assert_exit_code 0 "cfg_bool vrai"  -- \
  bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; cfg_bool options.reuse_existing_dir"
assert_exit_code 1 "cfg_bool faux"  -- \
  bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; cfg_bool options.allow_existing_repo"
assert_exit_code 1 "cfg_bool absent" -- \
  bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; cfg_bool github.enabled"

# cfg_port
assert_eq "10001" "$(run_cfg 'cfg_port api')" "cfg_port lit un port alloué"
assert_exit_code 2 "cfg_port refuse un port < 1024" -- \
  bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; cfg_port trop_bas"
assert_exit_code 2 "cfg_port meurt si le port est absent" -- \
  bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; cfg_port fantome"

# Plus aucune trace de l'ancien mécanisme
assert_not_contains "$(cat "$CF")" "ALL_VARS"  "ALL_VARS a disparu"
assert_not_contains "$(cat "$CF")" "source \"\$ENV_FILE\"" "plus de source du fichier d'env"

# ----- Helpers de lecture du spec -----------------------------------------
SPEC="$TESTS_DIR/fixtures/spec.multi.json"
run_spec() { bash -c "source '$RT'; source '$CF'; SPEC_JSON='$SPEC'; $*" 2>/dev/null; }

assert_eq "api web db testcase" "$(run_spec 'spec_service_ids' | tr '\n' ' ' | sed 's/ $//')" \
  "spec_service_ids liste les quatre services"
assert_eq "3000"  "$(run_spec 'spec_get api port')"           "spec_get lit le port conteneur"
assert_eq "/api/" "$(run_spec 'spec_get api expose')"         "spec_get lit expose"
assert_eq "postgres:16-alpine" "$(run_spec 'spec_get db image')" "spec_get lit image"
assert_eq "repli" "$(run_spec 'spec_get web image repli')"    "spec_get applique le défaut"

assert_exit_code 0 "db est interne"      -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$SPEC'; spec_is_internal db"
assert_exit_code 1 "api n'est pas interne" -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$SPEC'; spec_is_internal api"
assert_exit_code 0 "api est exposé"      -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$SPEC'; spec_is_exposed api"
assert_exit_code 1 "db n'est pas exposé"  -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$SPEC'; spec_is_exposed db"

# Le plus spécifique d'abord : /api/ (5 caractères) avant / (1 caractère)
assert_eq "api web" \
  "$(run_spec 'spec_exposed_ids_by_path_length' | tr '\n' ' ' | sed 's/ $//')" \
  "les chemins exposés sont triés du plus spécifique au plus général"

# spec_get doit distinguer un champ absent d'un champ présent mais vide/false
assert_eq "" "$(run_spec 'spec_get testcase empty_string defaut_vide')" \
  "spec_get retourne chaîne vide explicite (pas le défaut)"
assert_eq "false" "$(run_spec 'spec_get testcase false_bool')" \
  "spec_get retourne false comme 'false' (pas le défaut)"
assert_eq "defaut" "$(run_spec 'spec_get testcase null_val defaut')" \
  "spec_get applique le défaut pour null"
assert_eq "0" "$(run_spec 'spec_get testcase zero_num')" \
  "spec_get retourne 0 comme '0' (pas le défaut)"

# spec_init doit rejeter tout id de service hors [A-Za-z0-9_-] : c'est lui
# qui sert de clé de mapping YAML brute dans gen_compose.sh, et à terme
# spec.json sera généré par un LLM (jalon 5) — son contenu n'est pas fiable.
# La validation vit dans spec_init pour protéger TOUS les consommateurs.
BADID_SPEC=$(mktemp)
cat > "$BADID_SPEC" <<'EOF'
{"name":"poc","services":[{"id":"svc bad","image":"alpine"}]}
EOF
assert_exit_code 2 "spec_init rejette un id de service contenant un espace" -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$BADID_SPEC'; spec_init"
rm -f "$BADID_SPEC"

BADID_SPEC2=$(mktemp)
printf '{"name":"poc","services":[{"id":"svc$(id)","image":"alpine"}]}' > "$BADID_SPEC2"
assert_exit_code 2 "spec_init rejette un id de service contenant \$(...)" -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$BADID_SPEC2'; spec_init"
rm -f "$BADID_SPEC2"

BADID_SPEC3=$(mktemp)
cat > "$BADID_SPEC3" <<'EOF'
{"name":"poc","services":[{"id":"svc/evil","image":"alpine"}]}
EOF
assert_exit_code 2 "spec_init rejette un id de service contenant '/'" -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$BADID_SPEC3'; spec_init"
rm -f "$BADID_SPEC3"

GOODID_SPEC=$(mktemp)
cat > "$GOODID_SPEC" <<'EOF'
{"name":"poc","services":[{"id":"svc-good_1","image":"alpine"}]}
EOF
assert_exit_code 0 "spec_init accepte un id de service lettres/chiffres/_/-'" -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$GOODID_SPEC'; spec_init"
rm -f "$GOODID_SPEC"

# ----- Revue round 2, finding A : id de service vide -----------------------
# Un id vide échoue la regex [A-Za-z0-9_-]+ (le '+' exige au moins un
# caractère) donc était déjà "détecté" comme invalide — mais join(", ") sur
# UNE liste contenant UNE seule chaîne vide produit "" : indistinguable de
# "aucun id invalide" pour un `[[ -z "$bad_ids" ]]`. La décision doit se
# prendre sur un COMPTE d'éléments, jamais sur le résultat d'un join().

# Preuve 1 : un seul service, id vide.
EMPTYID_SPEC1=$(mktemp)
cat > "$EMPTYID_SPEC1" <<'EOF'
{"name":"poc","services":[{"id":"","image":"alpine"}]}
EOF
assert_exit_code 2 "spec_init meurt sur un id de service vide (un seul service)" -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$EMPTYID_SPEC1'; spec_init"
# die()/emit_fail impriment le message JSON sur stdout (contrat du projet).
empty1_msg=$(bash -c "source '$RT'; source '$CF'; SPEC_JSON='$EMPTYID_SPEC1'; spec_init" 2>/dev/null)
assert_contains "$empty1_msg" "<vide>" \
  "message d'id vide lisible ('<vide>', pas un trou dans la phrase)"
rm -f "$EMPTYID_SPEC1"

# Preuve 2 : deux services déclarés, un seul id vide — vérifie que le cas à
# UN SEUL élément invalide (même noyé parmi plusieurs services déclarés)
# n'est plus masqué par le join().
EMPTYID_SPEC2=$(mktemp)
cat > "$EMPTYID_SPEC2" <<'EOF'
{"name":"poc","services":[{"id":"","image":"alpine"},{"id":"good","image":"alpine"}]}
EOF
assert_exit_code 2 "spec_init meurt sur un id vide même noyé parmi un id valide (deux services déclarés)" -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$EMPTYID_SPEC2'; spec_init"
rm -f "$EMPTYID_SPEC2"

# Bonus : le même défaut de logique existait, de façon plus discrète, dans le
# contrôle de DOUBLONS — masqué précisément quand il y a deux ids vides
# dupliqués (join donne ", ", non vide, donc il "marchait par accident").
# Toujours vrai après le correctif, testé explicitement pour ne pas régresser.
DUPEEMPTY_SPEC=$(mktemp)
cat > "$DUPEEMPTY_SPEC" <<'EOF'
{"name":"poc","services":[{"id":"","image":"alpine"},{"id":"","image":"alpine"}]}
EOF
assert_exit_code 2 "spec_init meurt sur deux ids vides dupliqués (contrôle de doublons)" -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$DUPEEMPTY_SPEC'; spec_init"
rm -f "$DUPEEMPTY_SPEC"

# spec_get doit appliquer le défaut quand le service n'existe pas (finding A)
assert_eq "mondefaut" "$(run_spec 'spec_get service_inexistant champ mondefaut')" \
  "spec_get applique le défaut quand le service n'existe pas"
assert_eq "" "$(run_spec 'spec_get service_inexistant champ')" \
  "spec_get retourne vide (défaut vide) quand service inexistant sans défaut"
assert_eq "" "$(run_spec 'spec_get testcase empty_string mondefaut')" \
  "non-régression : champ '' avec défaut non-vide retourne '' (pas le défaut)"

finish
