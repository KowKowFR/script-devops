#!/usr/bin/env bash
# lib/gen_skills.sh
# Génère les 5 Skills Claude Code custom du projet.
#
# Usage : gen_skills.sh WORK_DIR

set -euo pipefail

WORK_DIR="${1:?WORK_DIR required}"
SKILLS_DIR="$WORK_DIR/.agents/skills"

mkdir -p "$SKILLS_DIR"

# Symlink vers .claude/skills pour compatibilité Claude Code
mkdir -p "$WORK_DIR/.claude"
ln -sfn "../.agents/skills" "$WORK_DIR/.claude/skills" 2>/dev/null || true

# ====================================================================
# SKILL 1 : microservice-editor
# ====================================================================
mkdir -p "$SKILLS_DIR/microservice-editor"

cat > "$SKILLS_DIR/microservice-editor/SKILL.md" <<'EOF'
---
name: microservice-editor
description: Use this skill when the user wants to modify, add, or remove code in the microservices (Express API at services/api/server.js or static frontend at services/web/index.html). Triggers include "add a route", "modify the API", "add an endpoint", "change the home page", "ajoute une route", "modifie l'API". This skill knows the structure of both microservices and applies changes idiomatically.
---

# microservice-editor

This skill modifies the application code (API or Web) in this project.

## Project structure

- `services/api/server.js` — Express.js API
  - Routes already present: `GET /`, `GET /health`, `GET /info`
  - Convention: use `res.json(...)` for responses
  - Health-check must always remain at `GET /health` and return `{ status: "ok", ... }`
- `services/web/index.html` — static frontend served by nginx
  - Single-page HTML with CSS variables for theming

## Workflow

1. **Identify the microservice** the user wants to modify (api or web). Ask if ambiguous.
2. **Read the current source** to understand the existing conventions (route style, response format).
3. **Apply the change** using the Edit tool, preserving the existing style.
4. **Do NOT commit or push** — that is the job of the `github-flow` skill.
5. **Do NOT deploy** — that is the job of the `docker-deploy` skill.
6. Report what was changed and suggest the next skill to invoke.

## Output format

```
✓ Modified: <file path>
  - <summary of change>

Suggested next: github-flow (commit + push) → docker-deploy (deploy the app)
```

## Rules

- Never modify the `/health` endpoint signature (the Compose healthcheck depends on it).
- Always use `res.json()` for API responses, not `res.send()`.
- Keep the HTML file under ~100 lines for readability.
- If asked to add a complex feature requiring a new file, ask the user first.
EOF

# ====================================================================
# SKILL 2 : github-flow
# ====================================================================
mkdir -p "$SKILLS_DIR/github-flow"

cat > "$SKILLS_DIR/github-flow/SKILL.md" <<'EOF'
---
name: github-flow
description: Use this skill when the user wants to commit and push changes to GitHub. Triggers include "commit and push", "save my work", "push to github", "commit ça", "push sur main". This skill follows Conventional Commits and pushes directly to main (no branch / no PR in this project).
---

# github-flow

Commit changes and push to the `main` branch.

## Workflow

1. Run `git status` to see what changed.
2. If nothing changed, report and stop.
3. Categorize the changes:
   - Changes in `services/api/` → scope `api`
   - Changes in `services/web/` → scope `web`
   - Changes in `deploy/` → scope `deploy`
   - Changes in `.github/workflows/` → scope `ci`
   - Changes in `.agents/skills/` → scope `skills`
   - Changes in `*.md` → scope `docs`
4. Pick a type:
   - `feat:` for a new feature or endpoint
   - `fix:` for a bug fix
   - `chore:` for maintenance
   - `docs:` for documentation
   - `ci:` for CI/CD changes
   - `refactor:` for refactoring without behavior change
5. Build the message: `<type>(<scope>): <short description>`
6. Run `git add -A && git commit -m "<message>"`
7. Run `git push origin main`
8. Report the commit SHA and the URL of the workflow run that was triggered.

## Output format

```
✓ Committed: <SHA short> — <message>
✓ Pushed to origin/main
→ CI/CD triggered: https://github.com/<user>/<repo>/actions
```

## Rules

- One logical change per commit. If unsure, ask the user to split.
- Never force-push.
- Never amend an already-pushed commit.
- Never commit secrets or `.env*` files (the .gitignore covers this but double-check).
EOF

