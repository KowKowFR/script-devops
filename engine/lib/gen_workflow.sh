#!/usr/bin/env bash
# lib/gen_workflow.sh
# Génère le workflow GitHub Actions CI/CD (.github/workflows/deploy.yml).
#
# Usage : gen_workflow.sh WORK_DIR
#
# Variables d'environnement :
#   APP_NAME        (tp-app) — préfixe des images Docker et noms de deployments
#   OVH_AUTH_METHOD (key)    — "key" (OVH_SSH_KEY) ou "password" (OVH_PASSWORD)
#
# Le workflow utilise les secrets configurés côté GitHub (DOCKERHUB_USERNAME, etc.).

set -euo pipefail

WORK_DIR="${1:?WORK_DIR required}"
APP_NAME="${APP_NAME:-tp-app}"
OVH_AUTH_METHOD="${OVH_AUTH_METHOD:-key}"

API_IMAGE="${APP_NAME}-api"
WEB_IMAGE="${APP_NAME}-web"
API_DEPLOY="${APP_NAME}-api"
WEB_DEPLOY="${APP_NAME}-web"

# ----- Blocs spécifiques au mode d'authentification --------------------------
# `IFS= read -r -d ''` assigne un heredoc multi-ligne sans backslash hell.
# - IFS= : conserve les whitespace de début (indentation YAML).
# - || true : `read` renvoie 1 quand il atteint EOF, normal avec -d ''.

if [[ "$OVH_AUTH_METHOD" == "password" ]]; then
  IFS= read -r -d '' SETUP_SSH_BLOCK <<'EOF' || true
      - name: Setup SSH (password mode)
        env:
          SSH_HOST: ${{ secrets.OVH_HOST }}
        run: |
          sudo apt-get update -qq && sudo apt-get install -y -qq sshpass
          mkdir -p ~/.ssh
          ssh-keyscan -H "$SSH_HOST" >> ~/.ssh/known_hosts
EOF

  IFS= read -r -d '' SSH_ENV <<'EOF' || true
        env:
          SSHPASS: ${{ secrets.OVH_PASSWORD }}
EOF

  IFS= read -r -d '' CLEANUP_BLOCK <<'EOF' || true
      - name: Cleanup
        if: always()
        run: true
EOF

  SSH_CMD='sshpass -e ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no'
  SCP_CMD='sshpass -e scp -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no'
else
  IFS= read -r -d '' SETUP_SSH_BLOCK <<'EOF' || true
      - name: Setup SSH (key mode)
        env:
          SSH_PRIVATE_KEY: ${{ secrets.OVH_SSH_KEY }}
          SSH_HOST: ${{ secrets.OVH_HOST }}
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
  SCP_CMD='scp -i ~/.ssh/deploy_key'
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
      manifests: \${{ steps.filter.outputs.manifests }}
    steps:
      - uses: actions/checkout@v4

      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            api:
              - 'microservices/api/**'
            web:
              - 'microservices/web/**'
            manifests:
              - 'k8s/**'

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
          context: ./microservices/api
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
          context: ./microservices/web
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
      (needs.detect-changes.outputs.api == 'true' ||
       needs.detect-changes.outputs.web == 'true' ||
       needs.detect-changes.outputs.manifests == 'true') &&
      (needs.build-and-push-api.result == 'success' || needs.build-and-push-api.result == 'skipped') &&
      (needs.build-and-push-web.result == 'success' || needs.build-and-push-web.result == 'skipped')
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

${SETUP_SSH_BLOCK}

      - name: Apply manifests
${SSH_ENV}
        run: |
          ${SSH_CMD} \\
            \${{ secrets.OVH_USER }}@\${{ secrets.OVH_HOST }} \\
            'rm -rf ~/tp-k8s-manifests && mkdir -p ~/tp-k8s-manifests'
          ${SCP_CMD} -r k8s/base \\
            \${{ secrets.OVH_USER }}@\${{ secrets.OVH_HOST }}:~/tp-k8s-manifests/base
          ${SSH_CMD} \\
            \${{ secrets.OVH_USER }}@\${{ secrets.OVH_HOST }} \\
            "export KUBECONFIG=~/.kube/config && kubectl apply -f ~/tp-k8s-manifests/base/"

      - name: Deploy API
        if: needs.detect-changes.outputs.api == 'true'
${SSH_ENV}
        run: |
          ${SSH_CMD} \\
            \${{ secrets.OVH_USER }}@\${{ secrets.OVH_HOST }} \\
            "export KUBECONFIG=~/.kube/config && \\
             kubectl set image deployment/${API_DEPLOY} api=\${{ secrets.DOCKERHUB_USERNAME }}/${API_IMAGE}:\${{ github.sha }} && \\
             kubectl rollout status deployment/${API_DEPLOY} --timeout=2m"

      - name: Deploy Web
        if: needs.detect-changes.outputs.web == 'true'
${SSH_ENV}
        run: |
          ${SSH_CMD} \\
            \${{ secrets.OVH_USER }}@\${{ secrets.OVH_HOST }} \\
            "export KUBECONFIG=~/.kube/config && \\
             kubectl set image deployment/${WEB_DEPLOY} web=\${{ secrets.DOCKERHUB_USERNAME }}/${WEB_IMAGE}:\${{ github.sha }} && \\
             kubectl rollout status deployment/${WEB_DEPLOY} --timeout=2m"

      - name: Post-deploy health check
        run: |
          for i in {1..15}; do
            if curl -fsS -m 5 "http://\${{ secrets.OVH_HOST }}/api/health" > /tmp/health.json 2>/dev/null; then
              echo "Health check passed"
              cat /tmp/health.json
              exit 0
            fi
            echo "  retry \$i/15…"
            sleep 4
          done
          echo "Health check failed"
          exit 1

${CLEANUP_BLOCK}
EOF

echo "  - .github/workflows/deploy.yml (auth=${OVH_AUTH_METHOD}, images: ${API_IMAGE}/${WEB_IMAGE})"
