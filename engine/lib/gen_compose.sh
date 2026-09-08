#!/usr/bin/env bash
# engine/lib/gen_compose.sh — génère deploy/compose.yml depuis spec.json.
#
# Remplace lib/gen_manifests.sh (Kubernetes). Sourcé par lib/steps.sh, pas
# exécuté en sous-processus : il a besoin des helpers cfg_*/spec_*.
#
# Produit dans $WORK_DIR :
#   deploy/compose.yml     la stack
#   deploy/.env            IMAGE_TAG=latest  (réécrit par le CI avec le SHA)
#   deploy/.env.example    committable
#
# DEUX SQUELETTES, PAS UN
#   - service buildé (clé "build") : durcissement complet, il porte notre code.
#   - service sur image tierce interne (clé "image" + internal) : durcissement
#     partiel. Forcer user 1000 et read_only sur postgres:16-alpine l'empêche
#     de démarrer — il tourne en uid 70 et doit posséder son datadir.
#
# ATTENTION AUX HEREDOCS : ${IMAGE_TAG} doit arriver littéral dans le YAML,
# c'est Compose qui l'interpole depuis deploy/.env. D'où les \${…}.
#
# INJECTION YAML (jalon 5 : spec.json sera généré par un LLM à partir d'un
# prompt utilisateur — le contenu de spec.json n'est PAS de confiance)
#   `jq --arg` protège contre l'exécution shell, pas contre la corruption de
#   structure YAML : une valeur `env`/`volumes` contenant un retour à la ligne
#   suivi de "  privileged: true" devient, une fois interpolée telle quelle
#   dans une chaîne YAML construite à la main, une VRAIE clé de service que
#   Compose résout. Toute valeur issue du spec qui atterrit dans le YAML passe
#   donc par _yaml_str : une chaîne JSON (`tojson`) est un scalaire YAML
#   double-quoté valide, guillemets/antislashs échappés et retours à la ligne
#   réifiés en \n — aucun caractère ne peut faire déborder la valeur hors de
#   sa position. Défense en profondeur complémentaire : spec_init (config.sh)
#   rejette tout id de service hors [A-Za-z0-9_-], donc l'id lui-même — qui
#   sert de clé de mapping YAML brute — ne peut pas non plus servir de vecteur.
#
# ÉCRITURE ATOMIQUE
#   Le contenu de compose.yml part sur le descripteur 3, jamais sur stdout
#   (fd 1) : si une fonction appelée en cours de génération meurt (die), son
#   message d'échec JSON doit atteindre le VRAI stdout du process, pas être
#   avalé par le fichier compose.yml en cours d'écriture (qui, avant ce
#   correctif, était construit via `{ ... } > compose.yml`, un bloc qui
#   redirige fd 1 pour toute sa durée). Le fichier temporaire n'est renommé en
#   compose.yml qu'une fois la génération intégralement réussie : un die() en
#   cours de boucle laisse l'ancien compose.yml intact (ou aucun fichier, s'il
#   n'existait pas), jamais une version tronquée. Même traitement pour .env et
#   .env.example. En complément, tout ce qui peut mourir fatalement (build/
#   image absents, port hôte manquant) est vérifié dans une PASSE DE
#   PRÉ-VALIDATION avant même de créer le fichier temporaire : à l'usage
#   normal, aucun die() ne devrait donc jamais survenir une fois le fichier
#   temporaire ouvert, et aucun résidu ne peut apparaître sur disque.
#
#   Piège bash vérifié empiriquement : `cfg_port`/`cfg_req` sont appelées via
#   une substitution de commande (`x="$(cfg_port ...)"`) pour récupérer leur
#   valeur — une substitution de commande tourne dans un SOUS-SHELL. Un die()
#   interne y appelle bien `exit`, mais ça ne termine QUE ce sous-shell : le
#   process appelant continue, et le JSON que `die` a imprimé est resté piégé
#   dans la variable de capture, jamais sur le vrai stdout. D'où `_capture` :
#   elle relaie explicitement ce texte capturé sur le vrai stdout avant de
#   quitter avec le bon code, sans dépendre de `set -e` chez l'appelant (les
#   tests ne l'activent pas).

