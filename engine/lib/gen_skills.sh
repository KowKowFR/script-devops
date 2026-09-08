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
description: Use this skill when the user wants to modify, add, or remove code in the microservices (Express API at microservices/api/server.js or static frontend at microservices/web/index.html). Triggers include "add a route", "modify the API", "add an endpoint", "change the home page", "ajoute une route", "modifie l'API". This skill knows the structure of both microservices and applies changes idiomatically.
---

# microservice-editor

This skill modifies the application code (API or Web) in this project.

## Project structure

- `microservices/api/server.js` — Express.js API
  - Routes already present: `GET /`, `GET /health`, `GET /info`
  - Convention: use `res.json(...)` for responses
  - Health-check must always remain at `GET /health` and return `{ status: "ok", ... }`
- `microservices/web/index.html` — static frontend served by nginx
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
   - Changes in `microservices/api/` → scope `api`
   - Changes in `microservices/web/` → scope `web`
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
   builds the image, pushes it tagged with the commit SHA, then rewrites
   `IMAGE_TAG` in `deploy/.env` on the target and runs `docker compose up -d`.
5. Watch the workflow with `gh run watch` (or print the URL for the user).
6. Once the workflow completes successfully, invoke the `health-monitor` skill.

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
3. **CI/CD** (this skill): GitHub Actions builds the image, pushes to Docker Hub, then SSH into the target server to rewrite `IMAGE_TAG` in `deploy/.env` and run `docker compose up -d`.

## Workflow file

The CI/CD workflow lives at `.github/workflows/deploy.yml`. It has 4 jobs:

- `detect-changes` — uses `dorny/paths-filter` to identify which microservices changed
- `build-and-push-api` — builds and pushes the API image (only if `api` changed)
- `build-and-push-web` — builds and pushes the web image (only if `web` changed)
- `deploy` — SSH into the target, rewrites `IMAGE_TAG` in `deploy/.env` with the
  SHA tag, then runs `docker compose pull && docker compose up -d --remove-orphans`

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
`latest`. Rolling back means putting an older SHA back in that line and running
`docker compose up -d`.
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

1. **Container status** — `docker compose ps` : every service is `running`, and
   every service that declares a healthcheck is `healthy`.
2. **Restart count** — no container has restarted in the last 5 minutes
   (`docker inspect -f '{{.RestartCount}}'`).
3. **HTTP health-check** — each exposed service answers on
   `http://127.0.0.1:<host port><health path>`, **from the target host**. Never
   from a public URL: the target is not publicly reachable, only BunkerWeb is.
4. **Response time** — under 1 second.

## Workflow

1. Run `docker compose ps` (via SSH on the target) to check container status
   and restart counts.
2. Use `scripts/check_health.sh <host port> <health path>` on the target host
   to verify the HTTP endpoint.
3. If ALL checks pass: report success and the current version.
4. If ANY check fails:
   - Invoke the `rollback-manager` skill to put the previous SHA back in
     `deploy/.env` and re-run `docker compose up -d`.
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
description: Use this skill when the user wants to MANUALLY roll back a deployment to a previous version, either by selecting a specific image SHA from deploy/.image-history, or simply "the previous version". Triggers include "rollback to <sha>", "revert last deploy", "go back to commit abc1234", "annule le dernier déploiement", "reviens à la version d'hier". Different from health-monitor (which rolls back automatically on health failure) — this skill is for INTENTIONAL human-driven rollbacks.
---

# rollback-manager

Roll back the deployment to a chosen previous image tag (commit SHA).

## When to use vs other skills

- **rollback-manager** (this one): user explicitly asks to rollback.
- **health-monitor**: rolls back AUTOMATICALLY when a health check fails after a deploy.
- **docker-deploy**: deploys a NEW version (forward).

## Why Compose has no built-in undo command

Docker Compose keeps no revision history by itself. The only source of truth
is `deploy/.image-history`, a file listing the last five deployed SHAs (most
recent first), written by `scripts/record_tag.sh` after every successful
deploy. Without it, "go back to the previous version" is meaningless — there
would be nothing to go back to.

## Workflow

1. Run `scripts/rollback.sh list` to display the current tag and the history.
2. Help the user pick a target:
   - by SHA (from the history, or from `git log`),
   - by "previous" (the second line of `.image-history`, simplest case).
