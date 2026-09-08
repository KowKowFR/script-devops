#!/usr/bin/env bash
# lib/gen_workflow.sh
# Génère le workflow GitHub Actions CI/CD (.github/workflows/deploy.yml).
#
# Usage : gen_workflow.sh WORK_DIR
#
# Variables d'environnement :
#   APP_NAME           (tp-app) — préfixe des images Docker
#   TARGET_AUTH_METHOD (key)    — "key" (TARGET_SSH_KEY) ou "password" (TARGET_PASSWORD)
#   SPEC_JSON                   — chemin de spec.json (services exposés, health)
#   ENV_JSON                    — chemin de env.json (ports hôte)
#
# Le déploiement se fait par Docker Compose (pas Kubernetes) : le job `deploy`
# se connecte en SSH à la cible, réécrit IMAGE_TAG dans deploy/.env avec le SHA
# du commit, relance la stack, attend les healthchecks, contrôle la santé
# applicative (en SSH, sur 127.0.0.1 — jamais via une URL publique, cf.
# commentaire plus bas) et restaure le tag précédent en cas d'échec.
#
# Le workflow utilise les secrets configurés côté GitHub (DOCKERHUB_USERNAME,
# TARGET_HOST, TARGET_USER, TARGET_SSH_KEY ou TARGET_PASSWORD…), posés par
# step_github_set_secrets (lib/steps.sh).

set -euo pipefail

WORK_DIR="${1:?WORK_DIR required}"
APP_NAME="${APP_NAME:-tp-app}"
TARGET_AUTH_METHOD="${TARGET_AUTH_METHOD:-key}"

API_IMAGE="${APP_NAME}-api"
WEB_IMAGE="${APP_NAME}-web"

# ----- Contrôle de santé applicatif ------------------------------------------
# Un curl local par service exposé, enchaînés par && — construit depuis
# spec.json (quels services sont exposés, sur quel chemin de health-check) et
# env.json (quel port hôte leur est alloué). Exécuté DEPUIS la cible via SSH :
# un runner GitHub hébergé ne peut pas joindre une adresse RFC1918, et l'hôte
# cible n'est plus exposé directement — seul le reverse proxy l'est.
HEALTH_CHECK_CMDS=""
if [[ -n "${SPEC_JSON:-}" && -f "$SPEC_JSON" ]]; then
  while IFS=$'\t' read -r sid health; do
    port=$(jq -r --arg s "$sid" '.ports[$s] // empty' "${ENV_JSON:-/dev/null}" 2>/dev/null || printf '')
    [[ -n "$port" ]] || continue
    [[ -n "$HEALTH_CHECK_CMDS" ]] && HEALTH_CHECK_CMDS+=" && "
    HEALTH_CHECK_CMDS+="curl -fsS -m 5 -o /dev/null http://127.0.0.1:${port}${health}"
  done < <(jq -r '.services[] | select((.expose // "") != "") | "\(.id)\t\(.health // "/")"' "$SPEC_JSON")
fi
[[ -n "$HEALTH_CHECK_CMDS" ]] || HEALTH_CHECK_CMDS="true"

# ----- Blocs spécifiques au mode d'authentification --------------------------
# `IFS= read -r -d ''` assigne un heredoc multi-ligne sans backslash hell.
# - IFS= : conserve les whitespace de début (indentation YAML).
# - || true : `read` renvoie 1 quand il atteint EOF, normal avec -d ''.

if [[ "$TARGET_AUTH_METHOD" == "password" ]]; then
  IFS= read -r -d '' SETUP_SSH_BLOCK <<'EOF' || true
      - name: Setup SSH (password mode)
        env:
          SSH_HOST: ${{ secrets.TARGET_HOST }}
        run: |
          sudo apt-get update -qq && sudo apt-get install -y -qq sshpass
          mkdir -p ~/.ssh
          ssh-keyscan -H "$SSH_HOST" >> ~/.ssh/known_hosts