# _yaml_str VALEUR — encode n'importe quelle chaîne en scalaire YAML sûr.
# Le mode de sortie par défaut de jq (sans -r) encode déjà une chaîne comme
# du JSON — guillemets et antislashs échappés, retours à la ligne réifiés en
# \n — et une chaîne JSON EST un scalaire YAML "double-quoted" valide : c'est
# la défense contre l'injection décrite en tête de fichier. (Piège vérifié :
# `'$v | tojson'` ici double-encoderait, puisque `$v` seul est déjà la
# représentation JSON — tojson sert à insérer cette représentation À
# L'INTÉRIEUR d'une autre chaîne construite avec -r, pas en sortie directe.)
_yaml_str() {
  jq -n --arg v "${1-}" '$v'
}

# _capture VARNAME CMD... — équivalent de VARNAME="$(CMD...)" mais qui reste
# correct quand CMD peut appeler `die` : voir le paragraphe "ÉCRITURE
# ATOMIQUE" en tête de fichier pour le pourquoi.
_capture() {
  local __var="$1"; shift
  local __out __rc=0
  __out="$("$@")" || __rc=$?
  if [[ "$__rc" -ne 0 ]]; then
    [[ -n "$__out" ]] && printf '%s\n' "$__out"
    _RESULT_EMITTED=1
    exit "$__rc"
  fi
  printf -v "$__var" '%s' "$__out"
}

# _gen_compose_validate_service ID — vérifie ce qui, pour ce service, peut
# faire mourir la génération (ni build ni image ; port hôte manquant pour un
# service exposé), AVANT que quoi que ce soit ne soit écrit sur disque.
_gen_compose_validate_service() {
  local sid="$1"
  local image build
  image="$(spec_get "$sid" image)"
  build="$(spec_get "$sid" build)"
  [[ -n "$build" || -n "$image" ]] \
    || die "service '${sid}' : ni 'build' ni 'image' dans spec.json" 2
  if spec_is_exposed "$sid"; then
    local _unused
    _capture _unused cfg_port "$sid"
  fi
}

gen_compose() {
  spec_init

  local deploy_dir="${WORK_DIR}/deploy"
  mkdir -p "$deploy_dir"

  local registry_user bind_addr cpu_raw mem_raw
  _capture registry_user cfg_req registry.user
  bind_addr="$(cfg target.bind_addr 0.0.0.0)"
  cpu_raw="$(cfg limits.cpu 200m)"
  mem_raw="$(cfg limits.memory 128Mi)"

  local cpu mem
  cpu="$(k8s_cpu_to_docker "$cpu_raw")" || die "limite CPU invalide : ${cpu_raw}" 2
  mem="$(k8s_mem_to_docker "$mem_raw")" || die "limite mémoire invalide : ${mem_raw}" 2

  local net_name="${APP_NAME}-net"

  # Pré-validation (cf. en-tête) : tout se joue ici avant la moindre écriture.
  local sid
  while IFS= read -r sid; do
    [[ -n "$sid" ]] || continue
    _gen_compose_validate_service "$sid"
  done < <(spec_service_ids)

  # Restes d'une génération précédemment interrompue (crash, kill -9…) :
  # nettoyés avant d'en écrire une nouvelle. Les fichiers définitifs, eux, ne
  # sont jamais touchés tant que la génération n'a pas intégralement réussi.
  rm -f "${deploy_dir}"/.compose.yml.?????? \
        "${deploy_dir}"/.env.?????? \
        "${deploy_dir}"/.env.example.?????? 2>/dev/null || true

  # --- compose.yml : génération sur fd 3, renommage atomique ---------------
  local tmp_compose
  tmp_compose="$(mktemp "${deploy_dir}/.compose.yml.XXXXXX")" \
    || die "compose.yml : échec de création du fichier temporaire" 2
  exec 3>"$tmp_compose"

  printf 'services:\n' >&3

  while IFS= read -r sid; do
    [[ -n "$sid" ]] || continue
    _gen_compose_service "$sid" "$registry_user" "$bind_addr" "$cpu" "$mem"
  done < <(spec_service_ids)

  _gen_compose_volumes
  printf '\nnetworks:\n  %s:\n    driver: bridge\n' "$net_name" >&3

  exec 3>&-
  mv -f "$tmp_compose" "${deploy_dir}/compose.yml"

  # --- deploy/.env : IMAGE_TAG=latest, écriture atomique --------------------
  local tmp_env
  tmp_env="$(mktemp "${deploy_dir}/.env.XXXXXX")" \
    || die "deploy/.env : échec de création du fichier temporaire" 2
  printf 'IMAGE_TAG=latest\n' > "$tmp_env"
  chmod 600 "$tmp_env"
  mv -f "$tmp_env" "${deploy_dir}/.env"

  # --- deploy/.env.example : committable, écriture atomique -----------------
  local tmp_env_example
  tmp_env_example="$(mktemp "${deploy_dir}/.env.example.XXXXXX")" \
    || die "deploy/.env.example : échec de création du fichier temporaire" 2
  cat > "$tmp_env_example" <<'EOF'
# Tag des images déployées. Le workflow CI réécrit cette ligne avec le SHA du
# commit ; y remettre un ancien SHA puis relancer `docker compose up -d` est le
# mécanisme de rollback.
IMAGE_TAG=latest
EOF
  mv -f "$tmp_env_example" "${deploy_dir}/.env.example"

  ui_ok "deploy/compose.yml généré ($(spec_service_ids | wc -l | tr -d ' ') services)"
}

