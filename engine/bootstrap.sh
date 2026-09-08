#!/usr/bin/env bash
# =============================================================================
#  engine/bootstrap.sh — exécuteur d'étapes de DeployMatic.
#
#  Ce script ne décide plus de rien. Il exécute UNE étape qu'on lui nomme, avec
#  les paramètres qu'on lui donne en JSON. La séquence des étapes et le suivi
#  d'avancement vivent côté panel (jalon 2) ; le mode --all n'existe que pour
#  pouvoir tester l'engine seul.
#
#  Usage :
#    bootstrap.sh --workspace <ws> --step <nom>    exécute une étape
#    bootstrap.sh --workspace <ws> --all           exécute toute la séquence
#    bootstrap.sh --list-steps                     liste les étapes connues
#    bootstrap.sh --workspace <ws> --step <nom> --dry-run
#
#  Entrées  : runs/<ws>/env.json et runs/<ws>/spec.json
#  Sortie   : logs sur stderr, UNE ligne JSON sur stdout
#  Codes    : 0 succès, 1 échec réessayable, 2 échec fatal
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT
readonly RUNS_DIR="${REPO_ROOT}/runs"

# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/runtime.sh
source "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=lib/units.sh
source "$SCRIPT_DIR/lib/units.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/ssh_remote.sh
source "$SCRIPT_DIR/lib/ssh_remote.sh"
# shellcheck source=lib/prereqs.sh
source "$SCRIPT_DIR/lib/prereqs.sh"
# shellcheck source=lib/steps.sh
source "$SCRIPT_DIR/lib/steps.sh"
# shellcheck source=lib/diag.sh
source "$SCRIPT_DIR/lib/diag.sh"

# ----- Séquence d'étapes ----------------------------------------------------
# Ordre utilisé par --all uniquement. La séquence de référence vit côté panel.
# Le bloc GitHub est en fin de liste : une panne GitHub ne doit jamais empêcher
# un déploiement d'aboutir.
STEPS=(
  check_prereqs
  validate_ssh
  create_project_dir
  generate_microservices
  generate_compose
  generate_skills
  generate_workflow
  enable_sudo_nopasswd
  prepare_server
  build_images
  deploy_stack
  validate_deployment
  github_create_repo
  github_set_secrets
  git_init
  git_push
)

# ----- Parsing des arguments ------------------------------------------------
WS_NAME=""
STEP_NAME=""
MODE=""
DRY_RUN=0

while (( $# > 0 )); do
  case "$1" in
    --workspace|-w)
      [[ $# -ge 2 ]] || die "--workspace requiert une valeur (nom de workspace)" 2
      WS_NAME="$2"; shift 2 ;;
    --step)
      [[ $# -ge 2 ]] || die "--step requiert une valeur (nom d'étape)" 2
      STEP_NAME="$2"; MODE="step"; shift 2 ;;
    --all)          MODE="all"; shift ;;
    --list-steps)   MODE="list"; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --help|-h)      MODE="help"; shift ;;
    *)
      printf 'Argument inconnu : %s\n' "$1" >&2
      die "argument inconnu : $1" 2
      ;;
  esac
done

# ----- Modes sans workspace -------------------------------------------------
case "$MODE" in
  list)
    printf '%s\n' "${STEPS[@]}"
    exit 0
    ;;
  help)
    sed -n '2,20p' "$0" | sed 's/^#  \{0,1\}//'
    exit 0
    ;;
esac

# ----- Validation du nom de workspace ---------------------------------------
# Défense en profondeur : le panel valide déjà (jalon 2), mais l'engine ne fait
# jamais confiance à son appelant. C'est ce qui ferme --workspace ../../etc.
if [[ ! "$WS_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$ ]]; then
  die "nom de workspace invalide : '${WS_NAME}' (attendu : ^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$)" 2
fi

WS_DIR="${RUNS_DIR}/${WS_NAME}"
[[ -d "$WS_DIR" ]] || die "workspace inexistant : ${WS_DIR}" 2

config_init "$WS_DIR"

APP_NAME="$(cfg_req app.name)"
WORK_DIR="${WS_DIR}/${APP_NAME}"
export WS_NAME WS_DIR WORK_DIR APP_NAME DRY_RUN

# ----- Exécution ------------------------------------------------------------
install_error_trap

step_exists() {
  local candidate="$1" s
  for s in "${STEPS[@]}"; do
    [[ "$s" == "$candidate" ]] && return 0
  done
  return 1
}

run_one_step() {
  local name="$1"
  step_exists "$name" || die "étape inconnue : ${name} (voir --list-steps)" 2
  declare -F "step_${name}" >/dev/null \
    || die "étape déclarée mais non implémentée : step_${name}" 2

  # Réarme la garde anti-doublon pour CETTE étape : indispensable en mode
  # --all où plusieurs étapes tournent dans le même process (cf. commentaire
  # de _runtime_begin_step, lib/runtime.sh).
  _runtime_begin_step "$name"
  ui_step "$name"
  "step_${name}"
}

case "$MODE" in
  step)
    [[ -n "$STEP_NAME" ]] || die "--step requiert un nom d'étape" 2
    run_one_step "$STEP_NAME"
    ;;
  all)
    # Mode de test de l'engine seul : chaque étape imprime sa ligne JSON, donc
    # stdout contient N lignes. C'est une entorse assumée au contrat, réservée
    # à --all, qui n'est jamais appelé par le panel.
    ui_warn "--all : mode de test, stdout contiendra une ligne JSON par étape"
    for s in "${STEPS[@]}"; do
      run_one_step "$s"
    done
    ;;
  *)
    die "préciser --step <nom>, --all ou --list-steps" 2
    ;;
esac