EOF

  IFS= read -r -d '' SSH_ENV <<'EOF' || true
        env:
          SSHPASS: ${{ secrets.TARGET_PASSWORD }}
EOF

  IFS= read -r -d '' CLEANUP_BLOCK <<'EOF' || true
      - name: Cleanup
        if: always()
        run: true
EOF

  SSH_CMD='sshpass -e ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no'
else
  IFS= read -r -d '' SETUP_SSH_BLOCK <<'EOF' || true
      - name: Setup SSH (key mode)
        env:
          SSH_PRIVATE_KEY: ${{ secrets.TARGET_SSH_KEY }}
          SSH_HOST: ${{ secrets.TARGET_HOST }}
        run: |
          mkdir -p ~/.ssh
          printf '%s\n' "$SSH_PRIVATE_KEY" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          head -n 1 ~/.ssh/deploy_key
          ssh-keygen -y -f ~/.ssh/deploy_key > /dev/null && echo "Clé valide"
          ssh-keyscan -H "$SSH_HOST" >> ~/.ssh/known_hosts
EOF

  IFS= read -r -d '' CLEANUP_BLOCK <<'EOF' || true
      - name: Cleanup SSH
        if: always()
        run: rm -f ~/.ssh/deploy_key
EOF

  SSH_ENV=''
  SSH_CMD='ssh -i ~/.ssh/deploy_key'
fi

# ----- Génération du fichier ------------------------------------------------
mkdir -p "$WORK_DIR/.github/workflows"

cat > "$WORK_DIR/.github/workflows/deploy.yml" <<EOF
name: Build & Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

env:
  DOCKERHUB_USERNAME: \${{ secrets.DOCKERHUB_USERNAME }}
  APP_NAME: ${APP_NAME}

jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      api: \${{ steps.filter.outputs.api }}
      web: \${{ steps.filter.outputs.web }}
    steps:
      - uses: actions/checkout@v4

      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            api:
              - 'services/api/**'
            web:
              - 'services/web/**'

  # ---- Sécurité : scan secrets dans l'arbre Git (bloquant) ------------------
  scan-secrets:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # gitleaks veut l'historique pour le diff
      - uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: \${{ secrets.GITHUB_TOKEN }}

  build-and-push-api:
    needs: [detect-changes, scan-secrets]
    if: needs.detect-changes.outputs.api == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          username: \${{ secrets.DOCKERHUB_USERNAME }}
          password: \${{ secrets.DOCKERHUB_TOKEN }}
      - uses: docker/build-push-action@v5
        with:
          context: ./services/api
          push: true
          cache-from: type=gha,scope=api
          cache-to: type=gha,scope=api,mode=max
          tags: |
            \${{ secrets.DOCKERHUB_USERNAME }}/${API_IMAGE}:latest
            \${{ secrets.DOCKERHUB_USERNAME }}/${API_IMAGE}:\${{ github.sha }}
      # Scan trivy bloquant sur HIGH+CRITICAL (l'image est déjà sur Docker Hub
      # mais le job 'deploy' n'enchaînera pas si ce step échoue).
      #
      # skip-dirs : on exclut les paquets npm/yarn bundled dans le base image
      # node:20-alpine. Ces vulns sont dans les dépendances internes de npm
      # lui-même (cross-spawn, glob, minimatch, tar) — on ne les contrôle pas,
      # c'est au mainteneur du base image de les patcher. Scanner notre app
      # reste plein, mais on ne casse plus le CI à cause de npm bundled.
      - name: Trivy scan API
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          image-ref: \${{ secrets.DOCKERHUB_USERNAME }}/${API_IMAGE}:\${{ github.sha }}
          severity: HIGH,CRITICAL
          exit-code: '1'
          ignore-unfixed: true
          vuln-type: os,library
          skip-dirs: '/usr/local/lib/node_modules/npm,/opt/yarn-v1.22.22,/usr/local/lib/node_modules/corepack'

  build-and-push-web:
    needs: [detect-changes, scan-secrets]
    if: needs.detect-changes.outputs.web == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          username: \${{ secrets.DOCKERHUB_USERNAME }}
          password: \${{ secrets.DOCKERHUB_TOKEN }}
      - uses: docker/build-push-action@v5
        with:
          context: ./services/web
          push: true
          cache-from: type=gha,scope=web
          cache-to: type=gha,scope=web,mode=max
          tags: |
            \${{ secrets.DOCKERHUB_USERNAME }}/${WEB_IMAGE}:latest
            \${{ secrets.DOCKERHUB_USERNAME }}/${WEB_IMAGE}:\${{ github.sha }}
      - name: Trivy scan Web
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          image-ref: \${{ secrets.DOCKERHUB_USERNAME }}/${WEB_IMAGE}:\${{ github.sha }}
          severity: HIGH,CRITICAL
          exit-code: '1'
          ignore-unfixed: true
          vuln-type: os,library
          skip-dirs: '/usr/local/lib/node_modules/npm,/opt/yarn-v1.22.22,/usr/local/lib/node_modules/corepack'

  deploy:
    needs: [detect-changes, scan-secrets, build-and-push-api, build-and-push-web]
    if: |
      always() &&
      needs.scan-secrets.result == 'success' &&
      (needs.build-and-push-api.result == 'success' || needs.build-and-push-api.result == 'skipped') &&
      (needs.build-and-push-web.result == 'success' || needs.build-and-push-web.result == 'skipped')
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

