#!/usr/bin/env bash
# lib/gen_workflow.sh
# Génère le workflow GitHub Actions CI/CD (.github/workflows/deploy.yml).
#
# Usage : gen_workflow.sh WORK_DIR
#
# Variables d'environnement :
#   APP_NAME           (tp-app) — préfixe des images Docker, nom de projet compose
#   TARGET_AUTH_METHOD (key)    — "key" (TARGET_SSH_KEY) ou "password" (TARGET_PASSWORD)
#   SPEC_JSON                   — chemin de spec.json (services exposés, health)
#   ENV_JSON                    — chemin de env.json (ports hôte)
#
# MÉCANISME DE DÉPLOIEMENT (revue round 2 : le job `deploy` faisait un `cd
# ~/${APP_NAME}/deploy` sur la cible, où rien n'a jamais copié `deploy/` —
# échec garanti). Le CI adopte désormais EXACTEMENT le mécanisme du panel
# (cf. `compose_remote`/`docker_remote`, lib/ssh_remote.sh, « un seul chemin
# de code, aucune exception ») : `DOCKER_HOST=ssh://user@host`, en lisant
# `deploy/compose.yml` depuis son propre clone fraîchement checkouté — pas un
# 2e mécanisme (scp, cd distant…) à côté de celui du panel.
#
#   - `deploy/.env` est gitignoré par step_git_init (le tag déployé est un
#     état de la CIBLE, pas du dépôt) : le CI le CRÉE lui-même, localement
#     sur le runner, avec IMAGE_TAG=<sha du commit>.
#   - Le tag actuellement déployé est capturé AVANT toute réécriture en
#     interrogeant le démon distant (`docker ps --filter
#     label=com.docker.compose.project=…`) — pas un `.env.prev` posé sur la
#     cible, qui n'existerait de toute façon pas avec ce mécanisme.
#   - Le contrôle de santé applicatif reste un SSH direct (pas DOCKER_HOST) :
#     c'est un `curl` sur 127.0.0.1, qui n'a de sens que dans l'espace
#     réseau de la cible — Docker ne tunnelle que son propre protocole API,
#     pas des commandes shell arbitraires. Voir aussi commentaire plus bas.
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

# Commande compose de référence, utilisée par toutes les étapes du job
# deploy qui pilotent la stack (elles tournent sur le runner, via
# DOCKER_HOST=ssh:// — le fichier compose.yml, lui, est LOCAL au runner,
# fraîchement checkouté).
COMPOSE_CMD="docker compose -f deploy/compose.yml --project-name ${APP_NAME} --env-file deploy/.env"

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
#
# Les DEUX modes doivent maintenant faire fonctionner DOCKER_HOST=ssh://, qui
# invoque en interne le binaire `ssh` du PATH (Docker n'a pas d'option -i ni
# de support de mot de passe intégré à son transport ssh://) :
#   - mode clé   : ~/.ssh/config déclare l'identité, ssh la trouve seul.
#   - mode mdp   : un wrapper `ssh` prioritaire dans le PATH route tout appel
#     (direct ou via DOCKER_HOST) par `sshpass -e <vrai ssh> …` — le mot de
#     passe reste dans SSHPASS, jamais sur une ligne de commande. Le wrapper
#     résout le VRAI binaire ssh AVANT de se poser en tête de PATH, pour ne
#     jamais s'appeler lui-même en boucle.