# ====================================================================
# SKILL 3 : docker-deploy
# ====================================================================
mkdir -p "$SKILLS_DIR/docker-deploy/scripts"
mkdir -p "$SKILLS_DIR/docker-deploy/references"

cat > "$SKILLS_DIR/docker-deploy/SKILL.md" <<'EOF'
---
name: docker-deploy
description: Use this skill when the user wants to deploy a new version of the application via the CI/CD pipeline or the DeployMatic panel. Triggers include "deploy", "deploy to prod", "release v1.0.4", "ship it", "déploie ça". This skill follows a strict GitOps approach — it does NOT build Docker images locally, it bumps the version, commits, pushes, and lets GitHub Actions rewrite deploy/.env and run docker compose up -d on the target.
---

# docker-deploy

Deploy a new version of the application via the CI/CD pipeline (GitOps approach).

## Why GitOps and not local build

Building Docker images locally caused platform mismatch issues (Mac ARM64 vs the target server's AMD64). We delegate build to GitHub Actions runners (Ubuntu AMD64), guaranteeing reproducibility regardless of the developer's machine. Git is the single source of truth.

## Workflow

1. Run `scripts/bump_version.sh patch|minor|major` to compute the next version.
2. Update `services/api/server.js` line `APP_VERSION`.
3. Stage and commit the change with message `chore(release): vX.Y.Z`.
4. Push to origin/main → this triggers the GitHub Actions workflow, which
   builds the image and pushes it tagged with the commit SHA, then rewrites
   `IMAGE_TAG` in a FRESH `deploy/.env` on the runner itself (nothing is
   copied to the target) and drives `docker compose pull && up -d` against
   the target's Docker daemon via `DOCKER_HOST=ssh://…` — see "Target
   access" below if you ever need to reproduce that manually.
5. Watch the workflow with `gh run watch` (or print the URL for the user).
6. Once the workflow completes successfully, invoke the `health-monitor` skill.

## Target access (DOCKER_HOST)

The CI never runs `docker`/`docker compose` on the local runner's own
daemon, and neither should you if you ever need to check state on the
target directly instead of waiting on CI logs. Export, first:

```
export TARGET_HOST=<same value as the GitHub secret TARGET_HOST>
export TARGET_USER=<same value as the GitHub secret TARGET_USER>
export DOCKER_HOST="ssh://${TARGET_USER}@${TARGET_HOST}"
```

Then `docker compose -f deploy/compose.yml ps` (for example) reaches the
TARGET's containers. Without `DOCKER_HOST` set, that same command silently
talks to YOUR OWN local Docker daemon instead — on a laptop, that can mean
pulling images to your machine or starting containers there, not on the
target, with no error to warn you.

## Output format

```
✓ Bumped version: vX.Y.Z → vA.B.C
✓ Pushed to origin/main
→ Workflow: <URL>
→ ETA: ~2 min (build + push + deploy)

Suggested next: health-monitor (verify deployment)
```

## Rules

- Never run `docker compose up` from the local machine — the deployment
  happens on the target, driven by the CI or the panel.
- Never run `docker build` from the local machine.
- Always bump the version (no two deployments with the same tag).
- If the user asks for a specific version, validate it follows semver (vMAJOR.MINOR.PATCH).
EOF

cat > "$SKILLS_DIR/docker-deploy/scripts/bump_version.sh" <<'EOF'
#!/usr/bin/env bash
# Compute the next semantic version based on the current one.
# Usage: bump_version.sh [patch|minor|major]

set -euo pipefail

BUMP="${1:-patch}"
SERVER_JS="services/api/server.js"

current=$(grep -oE "APP_VERSION = process.env.APP_VERSION \|\| '[0-9]+\.[0-9]+\.[0-9]+'" "$SERVER_JS" \
  | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")

if [[ -z "$current" ]]; then
  echo "Cannot detect current version in $SERVER_JS" >&2
  exit 1
fi

IFS='.' read -r major minor patch <<< "$current"

case "$BUMP" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "Unknown bump type: $BUMP" >&2; exit 1 ;;
esac

new="${major}.${minor}.${patch}"

# Update the file
sed -i.bak -E "s/(APP_VERSION = process.env.APP_VERSION \|\| ')[0-9]+\.[0-9]+\.[0-9]+(')/\1${new}\2/" "$SERVER_JS"
rm -f "${SERVER_JS}.bak"

echo "current=$current"
echo "new=$new"
EOF
chmod +x "$SKILLS_DIR/docker-deploy/scripts/bump_version.sh"

cat > "$SKILLS_DIR/docker-deploy/scripts/verify_health.sh" <<'EOF'
#!/usr/bin/env bash
# Check that /api/health responds with status:ok.
# Used by health-monitor skill after a deployment.
# Usage: verify_health.sh BASE_URL [max_attempts]

set -euo pipefail

URL="${1:?BASE_URL required}"
MAX="${2:-30}"

for i in $(seq 1 "$MAX"); do
  if response=$(curl -fsS -m 5 "${URL}/api/health" 2>/dev/null); then
    status=$(echo "$response" | grep -oE '"status":"[^"]+"' | cut -d'"' -f4)
    if [[ "$status" == "ok" ]]; then
      echo "healthy"
      echo "$response"
      exit 0
    fi
  fi
  sleep 2
done

echo "unhealthy" >&2
exit 1
EOF
chmod +x "$SKILLS_DIR/docker-deploy/scripts/verify_health.sh"

cat > "$SKILLS_DIR/docker-deploy/references/DEPLOYMENT_GUIDE.md" <<'EOF'
# Deployment Guide — docker-deploy skill

## Architecture in 3 stages

1. **Local edit** (microservice-editor skill): code is modified on the developer's machine.
2. **Git push** (github-flow skill): change is committed and pushed to GitHub.
3. **CI/CD** (this skill): GitHub Actions builds the image, pushes it to Docker
   Hub, rewrites `IMAGE_TAG` in a fresh `deploy/.env` **on the runner itself**
   (checked out from the same commit — nothing is ever copied to the target),
   then drives `docker compose pull && up -d` against the target's Docker
   daemon via `DOCKER_HOST=ssh://$TARGET_USER@$TARGET_HOST`. The runner never
   SSHes in to run commands on the target for this part — only the
   post-deploy application health-check does that (see below), because a
   `curl` on `127.0.0.1` only makes sense executed from the target's own
   network namespace, and Docker's `ssh://` transport tunnels its own API
   protocol only, not arbitrary shell commands.

## Workflow file

The CI/CD workflow lives at `.github/workflows/deploy.yml`. It has 4 jobs:

- `detect-changes` — uses `dorny/paths-filter` to identify which microservices changed
- `build-and-push-api` — builds and pushes the API image (only if `api` changed)
- `build-and-push-web` — builds and pushes the web image (only if `web` changed)
- `deploy` — rewrites `IMAGE_TAG` in `deploy/.env` with the SHA tag, then runs
  `docker compose pull && docker compose up -d --remove-orphans` against the
  target's Docker daemon via `DOCKER_HOST=ssh://…` (see above — no file is
  ever written on the target itself)

## Secrets

The following GitHub Actions secrets must be set:

- `DOCKERHUB_USERNAME` — Docker Hub username
- `DOCKERHUB_TOKEN` — Docker Hub access token (Read/Write/Delete scope)
- `TARGET_HOST` — IP or hostname of the target server
- `TARGET_USER` — SSH username on that server
- `TARGET_SSH_KEY` — private SSH key (entire file content), or `TARGET_PASSWORD`
  if key-based auth is not used

## Tagging strategy

Each image is pushed with TWO tags:

- `latest` — developer convenience
- `<SHA>` — the commit SHA, immutable

`deploy/compose.yml` references `${IMAGE_TAG}`, interpolated by Compose from
`deploy/.env`. The CI rewrites that single line with the commit SHA on every
deploy, so the running stack is always pinned to an immutable tag — never to
`latest`. Rolling back means putting an older SHA back in that line and
running `docker compose up -d` against the target's daemon (`DOCKER_HOST=
ssh://…`, see "Target access" above) — see the `rollback-manager` skill,
which does exactly this, resolving the target SHA from the target's Docker
daemon and git history (never a local file — see that skill for why).
EOF

# ====================================================================
# SKILL 4 : health-monitor
# ====================================================================
mkdir -p "$SKILLS_DIR/health-monitor/scripts"

cat > "$SKILLS_DIR/health-monitor/SKILL.md" <<'EOF'
---
name: health-monitor
description: Use this skill when the user wants to verify that the production deployment is healthy, especially right after a deploy. Triggers include "check production", "verify the deployment", "is everything ok", "vérifie que tout est OK". This skill performs a series of checks and triggers an automatic rollback if a check fails.
---

# health-monitor

Verify the production deployment and rollback automatically if any check fails.

## Checks performed (in order)

1. **Container status** — `docker compose ps` against the target's Docker
   daemon (`DOCKER_HOST=ssh://…`, see "Target access" below) : every service
   is `running`, and every service that declares a healthcheck is `healthy`.
2. **Restart count** — no container has restarted in the last 5 minutes
   (`docker inspect -f '{{.RestartCount}}'`, same `DOCKER_HOST`).
3. **HTTP health-check** — each exposed service answers on
   `http://127.0.0.1:<host port><health path>`, run **from the target host
   itself via `ssh` directly** (not via `DOCKER_HOST` — Docker's `ssh://`
   transport tunnels its own API protocol only, never arbitrary shell
   commands like `curl`). Never from a public URL: the target is not
   publicly reachable, only BunkerWeb is.
4. **Response time** — under 1 second.

## Target access (DOCKER_HOST)

Checks 1 and 2 above run `docker`/`docker compose` — always against the
target, never against whatever Docker daemon happens to be local to the
machine this skill runs on. Before running them, export:

```
export TARGET_HOST=<same value as the GitHub secret TARGET_HOST>
export TARGET_USER=<same value as the GitHub secret TARGET_USER>
export DOCKER_HOST="ssh://${TARGET_USER}@${TARGET_HOST}"
```

A bare `docker compose ps` without `DOCKER_HOST` set would report on
containers on the WRONG machine (or none at all) — a false "healthy" or a
false "unreachable", either way not the target's actual state.

## Workflow

1. With `DOCKER_HOST` exported as above, run `docker compose ps` and
   `docker inspect` to check container status and restart counts.
2. Use `scripts/check_health.sh <host port> <health path>`, executed via a
   direct `ssh` to the target (not through `DOCKER_HOST`), to verify the
   HTTP endpoint.
3. If ALL checks pass: report success and the current version.
4. If ANY check fails:
   - Invoke the `rollback-manager` skill to put the previous SHA back in
     `deploy/.env` and re-run `docker compose up -d` (same `DOCKER_HOST`).
   - Re-run the health-check.
   - Report what was rolled back and why.

## Output format (success)

```
✓ Health check passed (4/4)
  - Containers: 2/2 running (api, web)
  - Restart count: 0
  - /api/health: 200 OK (42ms)
  - Version active: v1.0.X

Production protected.
```

## Output format (rollback)

```
✗ Health check FAILED (1/4 failed)
  - /api/health: timeout after 3 attempts

Rolling back deploy/.env to the previous SHA…
  (see rollback-manager skill)

✓ Rollback complete (18s)
  - Previous version restored: v1.0.X
  - /api/health: 200 OK

⚠ Manual fix required. The bad version was reverted but the bug is still in main.
```

## Rules

- Always check `127.0.0.1:<host port>` on the target machine — never a public
  URL: BunkerWeb is the only thing publicly exposed, not the target host.
- Maximum 3 retries on the HTTP health-check before declaring failure.
- Never modify code or `deploy/.env` directly — only trigger the
  `rollback-manager` skill.
- Never run `docker`/`docker compose` without `DOCKER_HOST` set to the
  target — see "Target access" above. It talks to your own local daemon
  otherwise, silently.
EOF

cat > "$SKILLS_DIR/health-monitor/scripts/check_health.sh" <<'EOF'
#!/usr/bin/env bash
# Comprehensive health check, run from the target host.
# Usage: check_health.sh HOST_PORT HEALTH_PATH

set -euo pipefail

HOST_PORT="${1:?HOST_PORT required}"
HEALTH_PATH="${2:?HEALTH_PATH required}"
MAX_RETRIES=3
TIMEOUT_SEC=3

for i in $(seq 1 $MAX_RETRIES); do
  start=$(date +%s%N)
  if response=$(curl -fsS -m $TIMEOUT_SEC "http://127.0.0.1:${HOST_PORT}${HEALTH_PATH}" 2>/dev/null); then
    end=$(date +%s%N)
    elapsed_ms=$(( (end - start) / 1000000 ))
    status=$(echo "$response" | grep -oE '"status":"[^"]+"' | cut -d'"' -f4)
    if [[ "$status" == "ok" ]]; then
      echo "healthy"
      echo "response_time_ms=$elapsed_ms"
      echo "body=$response"
      exit 0
    fi
  fi
  sleep 1
done

echo "unhealthy" >&2
echo "reason=no_response_or_bad_status" >&2
exit 1
EOF
chmod +x "$SKILLS_DIR/health-monitor/scripts/check_health.sh"

# ====================================================================
# SKILL 5 : rollback-manager
# ====================================================================
mkdir -p "$SKILLS_DIR/rollback-manager/scripts"

cat > "$SKILLS_DIR/rollback-manager/SKILL.md" <<'EOF'
---
name: rollback-manager
description: Use this skill when the user wants to MANUALLY roll back a deployment to a previous version, either by a specific commit SHA (see `git log`) or simply "the previous version" (the commit deployed just before whatever is currently running on the target). Triggers include "rollback to <sha>", "revert last deploy", "go back to commit abc1234", "annule le dernier déploiement", "reviens à la version d'hier". Different from health-monitor (which rolls back automatically on health failure) — this skill is for INTENTIONAL human-driven rollbacks.
---

# rollback-manager

Roll back the deployment to a chosen previous image tag (commit SHA).

## When to use vs other skills

- **rollback-manager** (this one): user explicitly asks to rollback.
- **health-monitor**: rolls back AUTOMATICALLY when a health check fails after a deploy.
- **docker-deploy**: deploys a NEW version (forward).

## Where the tag history actually lives

Docker Compose keeps no revision history by itself. This project used to
keep its own local file for that — written after every successful deploy —
and it never actually worked, so it has been removed: the CI runner's git
clone is thrown away after every run, and a developer's own clone never
deploys by itself (deploys always go through the CI, see the `docker-deploy`
skill). Nothing was ever in a position to write to such a file AND still be
around later, on the SAME clone, to read it back — so "the previous
version" could never reliably be answered from it. Don't look for a local
history file; there isn't one, on purpose.

The information lives in two REAL places instead — target state and git,
never a local file:

- **What is currently running** — the target's own Docker daemon knows it.
  `scripts/rollback.sh list` asks it directly (`docker ps --filter
  label=com.docker.compose.project=…`), the exact same query as the CI's own
  "Tag actuellement déployé" step in `.github/workflows/deploy.yml`.
- **What came before that** — git knows it. A deployed tag IS a commit SHA
  (see `docker-deploy`'s tagging strategy), so "the previous version" is
  `git rev-parse "$CURRENT^"` — the parent, in git history, of the commit
  currently running on the target. `scripts/rollback.sh to previous`
  resolves it this way automatically. For anything further back, `git log`
  IS the record: unlike a local file, it is identical on every clone.

## Target access (DOCKER_HOST)

`scripts/rollback.sh` runs `docker compose pull && docker compose up -d`
(and reads current state via `docker ps`) against the **target's** Docker
daemon, never the machine it runs on. It requires `TARGET_HOST` and
`TARGET_USER` (same values as the GitHub secrets of the same name) exported
before it runs:

```
export TARGET_HOST=<same value as the GitHub secret TARGET_HOST>
export TARGET_USER=<same value as the GitHub secret TARGET_USER>
```

The script builds `DOCKER_HOST=ssh://$TARGET_USER@$TARGET_HOST` itself (add
`export TARGET_PORT=<same value as the GitHub secret TARGET_PORT>` too, only
if the target uses a non-standard SSH port) and fails fast (before touching
`deploy/.env`) if `TARGET_HOST`/`TARGET_USER` are missing — it never
silently falls back to a local Docker daemon.

`APP_NAME` (the compose project name on the target) is auto-detected from
`.github/workflows/deploy.yml`'s own `APP_NAME:` job env line — the exact
same value the CI itself uses, so there is nothing to remember or keep in
sync by hand. Export `APP_NAME` explicitly only to override this (e.g. that
file was moved or renamed).

## Workflow

1. Run `scripts/rollback.sh list` to see what is currently running on the target.
2. Help the user pick a target:
   - by SHA (from `git log`, or from whatever `list` just showed),
   - by "previous" — resolved automatically from the current tag's parent commit.
3. With `TARGET_HOST`/`TARGET_USER` exported (see "Target access" above),
   run `scripts/rollback.sh to <target>` (or `scripts/rollback.sh to previous`).
4. Wait for `docker compose up -d` to report the containers as started.
5. Invoke the `health-monitor` skill to validate the rolled-back version is healthy.

## Output format

```
✓ Rolled back deploy/.env
  - From: <SHA before>
  - To:   <SHA after>
  - Duration: <s>s

Suggested next: health-monitor (verify the rolled-back version is healthy)
```

## Rules

- Never guess a rollback target from memory — always resolve it from
  `scripts/rollback.sh list` (target state) or `git log` (history). There is
  no local history file to fall back on, on purpose (see above).
- Always confirm the target with the user if `<target>` is ambiguous.
- Rolling back does not remove the bad SHA from git history — the underlying
  bug still needs a forward fix.
- Display the diff (`git log <from>..<to>`) if both SHAs are available, so the
  user knows what's being reverted.
EOF

cat > "$SKILLS_DIR/rollback-manager/scripts/rollback.sh" <<'EOF'
#!/usr/bin/env bash
# Rollback helper — points deploy/.env at a different image tag and applies
# it on the target. State comes from TWO real places, never a local file:
#   - the target's own Docker daemon (DOCKER_HOST=ssh://…) for what is
#     CURRENTLY running — same `docker ps` filter as the "Tag actuellement
#     déployé" step of .github/workflows/deploy.yml.
#   - git history for anything before that: a deployed tag IS a commit SHA,
#     so "the version before the current one" is `git rev-parse "$CURRENT^"`.
# This project used to keep a local per-clone history file for this. It
# never worked: the CI runner's clone is discarded after every run, and a
# developer clone never deploys by itself (see docker-deploy) — nothing was
# ever in a position to write to it AND still be around later, on the SAME
# clone, to read it back. Removed for good; see rollback-manager's SKILL.md
# for the full reasoning.
#
# Usage:
#   rollback.sh list           show what is currently running on the target
#   rollback.sh to previous    roll back to the commit before the current one
#   rollback.sh to <sha>       roll back to a specific SHA (see `git log`)

set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-deploy}"
ENV_FILE="${DEPLOY_DIR}/.env"
WORKFLOW_FILE="${WORKFLOW_FILE:-.github/workflows/deploy.yml}"

current_tag() { grep '^IMAGE_TAG=' "$ENV_FILE" | cut -d= -f2; }

# _require_docker_host — construit et exporte DOCKER_HOST=ssh://user@host
# (port optionnel via TARGET_PORT) depuis TARGET_USER/TARGET_HOST (mêmes
# valeurs que les secrets GitHub du même nom). Sans ça, le `docker compose
# pull`/`up -d` (et la lecture de _running_tag) plus bas parlerait au démon
# Docker LOCAL de la machine qui exécute ce script — jamais celui de la
# cible : ce script tournerait alors en silence contre le mauvais démon,
# potentiellement en démarrant des conteneurs sur le poste du développeur.
# Appelée avant toute écriture dans deploy/.env : en cas de variable
# manquante, rien n'est modifié sur disque.
_require_docker_host() {
  : "${TARGET_HOST:?TARGET_HOST required (same value as the GitHub secret TARGET_HOST) - this script drives the Docker daemon on the target, never the local one}"
  : "${TARGET_USER:?TARGET_USER required (same value as the GitHub secret TARGET_USER)}"
  DOCKER_HOST="ssh://${TARGET_USER}@${TARGET_HOST}${TARGET_PORT:+:${TARGET_PORT}}"
  export DOCKER_HOST
}

# _require_app_name — APP_NAME identifie le projet compose sur la cible
# (docker compose --project-name "$APP_NAME", et le label que docker ps
# filtre plus bas). Auto-détecté depuis la propre ligne "APP_NAME: <valeur>"
# de l'env du job dans .github/workflows/deploy.yml — la même valeur que le
# CI utilise — plutôt que de demander à l'appelant de s'en souvenir ou de la
# garder synchronisée à la main. Positionner APP_NAME explicitement pour
# court-circuiter cette détection (fichier de workflow absent ou déplacé).
_require_app_name() {
  if [[ -z "${APP_NAME:-}" ]]; then
    # "|| true" sur le PIPELINE ENTIER (pas seulement grep) : sous
    # set -o pipefail, un grep qui ne trouve rien (fichier absent, ou
    # simplement "APP_NAME:" renommé/reformaté) rend un statut non nul pour
    # tout le pipeline, MEME SI awk a réussi sur une entrée vide (pipefail
    # retient le pire code, pas celui de la dernière commande). Sans ce
    # garde, `set -e` arrête le script sur-le-champ à cette affectation,
    # AVANT que le message d'aide du ":?" juste en dessous ne soit jamais
    # atteint - échec silencieux, zéro sortie, exactement le scénario
    # "le format du workflow change" que cette détection est censée rendre
    # diagnosticable.
    APP_NAME="$(grep -m1 '^  APP_NAME:' "$WORKFLOW_FILE" 2>/dev/null | awk '{print $2}' || true)"
  fi
  : "${APP_NAME:?APP_NAME required (could not auto-detect it from ${WORKFLOW_FILE} - export it explicitly, same value used to generate this project)}"
}

# _running_tag — tag d'image actuellement en cours d'exécution sur la cible
# pour CE projet compose, lu depuis le démon Docker de la cible
# (DOCKER_HOST doit déjà être exporté). Même filtre que l'étape "Tag
# actuellement déployé" du CI (.github/workflows/deploy.yml).
_running_tag() {
  docker ps --filter "label=com.docker.compose.project=${APP_NAME}" \
    --format '{{.Image}}' | head -1 | awk -F: '{print $NF}'
}

case "${1:?usage: rollback.sh list|to <target>}" in
  list)
    _require_docker_host
    _require_app_name
    # "|| true" : même raisonnement que _require_app_name plus haut - si le
    # démon distant est injoignable, on veut un "<none found>" lisible, pas
    # un arrêt muet de tout le script sous set -e/pipefail.
    running="$(_running_tag || true)"
    echo "Currently running on target (project ${APP_NAME}): ${running:-<none found>}"
    echo "deploy/.env in this clone (may be stale - this clone may not be the one that deployed it): $(current_tag 2>/dev/null || echo '<none>')"
    echo "For anything older than what is running: git log --oneline (a deployed tag IS a commit SHA)."
    ;;

  to)
    _require_docker_host
    _require_app_name
    target="${2:?usage: rollback.sh to previous|<sha>}"
    if [[ "$target" == "previous" ]]; then
      current="$(_running_tag)"
      [[ -n "$current" ]] \
        || { echo "no container currently running for project ${APP_NAME} on the target - nothing to compute 'previous' from, pass an explicit SHA" >&2; exit 1; }
      target="$(git rev-parse "${current}^" 2>/dev/null)" \
        || { echo "cannot resolve the commit before ${current} (shallow clone, detached tag, or ${current} is not in this repo's history) - pass an explicit SHA instead" >&2; exit 1; }
    fi
    echo "Rollback: $(_running_tag || echo '<unknown>') -> ${target} (DOCKER_HOST=${DOCKER_HOST})"
    sed -i.bak "s/^IMAGE_TAG=.*/IMAGE_TAG=${target}/" "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
    (cd "$DEPLOY_DIR" && docker compose --project-name "$APP_NAME" pull \
      && docker compose --project-name "$APP_NAME" up -d --remove-orphans)
    echo "current_tag=$(current_tag)"
    ;;

  *)
    echo "Unknown action: $1 (list | to)" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$SKILLS_DIR/rollback-manager/scripts/rollback.sh"

# ====================================================================
# Summary
# ====================================================================
echo "  • .agents/skills/microservice-editor/"
echo "  • .agents/skills/github-flow/"
echo "  • .agents/skills/docker-deploy/ (+ 2 scripts + DEPLOYMENT_GUIDE.md)"
echo "  • .agents/skills/health-monitor/ (+ check_health.sh)"
echo "  • .agents/skills/rollback-manager/ (+ rollback.sh)"
echo "  • .claude/skills → symlink vers .agents/skills"