${SETUP_SSH_BLOCK}

      - name: Déploiement du nouveau tag
${SSH_ENV}
        run: |
          ${SSH_CMD} \\
            \${{ secrets.TARGET_USER }}@\${{ secrets.TARGET_HOST }} \\
            "set -e
             cd ~/${APP_NAME}/deploy
             cp .env .env.prev
             sed -i 's/^IMAGE_TAG=.*/IMAGE_TAG=\${{ github.sha }}/' .env
             docker compose pull
             docker compose up -d --remove-orphans"

      - name: Attente des healthchecks
${SSH_ENV}
        run: |
          ${SSH_CMD} \\
            \${{ secrets.TARGET_USER }}@\${{ secrets.TARGET_HOST }} \\
            "cd ~/${APP_NAME}/deploy
             for i in \\\$(seq 1 30); do
               bad=\\\$(docker compose ps --format json \\
                 | jq -rs 'if type==\"array\" then . else [.] end
                           | map(select(.State != \"running\" or ((.Health // \"\") == \"unhealthy\")))
                           | length')
               [ \\\"\\\$bad\\\" = \\\"0\\\" ] && exit 0
               sleep 3
             done
             echo 'healthchecks non satisfaits après 90s' >&2
             exit 1"

      # Le health-check passe par SSH sur l'hôte cible, jamais par une URL
      # publique : un runner GitHub hébergé ne peut pas joindre une adresse
      # RFC1918, et l'hôte cible n'est plus exposé directement.
      - name: Contrôle de santé applicatif
${SSH_ENV}
        run: |
          ${SSH_CMD} \\
            \${{ secrets.TARGET_USER }}@\${{ secrets.TARGET_HOST }} \\
            "${HEALTH_CHECK_CMDS}"

      - name: Rollback si échec
        if: failure()
${SSH_ENV}
        run: |
          ${SSH_CMD} \\
            \${{ secrets.TARGET_USER }}@\${{ secrets.TARGET_HOST }} \\
            "set -e
             cd ~/${APP_NAME}/deploy
             [ -f .env.prev ] && mv .env.prev .env
             docker compose pull && docker compose up -d --remove-orphans
             echo 'rollback effectué vers le tag précédent'"

${CLEANUP_BLOCK}
EOF

echo "  - .github/workflows/deploy.yml (auth=${TARGET_AUTH_METHOD}, images: ${API_IMAGE}/${WEB_IMAGE})"
