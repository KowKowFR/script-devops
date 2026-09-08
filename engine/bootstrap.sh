#!/usr/bin/env bash
# Re-exec sous bash non-POSIX si lancé via sh / bash --posix (sinon la
# process substitution `>(...)` utilisée par lib/runtime.sh casserait).
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
case $- in *p*) exec /usr/bin/env bash "$0" "$@" ;; esac

# =============================================================================
#  bootstrap.sh
#  -----------------------------------------------------------------------------
#  Déploie le TP DevSecOps de A à Z en un seul script.
#
#  Pré-requis (vérifiés par le script) :
#    - git, gh (GitHub CLI), ssh, ssh-keygen, curl, jq
#    - docker, kubectl, claude (optionnels mais recommandés)
#    - gum (charm.sh/gum) pour le TUI — installation proposée si manquant
#    - un serveur SSH-accessible avec sudo
#    - un compte GitHub et un compte Docker Hub
#
#  Le script est idempotent : un fichier .bootstrap-state suit la progression.
#  Relancer le script reprend exactement où il s'était arrêté.
#  Pour repartir de zéro : ./bootstrap.sh --reset
#
#  Usage :
#    ./bootstrap.sh                       # exécution normale (TUI gum)
#    ./bootstrap.sh --dry-run             # montre ce qui serait fait
#    ./bootstrap.sh --config FILE         # mode non-interactif (CI/CD)
#    ./bootstrap.sh --reset               # efface l'état et recommence
#    ./bootstrap.sh --status              # affiche les étapes restantes
#    ./bootstrap.sh --doctor              # diagnostic global post-install
#    ./bootstrap.sh --logs [api|web]      # tail des logs d'un pod
#    ./bootstrap.sh --cluster-info        # état pods/svc/ingress
#    ./bootstrap.sh --help                # affiche cette aide
# =============================================================================

set -euo pipefail

# ----- Chargement des modules -----------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT

# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/workspace.sh
source "$SCRIPT_DIR/lib/workspace.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/ssh_remote.sh
source "$SCRIPT_DIR/lib/ssh_remote.sh"
# shellcheck source=lib/runtime.sh
source "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=lib/prereqs.sh
source "$SCRIPT_DIR/lib/prereqs.sh"
# shellcheck source=lib/collect.sh
source "$SCRIPT_DIR/lib/collect.sh"
# shellcheck source=lib/steps.sh
source "$SCRIPT_DIR/lib/steps.sh"
# shellcheck source=lib/diag.sh
source "$SCRIPT_DIR/lib/diag.sh"

# ----- Constantes -----------------------------------------------------------
readonly RUNS_DIR="${REPO_ROOT}/runs"
readonly PROJECT_NAME="tp-devops-agent-ia"

# Workspace courant (peut être surchargé par --workspace ou $WORKSPACE).
# Les fichiers d'état dépendent du workspace sélectionné — initialisés plus bas
# après le parsing des args.
WORKSPACE="${WORKSPACE:-default}"

# Variables ré-affectées en fin d'args parsing (cf. _init_workspace_paths).
STATE_FILE=""
ENV_FILE=""
LOG_FILE=""
LOCK_FILE=""
WORK_DIR=""
WORKSPACE_DIR=""

_init_workspace_paths() {
  WORKSPACE_DIR="${RUNS_DIR}/${WORKSPACE}"
  STATE_FILE="${WORKSPACE_DIR}/.bootstrap-state"
  ENV_FILE="${WORKSPACE_DIR}/.bootstrap-env"
  LOG_FILE="${WORKSPACE_DIR}/.bootstrap.log"
  LOCK_FILE="${WORKSPACE_DIR}/.bootstrap.lock"
  WORK_DIR="${WORKSPACE_DIR}/${PROJECT_NAME}"
  mkdir -p "$WORKSPACE_DIR"
}

DRY_RUN=0

