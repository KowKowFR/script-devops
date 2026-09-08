#!/usr/bin/env bash
# engine/tools/migrate-env.sh — convertit un ancien .bootstrap-env en env.json.
#
# Usage : engine/tools/migrate-env.sh ANCIEN_FICHIER NOUVEAU_ENV_JSON
#
# L'ancien fichier est du shell (VAR="valeur"). On ne le `source` PAS — c'est
# précisément ce qu'on cherche à éliminer. On le parse ligne par ligne avec une
# expression régulière, et on désérialise les échappements \" et \\ à la main.

set -euo pipefail

SRC="${1:?usage: migrate-env.sh ANCIEN_FICHIER NOUVEAU_ENV_JSON}"
DST="${2:?usage: migrate-env.sh ANCIEN_FICHIER NOUVEAU_ENV_JSON}"

[[ -f "$SRC" ]] || { echo "Fichier source introuvable : $SRC" >&2; exit 2; }

# Extraction en paires clé/valeur, sans évaluation.
tmp_kv=$(mktemp)
trap 'rm -f "$tmp_kv"' EXIT

while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=\"(.*)\"$ ]] || continue
  key="${BASH_REMATCH[1]}"
  val="${BASH_REMATCH[2]}"
  val="${val//\\\"/\"}"
  val="${val//\\\\/\\}"
  printf '%s\t%s\n' "$key" "$val" >> "$tmp_kv"
done < "$SRC"

get() { awk -F'\t' -v k="$1" '$1 == k { sub(/^[^\t]*\t/, ""); print; exit }' "$tmp_kv"; }

# Les anciens APP_PORT / API_PORT étaient des ports CONTENEUR. Ils deviennent
# des ports HÔTE par défaut, avec un plancher à 1024 puisque les conteneurs
# tournent désormais en utilisateur non privilégié.
host_port() {
  local p="$1" fallback="$2"
  if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1024 )); then printf '%s' "$p"; else printf '%s' "$fallback"; fi
}

mkdir -p "$(dirname "$DST")"
jq -n \
  --arg app_name    "$(get APP_NAME)" \
  --arg app_author  "$(get APP_AUTHOR)" \
  --arg host        "$(get OVH_HOST)" \
  --arg user        "$(get OVH_USER)" \
  --arg auth        "$(get OVH_AUTH_METHOD)" \
  --arg key_path    "$(get OVH_SSH_KEY_PATH)" \
  --arg password    "$(get OVH_PASSWORD)" \
  --arg reg_user    "$(get DOCKERHUB_USER)" \
  --arg reg_token   "$(get DOCKERHUB_TOKEN)" \
  --arg gh_user     "$(get GITHUB_USER)" \
  --arg gh_repo     "$(get GITHUB_REPO_NAME)" \
  --arg cpu         "$(get CPU_LIMIT_API)" \
  --arg mem         "$(get MEM_LIMIT_API)" \
  --argjson port_api "$(host_port "$(get API_PORT)" 10001)" \
  --argjson port_web "$(host_port "$(get APP_PORT)" 10002)" \
  '{
    app:      { name: (.x // $app_name), author: $app_author },
    target:   { host: $host, user: $user,
                auth_method: (if $auth == "" then "key" else $auth end),
                ssh_key_path: $key_path, password: $password,
                bind_addr: "0.0.0.0" },
    registry: { user: $reg_user, token: $reg_token },
    github:   { enabled: ($gh_user != "" and $gh_repo != ""),
                user: $gh_user, repo: $gh_repo, token: "" },
    ports:    { api: $port_api, web: $port_web },
    limits:   { cpu: (if $cpu == "" then "200m" else $cpu end),
                memory: (if $mem == "" then "128Mi" else $mem end) },
    options:  { reuse_existing_dir: true, allow_existing_repo: true }
  } | .app.name = $app_name' > "$DST"

chmod 600 "$DST"

echo "✓ Migré : $SRC → $DST" >&2
echo "  ⚠ github.token est vide : le renseigner à la main (l'ancien format ne le" >&2
echo "    stockait pas, l'authentification passait par 'gh auth login')." >&2
echo "  ⚠ Les ports ont été promus en ports HÔTE. Vérifier qu'ils sont libres" >&2
echo "    sur la cible et ≥ 1024." >&2

# Régression fonctionnelle assumée : Compose ne répartit pas la charge entre
# plusieurs répliques derrière un port hôte publié. Le champ disparaît du
# modèle, mais on ne le laisse pas tomber en silence.
for k in REPLICAS_API REPLICAS_WEB; do
  v="$(get "$k")"
  if [ -n "$v" ] && [ "$v" != "1" ]; then
    echo "  ⚠ ${k}=${v} est ignoré : une seule réplique par service désormais." >&2
    echo "    Compose ne load-balance pas plusieurs répliques derrière un port" >&2
    echo "    hôte publié. Le scaling horizontal est hors périmètre." >&2
  fi
done