# _gen_compose_service ID REGISTRY_USER BIND_ADDR CPU MEM
# Écrit sur le descripteur 3 (jamais stdout, cf. en-tête du fichier).
_gen_compose_service() {
  local sid="$1" registry_user="$2" bind_addr="$3" cpu="$4" mem="$5"
  local net_name="${APP_NAME}-net"

  local image build port health
  image="$(spec_get "$sid" image)"
  build="$(spec_get "$sid" build)"
  port="$(spec_get "$sid" port)"
  health="$(spec_get "$sid" health)"

  # sid : protégé en amont par spec_init (regex [A-Za-z0-9_-]+), donc sûr en
  # tant que clé YAML brute.
  printf '  %s:\n' "$sid" >&3

  if [[ -n "$build" ]]; then
    # Service buildé : image publiée sur le registre, tag piloté par .env.
    # ${IMAGE_TAG} doit rester littéral (Compose l'interpole depuis .env) —
    # échappé ici en \${IMAGE_TAG} dans la chaîne double-quotée bash, donc
    # jamais vu par le shell comme une expansion.
    printf '    image: %s\n' \
      "$(_yaml_str "${registry_user}/${APP_NAME}-${sid}:\${IMAGE_TAG}")" >&3
    printf '    build:\n      context: %s\n' \
      "$(_yaml_str "../${build#./}")" >&3
  else
    [[ -n "$image" ]] || die "service '${sid}' : ni 'build' ni 'image' dans spec.json" 2
    printf '    image: %s\n' "$(_yaml_str "$image")" >&3
  fi

  printf '    restart: unless-stopped\n' >&3
  printf '    networks: [ %s ]\n' "$net_name" >&3

  # Variables d'environnement du spec, plus PORT pour les services buildés.
  # Clé ET valeur passent par tojson côté jq : aucune des deux n'est jamais
  # interpolée telle quelle dans une chaîne YAML construite à la main.
  local envs
  envs=$(jq -r --arg s "$sid" '
    .services[] | select(.id == $s) | (.env // {}) | to_entries[]
    | "      " + (.key | tojson) + ": " + (.value | tojson)
  ' "$SPEC_JSON")
  if [[ -n "$envs" || -n "$build" ]]; then
    printf '    environment:\n' >&3
    [[ -n "$build" && -n "$port" ]] && printf '      PORT: %s\n' "$(_yaml_str "$port")" >&3
    [[ -n "$envs" ]] && printf '%s\n' "$envs" >&3
  fi

  # Publication de port : seulement pour les services exposés. La ligne
  # entière (bind:host:conteneur) est encodée d'un bloc, donc sûre quel que
  # soit le contenu de $port (hôte déjà validé numérique par cfg_port).
  if spec_is_exposed "$sid"; then
    local host_port
    # Déjà validé par _gen_compose_validate_service avant l'ouverture du
    # fichier temporaire ; _capture reste la voie sûre si ce n'était pas le
    # cas (cf. "ÉCRITURE ATOMIQUE" en tête de fichier).
    _capture host_port cfg_port "$sid"
    printf '    ports: [ %s ]\n' "$(_yaml_str "${bind_addr}:${host_port}:${port}")" >&3
  fi

  # Volumes déclarés dans le spec. C'est le vecteur du PoC de la revue : une
  # entrée comme "normal:/data\n    privileged: true" doit rester une SEULE
  # chaîne littérale, jamais devenir une clé de service. tojson garantit ça.
  local vols
  vols=$(jq -r --arg s "$sid" '
    .services[] | select(.id == $s) | (.volumes // [])[] | "      - " + (. | tojson)
  ' "$SPEC_JSON")
  [[ -n "$vols" ]] && { printf '    volumes:\n' >&3; printf '%s\n' "$vols" >&3; }

  # Durcissement : complet pour nos images, partiel pour les images tierces.
  if [[ -n "$build" ]]; then
    printf '    user: "1000:1000"\n' >&3
    printf '    read_only: true\n' >&3
    printf '    tmpfs:\n      - /tmp\n      - /var/run\n      - /var/cache/nginx\n' >&3
    printf '    cap_drop: [ ALL ]\n' >&3
    printf '    security_opt: [ "no-new-privileges:true" ]\n' >&3
  else
    printf '    security_opt: [ "no-new-privileges:true" ]\n' >&3
  fi

  # Healthcheck : HTTP pour un service buildé qui déclare un chemin de santé,
  # sinon rien (une image tierce apporte souvent le sien). La commande entière
  # est composée puis encodée d'un bloc : un $health contenant un guillemet ne
  # peut plus faire déborder la valeur hors du tableau CMD-SHELL.
  if [[ -n "$build" && -n "$health" && -n "$port" ]]; then
    local hc_cmd="wget -qO- http://127.0.0.1:${port}${health} || exit 1"
    printf '    healthcheck:\n' >&3
    printf '      test: ["CMD-SHELL", %s]\n' "$(_yaml_str "$hc_cmd")" >&3
    printf '      interval: 10s\n      timeout: 3s\n      retries: 5\n      start_period: 5s\n' >&3
  fi

  printf '    deploy:\n      resources:\n        limits:\n' >&3
  printf '          cpus: "%s"\n          memory: %s\n' "$cpu" "$mem" >&3

  printf '    logging:\n      driver: json-file\n' >&3
  printf '      options:\n        max-size: "10m"\n        max-file: "3"\n' >&3
}

# Déclare au niveau racine les volumes nommés référencés par les services.
# Écrit sur le descripteur 3 (jamais stdout, cf. en-tête du fichier).
_gen_compose_volumes() {
  local names
  # Le nom extrait (avant le premier ':') est borné par construction au jeu de
  # caractères testé par la regex — aucun ':', guillemet ni retour à la ligne
  # ne peut s'y trouver, donc sûr comme clé YAML brute même sans _yaml_str.
  names=$(jq -r '
    [ .services[]? | (.volumes // [])[] ]
    | map(select(test("^[A-Za-z0-9_][A-Za-z0-9._-]*:")))
    | map(split(":")[0]) | unique | .[]
  ' "$SPEC_JSON")
  [[ -n "$names" ]] || return 0
  printf '\nvolumes:\n' >&3
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    printf '  %s:\n' "$n" >&3
  done <<< "$names"
}
