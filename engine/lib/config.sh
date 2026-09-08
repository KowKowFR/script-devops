#!/usr/bin/env bash
# engine/lib/config.sh — lecture des paramètres depuis runs/<ws>/env.json.
#
# POURQUOI DU JSON ET PLUS DU SHELL
# L'ancien .bootstrap-env était un fichier `VAR="valeur"` chargé par `source`.
# Toute valeur contenant $(…) ou des backticks s'exécutait au chargement — une
# saisie du formulaire web devenait une exécution de code. Ici, les valeurs sont
# extraites par jq et ne traversent jamais l'évaluateur du shell.
#
# Dépend de : die (lib/runtime.sh), jq.

ENV_JSON="${ENV_JSON:-}"
SPEC_JSON="${SPEC_JSON:-}"

# config_init WORKSPACE_DIR — positionne ENV_JSON et SPEC_JSON, vérifie leur
# lisibilité et leur validité syntaxique.
config_init() {
  local ws_dir="${1:?config_init requiert un répertoire de workspace}"
  ENV_JSON="${ws_dir}/env.json"
  SPEC_JSON="${ws_dir}/spec.json"

  [[ -f "$ENV_JSON" ]] || die "env.json introuvable : ${ENV_JSON}" 2
  jq -e . "$ENV_JSON" >/dev/null 2>&1 || die "env.json n'est pas du JSON valide" 2
}

# cfg CHEMIN [DÉFAUT] — valeur scalaire, chemin pointé ("target.host").
cfg() {
  local path="${1:?cfg requiert un chemin}" default="${2:-}"
  local value
  value=$(jq -r --arg p "$path" '
    getpath($p | split(".")) // empty
    | if type == "boolean" or type == "number" then tostring else . end
  ' "$ENV_JSON" 2>/dev/null || printf '')
  if [[ -z "$value" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$value"
  fi
}

# cfg_req CHEMIN — comme cfg, mais échec fatal si la valeur est absente ou vide.
cfg_req() {
  local path="${1:?cfg_req requiert un chemin}"
  local value
  value=$(cfg "$path")
  [[ -n "$value" ]] || die "paramètre requis manquant dans env.json : ${path}" 2
  printf '%s' "$value"
}

# cfg_bool CHEMIN — code 0 si la valeur vaut exactement true, 1 sinon.
cfg_bool() {
  [[ "$(cfg "${1:?cfg_bool requiert un chemin}")" == "true" ]]
}

# cfg_port SERVICE_ID — port hôte alloué pour ce service.
# L'engine ne CHOISIT jamais un port : il le reçoit. Un port < 1024 est refusé
# parce que les conteneurs tournent en utilisateur non privilégié.
cfg_port() {
  local sid="${1:?cfg_port requiert un id de service}"
  local port
  port=$(jq -r --arg s "$sid" '.ports[$s] // empty | tostring' "$ENV_JSON" 2>/dev/null || printf '')
  [[ -n "$port" ]] || die "aucun port hôte alloué pour le service '${sid}' (env.json .ports)" 2
  [[ "$port" =~ ^[0-9]+$ ]] || die "port hôte non numérique pour '${sid}' : ${port}" 2
  (( port >= 1024 && port <= 65535 )) \
    || die "port hôte hors plage pour '${sid}' : ${port} (attendu 1024-65535)" 2
  printf '%s' "$port"
}