# ----- Pipeline -------------------------------------------------------------
# Format : "state_id|titre|fonction"
# Préfixer state_id par "_" pour une étape transitoire (pas de state tracking,
# pas comptée dans la numérotation N/TOTAL).
PIPELINE=(
  "prereqs_checked|Vérification des pré-requis|check_prereqs"
  "credentials_collected|Collecte des informations du projet|collect_credentials"
  "_confirm|Confirmation des paramètres|confirm_summary"
  "ssh_validated|Validation de l'accès SSH au serveur|step_validate_ssh"
  "project_dir_created|Création du dossier projet|step_create_project_dir"
  "microservices_generated|Génération des microservices (API + Front)|step_generate_microservices"
  "manifests_generated|Génération des manifests Kubernetes|step_generate_manifests"
  "skills_generated|Génération des Skills Claude Code|step_generate_skills"
  "workflow_generated|Génération du workflow CI/CD GitHub Actions|step_generate_workflow"
  "sudo_nopasswd_enabled|Configuration de sudo NOPASSWD|step_enable_sudo_nopasswd"
  "server_prepared|Préparation du serveur (k3s, kubectl, docker)|step_prepare_server"
  "kubeconfig_fetched|Récupération du kubeconfig|step_fetch_kubeconfig"
  "_list_ports|Inventaire des ports déjà utilisés|step_list_cluster_ports"
  "initial_manifests_applied|Application initiale des manifests Kubernetes|step_apply_initial_manifests"
  "github_repo_created|Création du dépôt GitHub|step_create_github_repo"
  "github_secrets_set|Configuration des secrets GitHub Actions|step_set_github_secrets"
  "git_initialized|Initialisation Git local|step_init_git"
  "git_pushed|Push initial vers GitHub|step_push_to_github"
  "first_deploy_triggered|Premier déploiement (CI/CD)|step_trigger_first_deploy"
  "deployment_validated|Validation du déploiement|step_validate_deployment"
)

# ----- Runner ---------------------------------------------------------------
_pipeline_total() {
  local entry n=0
  for entry in "${PIPELINE[@]}"; do
    [[ "${entry%%|*}" == _* ]] || n=$((n + 1))
  done
  echo "$n"
}

run_pipeline() {
  local total
  total=$(_pipeline_total)

  local idx=0 entry id title fn label
  for entry in "${PIPELINE[@]}"; do
    id="${entry%%|*}"
    title="${entry#*|}"; title="${title%|*}"
    fn="${entry##*|}"

    if [[ "$id" == _* ]]; then
      label="$title"
    else
      idx=$((idx + 1))
      label="${idx}/${total}  ${title}"
    fi

    ui_step "$label"

    if [[ "$id" != _* ]] && state_has "$id"; then
      ui_skip "$title"
      continue
    fi

    if (( DRY_RUN == 1 )); then
      ui_info "[dry-run] appellerait ${fn}()"
      continue
    fi

    _CURRENT_STEP="$title"
    "$fn"
    _CURRENT_STEP=""

    [[ "$id" != _* ]] && state_mark "$id"
  done
}

# ----- Args parsing ---------------------------------------------------------
CONFIG_FILE=""
ACTION="run"
LOGS_TARGET="api"
RM_WORKSPACE_NAME=""

while (( $# > 0 )); do
  case "$1" in
    --reset)            ACTION="reset" ;;
    --status)           ACTION="status" ;;
    --doctor)           ACTION="doctor" ;;
    --cluster-info)     ACTION="cluster-info" ;;
    --logs)
      ACTION="logs"
      if [[ "${2:-}" =~ ^(api|web)$ ]]; then
        LOGS_TARGET="$2"
        shift
      fi
      ;;
    --dry-run)          DRY_RUN=1 ;;
    --config)
      CONFIG_FILE="${2:?--config requires a file argument}"
      export BOOTSTRAP_NONINTERACTIVE=1
      shift
      ;;
    --workspace|-w)
      WORKSPACE="${2:?--workspace requires a name}"
      shift
      ;;
    --list-workspaces|--ls) ACTION="list-workspaces" ;;
    --rm-workspace)
      ACTION="rm-workspace"
      RM_WORKSPACE_NAME="${2:?--rm-workspace requires a name}"
      shift
      ;;
    --claude|claude)    ACTION="claude" ;;
    --help|-h)          ACTION="help" ;;
    *)
      echo "Argument inconnu : $1" >&2
      echo "Usage : $0 [--workspace NAME] [--reset|--status|--doctor|--logs|--cluster-info|--dry-run|--claude|--config FILE|--list-workspaces|--rm-workspace NAME|--help]" >&2
      exit 1
      ;;
  esac
  shift
done

# ----- Banner DeployMatic : LA TOUTE PREMIÈRE chose visible -----------------
# Affiché avant migration / log_init / ensure_gum pour qu'aucun message
# d'init ne s'imprime avant le logo. Exception : --claude (hand-off direct).
if [[ "$ACTION" != "claude" ]]; then
  show_banner
fi

# Migration auto de l'ancien layout (.bootstrap-* à la racine) vers runs/default/
ws_migrate_legacy

# Initialise les paths après le parsing (donc --workspace est pris en compte)
_init_workspace_paths

# ----- Actions sans pipeline (read-only ou diagnostic) ----------------------
case "$ACTION" in
  help)
    cat <<'EOF'
Usage : ./bootstrap.sh [--workspace NAME] [OPTION]

