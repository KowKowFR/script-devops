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

gen_compose() {
  spec_init

  local deploy_dir="${WORK_DIR}/deploy"
  mkdir -p "$deploy_dir"

  local registry_user; registry_user="$(cfg_req registry.user)"
  local bind_addr;     bind_addr="$(cfg target.bind_addr 0.0.0.0)"
  local cpu_raw;       cpu_raw="$(cfg limits.cpu 200m)"
  local mem_raw;       mem_raw="$(cfg limits.memory 128Mi)"

  local cpu mem
  cpu="$(k8s_cpu_to_docker "$cpu_raw")" || die "limite CPU invalide : ${cpu_raw}" 2
  mem="$(k8s_mem_to_docker "$mem_raw")" || die "limite mémoire invalide : ${mem_raw}" 2

  local net_name="${APP_NAME}-net"

  {
    printf 'services:\n'

    local sid
    for sid in $(spec_service_ids); do
      _gen_compose_service "$sid" "$registry_user" "$bind_addr" "$cpu" "$mem"
    done

    _gen_compose_volumes
    printf '\nnetworks:\n  %s:\n    driver: bridge\n' "$net_name"
  } > "${deploy_dir}/compose.yml"

  printf 'IMAGE_TAG=latest\n' > "${deploy_dir}/.env"
  chmod 600 "${deploy_dir}/.env"

  cat > "${deploy_dir}/.env.example" <<'EOF'
# Tag des images déployées. Le workflow CI réécrit cette ligne avec le SHA du
# commit ; y remettre un ancien SHA puis relancer `docker compose up -d` est le
# mécanisme de rollback.
IMAGE_TAG=latest
EOF

  ui_ok "deploy/compose.yml généré ($(spec_service_ids | wc -l | tr -d ' ') services)"
}

# _gen_compose_service ID REGISTRY_USER BIND_ADDR CPU MEM
_gen_compose_service() {
  local sid="$1" registry_user="$2" bind_addr="$3" cpu="$4" mem="$5"
  local net_name="${APP_NAME}-net"

  local image build port health
  image="$(spec_get "$sid" image)"
  build="$(spec_get "$sid" build)"
  port="$(spec_get "$sid" port)"
  health="$(spec_get "$sid" health)"

  printf '  %s:\n' "$sid"

  if [[ -n "$build" ]]; then
    # Service buildé : image publiée sur le registre, tag piloté par .env.
    printf '    image: %s/%s-%s:${IMAGE_TAG}\n' "$registry_user" "$APP_NAME" "$sid"
    printf '    build:\n      context: ../%s\n' "${build#./}"
  else
    [[ -n "$image" ]] || die "service '${sid}' : ni 'build' ni 'image' dans spec.json" 2
    printf '    image: %s\n' "$image"
  fi

  printf '    restart: unless-stopped\n'
  printf '    networks: [ %s ]\n' "$net_name"

  # Variables d'environnement du spec, plus PORT pour les services buildés.
  local envs
  envs=$(jq -r --arg s "$sid" '
    .services[] | select(.id == $s) | (.env // {}) | to_entries[]
    | "      \(.key): \"\(.value)\""
  ' "$SPEC_JSON")
  if [[ -n "$envs" || -n "$build" ]]; then
    printf '    environment:\n'
    [[ -n "$build" && -n "$port" ]] && printf '      PORT: "%s"\n' "$port"
    [[ -n "$envs" ]] && printf '%s\n' "$envs"
  fi

  # Publication de port : seulement pour les services exposés.
  if spec_is_exposed "$sid"; then
    local host_port; host_port="$(cfg_port "$sid")"
    printf '    ports: [ "%s:%s:%s" ]\n' "$bind_addr" "$host_port" "$port"
  fi

  # Volumes déclarés dans le spec.
  local vols
  vols=$(jq -r --arg s "$sid" '
    .services[] | select(.id == $s) | (.volumes // [])[] | "      - \(.)"
  ' "$SPEC_JSON")
  [[ -n "$vols" ]] && { printf '    volumes:\n'; printf '%s\n' "$vols"; }

  # Durcissement : complet pour nos images, partiel pour les images tierces.
  if [[ -n "$build" ]]; then
    printf '    user: "1000:1000"\n'
    printf '    read_only: true\n'
    printf '    tmpfs:\n      - /tmp\n      - /var/run\n      - /var/cache/nginx\n'
    printf '    cap_drop: [ ALL ]\n'
    printf '    security_opt: [ "no-new-privileges:true" ]\n'
  else
    printf '    security_opt: [ "no-new-privileges:true" ]\n'
  fi

  # Healthcheck : HTTP pour un service buildé qui déclare un chemin de santé,
  # sinon rien (une image tierce apporte souvent le sien).
  if [[ -n "$build" && -n "$health" && -n "$port" ]]; then
    printf '    healthcheck:\n'
    printf '      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:%s%s || exit 1"]\n' "$port" "$health"
    printf '      interval: 10s\n      timeout: 3s\n      retries: 5\n      start_period: 5s\n'
  fi

  printf '    deploy:\n      resources:\n        limits:\n'
  printf '          cpus: "%s"\n          memory: %s\n' "$cpu" "$mem"

  printf '    logging:\n      driver: json-file\n'
  printf '      options:\n        max-size: "10m"\n        max-file: "3"\n'
}

# Déclare au niveau racine les volumes nommés référencés par les services.
_gen_compose_volumes() {
  local names
  names=$(jq -r '
    [ .services[]? | (.volumes // [])[] ]
    | map(select(test("^[A-Za-z0-9_][A-Za-z0-9._-]*:")))
    | map(split(":")[0]) | unique | .[]
  ' "$SPEC_JSON")
  [[ -n "$names" ]] || return 0
  printf '\nvolumes:\n'
  local n
  for n in $names; do
    printf '  %s:\n' "$n"
  done
}
