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

assert_eq "api web db" "$(run_spec 'spec_service_ids' | tr '\n' ' ' | sed 's/ $//')" \
  "spec_service_ids liste les trois services"
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

finish
