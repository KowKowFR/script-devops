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

# ----- Lecture du spec d'application ---------------------------------------
# spec.json décrit les services de l'application déployée. Il remplace le
# couple "api + web" codé en dur : une app générée par IA (jalon 5) n'aura pas
# toujours cette forme.

spec_init() {
  [[ -f "$SPEC_JSON" ]] || die "spec.json introuvable : ${SPEC_JSON}" 2
  jq -e . "$SPEC_JSON" >/dev/null 2>&1 || die "spec.json n'est pas du JSON valide" 2
  jq -e '.services | type == "array" and length > 0' "$SPEC_JSON" >/dev/null 2>&1 \
    || die "spec.json doit contenir un tableau 'services' non vide" 2

  # Défense en profondeur contre l'injection YAML (cf. gen_compose.sh) : l'id
  # de service atterrit tel quel comme clé de mapping YAML (`printf '  %s:\n'
  # "$sid"`). Le placer ici, dans spec_init, protège TOUS les consommateurs de
  # spec.json — pas seulement gen_compose — dès aujourd'hui et pour les
  # consommateurs futurs (jalon 5 : spec.json généré par un LLM).
  #
  # Piège corrigé (revue round 2) : la présence d'ids invalides NE DOIT PAS se
  # décider sur le résultat d'un `join(", ")` — un id vide, unique invalide
  # trouvé, joint en chaîne VIDE, indistinguable de "aucun id invalide" pour
  # un `[[ -z "$bad_ids" ]]`. Le nombre d'éléments (`length`) est la seule
  # information fiable ; la chaîne jointe ne sert plus qu'au message.
  local bad_result bad_count bad_ids
  bad_result=$(jq -c '
    [ .services[].id
      | (if type == "string" then . else tojson end) as $s
      | select(($s | test("^[A-Za-z0-9_-]+$")) | not)
      | (if $s == "" then "<vide>" else $s end)
    ] as $bad
    | {count: ($bad | length), joined: ($bad | join(", "))}
  ' "$SPEC_JSON" 2>/dev/null)
  bad_count=$(printf '%s' "$bad_result" | jq -r '.count // 0' 2>/dev/null)
  bad_ids=$(printf '%s' "$bad_result" | jq -r '.joined // ""' 2>/dev/null)
  [[ "${bad_count:-0}" -gt 0 ]] \
    && die "id(s) de service invalide(s) dans spec.json (lettres, chiffres, '_' et '-' uniquement) : ${bad_ids}" 2

  # Même raisonnement pour les doublons : un id dupliqué qui vaut la chaîne
  # vide se joint aussi en chaîne vide dès qu'il n'y en a qu'UN à rapporter
  # (le représentant de chaque groupe de doublons). Avec deux ids vides le
  # groupe entier est ["", ""] mais on ne rapporte QUE le premier représentant
  # de chaque groupe en doublon — donc UN SEUL élément vide dans le résultat,
  # qui se joint bien en chaîne vide et masquait le défaut identique.
  local dupes_result dupes_count dupes
  dupes_result=$(jq -c '
    [.services[].id] | group_by(.) | map(select(length > 1) | .[0])
    | map(if . == "" then "<vide>" else . end) as $dupes
    | {count: ($dupes | length), joined: ($dupes | join(", "))}
  ' "$SPEC_JSON")
  dupes_count=$(printf '%s' "$dupes_result" | jq -r '.count // 0' 2>/dev/null)
  dupes=$(printf '%s' "$dupes_result" | jq -r '.joined // ""' 2>/dev/null)
  [[ "${dupes_count:-0}" -gt 0 ]] \
    && die "ids de service dupliqués dans spec.json : ${dupes}" 2

  # `return 0` explicite : sans lui, la valeur de retour IMPLICITE de la
  # fonction est celle de la DERNIÈRE commande exécutée — ici un `[[ ... -gt
  # 0 ]]` qui vaut justement FAUX (statut 1) sur le chemin de succès. Piège
  # vérifié empiriquement (bash -x) en écrivant ce correctif : sans ce
  # `return 0`, spec_init sortait en 1 alors que la validation avait réussi.
  return 0
}

spec_service_ids() {
  jq -r '.services[].id' "$SPEC_JSON"
}

# spec_get SERVICE_ID CHAMP [DÉFAUT]
spec_get() {
  local sid="${1:?}" field="${2:?}" default="${3:-}"
  local value
  # Utiliser has() pour distinguer un champ absent (retour défaut) d'un champ
  # présent avec une valeur falsy (retour de la valeur). Cas spéciaux :
  # - champ absent → retour défaut
  # - champ = null → retour défaut (null signifie « pas de valeur »)
  # - champ = false → retour "false" (valeur explicite)
  # - champ = "" → retour "" (chaîne vide explicite, pas le défaut)
  value=$(jq -r --arg s "$sid" --arg f "$field" '
    (.services[] | select(.id == $s) |
    if has($f) then
      .[$f] | if . == null then "<<NULL>>"
              elif type == "boolean" or type == "number" then tostring
              else . end
    else
      "<<ABSENT>>"
    end) // "<<ABSENT>>"
  ' "$SPEC_JSON" 2>/dev/null || printf '<<ABSENT>>')
  if [[ "$value" == "<<ABSENT>>" ]] || [[ "$value" == "<<NULL>>" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$value"
  fi
}

spec_is_internal() {
  [[ "$(spec_get "${1:?}" internal)" == "true" ]]
}

spec_is_exposed() {
  local e
  e="$(spec_get "${1:?}" expose)"
  [[ -n "$e" ]]
}

# Ids exposés triés par longueur de chemin décroissante : le plus spécifique
# d'abord. Le jalon 4 en dépend (précédence des reverse proxies BunkerWeb) ;
# autant ne pas dépendre de l'ordre de déclaration dès maintenant.
spec_exposed_ids_by_path_length() {
  jq -r '
    [ .services[] | select((.expose // "") != "") ]
    | sort_by(-(.expose | length))
    | .[].id
  ' "$SPEC_JSON"
}