if [[ "$TARGET_AUTH_METHOD" == "password" ]]; then
  IFS= read -r -d '' SETUP_SSH_BLOCK <<'EOF' || true
      - name: Setup SSH (password mode)
        env:
          SSH_HOST: ${{ secrets.TARGET_HOST }}
        run: |
          sudo apt-get update -qq && sudo apt-get install -y -qq sshpass
          mkdir -p ~/.ssh "$HOME/.local/bin"
          ssh-keyscan -H "$SSH_HOST" >> ~/.ssh/known_hosts
          # DOCKER_HOST=ssh://… (job env, plus bas) invoque en interne le
          # binaire `ssh` du PATH, qui ne sait pas gérer un mot de passe
          # seul. On installe un wrapper prioritaire dans le PATH plutôt que
          # d'ajouter un 2e mécanisme de connexion à côté de celui-ci :
          # sshpass reste la seule source du mot de passe (SSHPASS, jamais
          # sur la ligne de commande), qu'on soit appelé directement ou via
          # DOCKER_HOST. REAL_SSH est résolu AVANT de modifier le PATH, pour
          # que le wrapper n'aille jamais s'invoquer lui-même en boucle.
          REAL_SSH="$(command -v ssh)"
          printf '#!/usr/bin/env bash\nexec sshpass -e "%s" -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@"\n' "$REAL_SSH" > "$HOME/.local/bin/ssh"
          chmod +x "$HOME/.local/bin/ssh"
          echo "$HOME/.local/bin" >> "$GITHUB_PATH"
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

  # Le wrapper installé par Setup SSH absorbe déjà sshpass : plus besoin de
  # l'invoquer explicitement ici, un seul chemin (le wrapper) gère les deux
  # usages (SSH direct et DOCKER_HOST).
  SSH_CMD='ssh'
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
          # DOCKER_HOST=ssh://… (job env, plus bas) invoque `ssh` sans
          # option -i : ~/.ssh/config lui fournit l'identité, sans ajouter
          # de 2e mécanisme de connexion à côté du SSH direct ci-dessus.
          printf 'Host *\n  IdentityFile ~/.ssh/deploy_key\n  StrictHostKeyChecking accept-new\n' >> ~/.ssh/config
          chmod 600 ~/.ssh/config
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
      deploy: \${{ steps.filter.outputs.deploy }}
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
            deploy:
              - 'deploy/**'

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

  # Ne se déclenche QUE si un changement pertinent a été détecté (code api,
  # code web, ou deploy/** — l'équivalent Compose des anciens manifests k8s).
  # Sans cette condition, un push documentation-only réécrirait quand même
  # IMAGE_TAG avec un SHA sous lequel aucune image n'a été poussée : le
  # 'pull' échouerait à coup sûr, un job rouge à chaque commit de doc.
  deploy:
    needs: [detect-changes, scan-secrets, build-and-push-api, build-and-push-web]
    if: |
      always() &&
      needs.scan-secrets.result == 'success' &&
      (needs.detect-changes.outputs.api == 'true' || needs.detect-changes.outputs.web == 'true' || needs.detect-changes.outputs.deploy == 'true') &&
      (needs.build-and-push-api.result == 'success' || needs.build-and-push-api.result == 'skipped') &&
      (needs.build-and-push-web.result == 'success' || needs.build-and-push-web.result == 'skipped')
    runs-on: ubuntu-latest
    env:
      # Même mécanisme que le panel (compose_remote/docker_remote,
      # lib/ssh_remote.sh) : on pilote le démon Docker DISTANT depuis le
      # compose.yml LOCAL au runner (checkouté juste après). Pas de fichiers
      # à copier sur la cible.
      DOCKER_HOST: ssh://\${{ secrets.TARGET_USER }}@\${{ secrets.TARGET_HOST }}
    steps:
      - uses: actions/checkout@v4

${SETUP_SSH_BLOCK}

      - name: Tag actuellement déployé (pour rollback)
${SSH_ENV}
        run: |
          prev="\$(docker ps --filter "label=com.docker.compose.project=${APP_NAME}" --format '{{.Image}}' | head -1 | awk -F: '{print \$NF}')"
          echo "PREV_TAG=\${prev}" >> "\$GITHUB_ENV"
          echo "Tag précédent : \${prev:-<aucun déploiement précédent>}"

      - name: Écriture de deploy/.env et déploiement
${SSH_ENV}
        run: |
          printf 'IMAGE_TAG=%s\n' "\${{ github.sha }}" > deploy/.env
          ${COMPOSE_CMD} pull
          ${COMPOSE_CMD} up -d --remove-orphans

      - name: Attente des healthchecks
${SSH_ENV}
        run: |
          for i in \$(seq 1 30); do
            bad="\$(${COMPOSE_CMD} ps --format json \\
              | jq -rs 'if type=="array" then . else [.] end
                        | map(select(.State != "running" or ((.Health // "") == "unhealthy")))
                        | length')"
            [ "\$bad" = "0" ] && exit 0
            sleep 3
          done
          echo 'healthchecks non satisfaits après 90s' >&2
          exit 1

      # Le contrôle de santé applicatif reste un SSH DIRECT (pas
      # DOCKER_HOST) : c'est un curl sur 127.0.0.1, qui n'a de sens que dans
      # l'espace réseau de la cible elle-même — un runner GitHub hébergé ne
      # peut pas joindre une adresse RFC1918, et Docker ne tunnelle que son
      # propre protocole API, pas des commandes shell arbitraires.
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
          if [ -n "\${PREV_TAG:-}" ]; then
            printf 'IMAGE_TAG=%s\n' "\${PREV_TAG}" > deploy/.env
            ${COMPOSE_CMD} pull
            ${COMPOSE_CMD} up -d --remove-orphans
            echo "rollback effectué vers le tag précédent (\${PREV_TAG})"
          else
            echo "aucun tag précédent connu — rollback impossible, intervention manuelle requise" >&2
          fi

${CLEANUP_BLOCK}
EOF

echo "  - .github/workflows/deploy.yml (auth=${TARGET_AUTH_METHOD}, images: ${API_IMAGE}/${WEB_IMAGE})"