Déploie le TP DevSecOps de A à Z (microservices + K8s + CI/CD + skills).

Sélection du workspace (projet) :
  --workspace NAME    Nom du workspace à utiliser (défaut : "default").
  -w NAME             Alias court de --workspace.
  --list-workspaces   Liste tous les workspaces sauvegardés.
  --ls                Alias de --list-workspaces.
  --rm-workspace NAME Supprime un workspace (sauf "default").

Options principales :
  (aucun)             Exécution interactive (TUI gum), reprise depuis l'état
                      courant du workspace.
  --config FILE       Mode non-interactif : charge VAR=value depuis FILE.
  --dry-run           Liste les étapes qui seraient exécutées, sans rien faire.
  --reset             Efface l'état et les credentials du workspace courant.
  --status            Affiche la progression du workspace courant.

Diagnostic (post-bootstrap) :
  --doctor            Diagnostic global : SSH, cluster, secrets, pods, HTTP.
  --logs [api|web]    Tail les logs des pods api ou web (défaut: api).
  --cluster-info      Affiche pods/svc/ingress/nodes du cluster.

Productivité :
  --claude (claude)   cd dans le projet et lance la CLI `claude`.

Divers :
  --help, -h          Affiche cette aide.

Fichiers gérés (sous runs/<workspace>/) :
  .bootstrap-state    Liste des étapes déjà accomplies (idempotence).
  .bootstrap-env      Credentials collectés (chmod 600, ne pas versionner).
  .bootstrap.log      Trace horodatée (mode non-interactif ou BOOTSTRAP_LOG=1).
  .bootstrap.lock     Anti-concurrence ; supprimer manuellement si stale.
  tp-devops-agent-ia/ Dossier du projet généré par ce workspace.

Variables d'environnement :
  WORKSPACE=NAME      Équivalent à --workspace NAME.
  BOOTSTRAP_LOG=1     Force l'écriture du .bootstrap.log même en interactif.

Exemples :
  ./bootstrap.sh                            # workspace "default"
  ./bootstrap.sh --workspace tp1            # workspace "tp1"
  ./bootstrap.sh -w prod --doctor           # doctor sur le workspace "prod"
  ./bootstrap.sh --list-workspaces          # voir tous les workspaces
  ./bootstrap.sh --rm-workspace old-tp      # supprimer
EOF
    exit 0
    ;;
  list-workspaces) ws_list; exit 0 ;;
  rm-workspace)    ws_delete "$RM_WORKSPACE_NAME"; exit $? ;;
  reset)         state_reset; exit 0 ;;
  status)        state_show; exit 0 ;;
  doctor)        load_env >/dev/null 2>&1 || true; cmd_doctor; exit $? ;;
  cluster-info)  load_env >/dev/null 2>&1 || true; cmd_cluster_info; exit $? ;;
  logs)          load_env >/dev/null 2>&1 || true; cmd_logs "$LOGS_TARGET"; exit $? ;;
  claude)
    if ! command -v claude >/dev/null 2>&1; then
      echo "claude CLI introuvable dans le PATH." >&2
      echo "Installation : https://docs.claude.com/claude-code" >&2
      exit 1
    fi
    if [[ ! -d "$WORK_DIR" ]]; then
      echo "Projet introuvable : ${WORK_DIR}" >&2
      echo "Lance d'abord ./bootstrap.sh pour le générer." >&2
      exit 1
    fi
    cd "$WORK_DIR"
    exec claude
    ;;
esac

# ----- Orchestration (run / dry-run) ----------------------------------------
# Logging fichier : actif en mode non-interactif (CI), ou via BOOTSTRAP_LOG=1,
# ou si stdout est piped (pas un TTY). Désactivé en interactif pour ne pas
# casser le rendu live de gum (curseur, animations…).
if [[ ! -t 1 ]] \
   || [[ "${BOOTSTRAP_NONINTERACTIVE:-0}" == "1" ]] \
   || [[ "${BOOTSTRAP_LOG:-0}" == "1" ]]
then
  log_init
fi

install_error_trap
acquire_lock

ensure_gum
# Banner déjà affiché en haut du script (avant la migration / log_init)
ui_info "Workspace : ${WORKSPACE}  (runs/${WORKSPACE}/)"
load_env

if [[ -n "$CONFIG_FILE" ]]; then
  load_config_file "$CONFIG_FILE"
  save_env
fi

if (( DRY_RUN == 1 )); then
  ui_warn "Mode DRY-RUN : aucune modification ne sera effectuée."
fi

run_pipeline

if (( DRY_RUN == 0 )); then
  print_success
else
  ui_ok "Dry-run terminé."
fi