3. Run `scripts/rollback.sh to <target>` (or `scripts/rollback.sh to previous`).
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

- Never edit `deploy/.image-history` by hand — it is only ever written by
  `scripts/record_tag.sh`.
- Always confirm the target with the user if `<target>` is ambiguous.
- Rolling back does not remove the bad SHA from git history — the underlying
  bug still needs a forward fix.
- Display the diff (`git log <from>..<to>`) if both SHAs are available, so the
  user knows what's being reverted.
EOF

cat > "$SKILLS_DIR/rollback-manager/scripts/rollback.sh" <<'EOF'
#!/usr/bin/env bash
# Rollback helper — puts a previous image tag back into deploy/.env.
#
# Usage:
#   rollback.sh list           show the history of deployed tags
#   rollback.sh to previous    roll back to the previous tag
#   rollback.sh to <sha>       roll back to a specific SHA

set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-deploy}"
ENV_FILE="${DEPLOY_DIR}/.env"
HISTORY="${DEPLOY_DIR}/.image-history"

current_tag() { grep '^IMAGE_TAG=' "$ENV_FILE" | cut -d= -f2; }

case "${1:?usage: rollback.sh list|to <target>}" in
  list)
    echo "Current tag: $(current_tag)"
    echo "History (most recent first):"
    [[ -f "$HISTORY" ]] && cat "$HISTORY" || echo "  (empty)"
    ;;

  to)
    target="${2:?usage: rollback.sh to previous|<sha>}"
    if [[ "$target" == "previous" ]]; then
      [[ -f "$HISTORY" ]] || { echo "no history available" >&2; exit 1; }
      target=$(sed -n '2p' "$HISTORY")
      [[ -n "$target" ]] || { echo "no previous tag available" >&2; exit 1; }
    fi
    echo "Rollback: $(current_tag) -> ${target}"
    sed -i.bak "s/^IMAGE_TAG=.*/IMAGE_TAG=${target}/" "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
    (cd "$DEPLOY_DIR" && docker compose pull && docker compose up -d --remove-orphans)
    echo "current_tag=$(current_tag)"
    ;;

  *)
    echo "Unknown action: $1 (list | to)" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$SKILLS_DIR/rollback-manager/scripts/rollback.sh"

cat > "$SKILLS_DIR/rollback-manager/scripts/record_tag.sh" <<'EOF'
#!/usr/bin/env bash
# Records the currently deployed image tag at the top of
# deploy/.image-history, keeping only the 5 most recent entries. Run right
# after a successful deploy — this is what makes "rollback to previous"
# possible.
#
# Usage: record_tag.sh [DEPLOY_DIR]

set -euo pipefail

DEPLOY_DIR="${1:-deploy}"
ENV_FILE="${DEPLOY_DIR}/.env"
HISTORY="${DEPLOY_DIR}/.image-history"

[[ -f "$ENV_FILE" ]] || { echo "${ENV_FILE} not found" >&2; exit 1; }

tag=$(grep '^IMAGE_TAG=' "$ENV_FILE" | cut -d= -f2)
[[ -n "$tag" ]] || { echo "IMAGE_TAG not set in ${ENV_FILE}" >&2; exit 1; }

tmp="$(mktemp "${HISTORY}.XXXXXX")"
{
  printf '%s\n' "$tag"
  if [[ -f "$HISTORY" ]]; then
    grep -vFx "$tag" "$HISTORY" || true
  fi
} | head -n 5 > "$tmp"
mv -f "$tmp" "$HISTORY"

echo "recorded=$tag"
EOF
chmod +x "$SKILLS_DIR/rollback-manager/scripts/record_tag.sh"

# ====================================================================
# Summary
# ====================================================================
echo "  • .agents/skills/microservice-editor/"
echo "  • .agents/skills/github-flow/"
echo "  • .agents/skills/docker-deploy/ (+ 2 scripts + DEPLOYMENT_GUIDE.md)"
echo "  • .agents/skills/health-monitor/ (+ check_health.sh)"
echo "  • .agents/skills/rollback-manager/ (+ rollback.sh + record_tag.sh)"
echo "  • .claude/skills → symlink vers .agents/skills"
