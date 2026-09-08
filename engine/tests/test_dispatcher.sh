#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

BS="$ENGINE_DIR/bootstrap.sh"

# --list-steps ne nécessite pas de workspace
out=$(bash "$BS" --list-steps 2>/dev/null)
assert_contains "$out" "generate_compose" "--list-steps mentionne generate_compose"
assert_contains "$out" "deploy_stack"     "--list-steps mentionne deploy_stack"
assert_not_contains "$out" "kubeconfig"   "--list-steps ne mentionne plus le kubeconfig"

# Noms de workspace : la défense en profondeur contre la traversée de chemin
assert_exit_code 2 "refuse un workspace avec ../" -- \
  bash "$BS" --workspace "../../etc" --step check_prereqs
assert_exit_code 2 "refuse un workspace avec /" -- \
  bash "$BS" --workspace "a/b" --step check_prereqs
assert_exit_code 2 "refuse un workspace vide" -- \
  bash "$BS" --workspace "" --step check_prereqs

# Étape inconnue → code 2, et une ligne JSON quand même
out=$(bash "$BS" --workspace demo --step etape_qui_nexiste_pas 2>/dev/null)
assert_valid_json "$out" "une étape inconnue produit tout de même du JSON"
assert_eq "false" "$(printf '%s' "$out" | jq -r .ok)" "étape inconnue → ok=false"

# env.json manquant → code 2, JSON sur stdout
rm -rf "$REPO_ROOT/runs/test-dispatch"
mkdir -p "$REPO_ROOT/runs/test-dispatch"
out=$(bash "$BS" --workspace test-dispatch --step check_prereqs 2>/dev/null)
assert_valid_json "$out" "env.json manquant produit du JSON"
assert_contains "$(printf '%s' "$out" | jq -r .error)" "env.json" \
  "le message d'erreur nomme env.json"

# Un workspace valide avec une fixture : stdout doit tenir sur UNE ligne
cp "$TESTS_DIR/fixtures/env.min.json" "$REPO_ROOT/runs/test-dispatch/env.json"
lines=$(bash "$BS" --workspace test-dispatch --step check_prereqs 2>/dev/null | wc -l | tr -d ' ')
assert_eq "1" "$lines" "une étape imprime exactement une ligne sur stdout"

# --dry-run n'exécute rien mais reste contractuel
out=$(bash "$BS" --workspace test-dispatch --step validate_ssh --dry-run 2>/dev/null)
assert_valid_json "$out" "--dry-run produit du JSON"
assert_eq "true" "$(printf '%s' "$out" | jq -r .ok)" "--dry-run réussit sans rien faire"

# ==========================================================================
# Preuve 1 — bloc GitHub optionnel : github.enabled=false (fixture env.min)
# court-circuite les 4 étapes en emit_ok {"skipped":true}, jamais en échec.
# Une panne GitHub ne doit jamais empêcher un déploiement d'aboutir.
# ==========================================================================
for gh_step in github_create_repo github_set_secrets git_init git_push; do
  out=$(bash "$BS" --workspace test-dispatch --step "$gh_step" 2>/dev/null)
  assert_valid_json "$out" "${gh_step} (github.enabled=false) : produit du JSON"
  assert_eq "true" "$(printf '%s' "$out" | jq -r .ok)" \
    "${gh_step} (github.enabled=false) : ok=true (pas un échec)"
  assert_eq "true" "$(printf '%s' "$out" | jq -r .data.skipped)" \
    "${gh_step} (github.enabled=false) : data.skipped=true"
done

rm -rf "$REPO_ROOT/runs/test-dispatch"
finish
