#!/usr/bin/env bash
# lib/gen_skills.sh
# Génère les 4 Skills Claude Code custom du projet.
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
5. **Do NOT deploy** — that is the job of the `k8s-deploy` skill.
6. Report what was changed and suggest the next skill to invoke.

## Output format

```
✓ Modified: <file path>
  - <summary of change>

Suggested next: github-flow (commit + push) → k8s-deploy (deploy to cluster)
```

## Rules

- Never modify the `/health` endpoint signature (Kubernetes liveness/readiness depend on it).
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
   - Changes in `k8s/` → scope `k8s`
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
# SKILL 3 : k8s-deploy
# ====================================================================
mkdir -p "$SKILLS_DIR/k8s-deploy/scripts"
mkdir -p "$SKILLS_DIR/k8s-deploy/references"

cat > "$SKILLS_DIR/k8s-deploy/SKILL.md" <<'EOF'
---
name: k8s-deploy
description: Use this skill when the user wants to deploy a new version of the application to the Kubernetes cluster. Triggers include "deploy", "deploy to prod", "release v1.0.4", "ship it", "déploie ça". This skill follows a strict GitOps approach — it does NOT build Docker images locally, it updates the manifest, commits, pushes, and lets GitHub Actions handle build + deploy.
---

# k8s-deploy

Deploy a new version of the application via the CI/CD pipeline (GitOps approach).

## Why GitOps and not local build

Building Docker images locally caused platform mismatch issues (Mac ARM64 vs cluster AMD64). We delegate build to GitHub Actions runners (Ubuntu AMD64), guaranteeing reproducibility regardless of the developer's machine. Git is the single source of truth.

## Workflow

1. Run `scripts/bump_version.sh patch|minor|major` to compute the next version.
2. Update `microservices/api/server.js` line `APP_VERSION` or the manifest `env` value.
3. Stage and commit the change with message `chore(release): vX.Y.Z`.
4. Push to origin/main → this triggers the GitHub Actions workflow.
5. Watch the workflow with `gh run watch` (or print the URL for the user).
6. Once the workflow completes successfully, invoke the `health-monitor` skill.

## Output format

```
✓ Bumped version: vX.Y.Z → vA.B.C
✓ Pushed to origin/main
→ Workflow: <URL>
→ ETA: ~3 min (build + push + rollout)

Suggested next: health-monitor (verify deployment)
```

## Rules

- Never run `kubectl set image` directly from the local machine.
- Never run `docker build` from the local machine.
- Always bump the version (no two deployments with the same tag).
- If the user asks for a specific version, validate it follows semver (vMAJOR.MINOR.PATCH).
EOF

cat > "$SKILLS_DIR/k8s-deploy/scripts/bump_version.sh" <<'EOF'
#!/usr/bin/env bash
# Compute the next semantic version based on the current one.
# Usage: bump_version.sh [patch|minor|major]

set -euo pipefail

BUMP="${1:-patch}"
SERVER_JS="microservices/api/server.js"

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
chmod +x "$SKILLS_DIR/k8s-deploy/scripts/bump_version.sh"

cat > "$SKILLS_DIR/k8s-deploy/scripts/verify_health.sh" <<'EOF'
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
chmod +x "$SKILLS_DIR/k8s-deploy/scripts/verify_health.sh"

cat > "$SKILLS_DIR/k8s-deploy/references/DEPLOYMENT_GUIDE.md" <<'EOF'
# Deployment Guide — k8s-deploy skill

## Architecture in 3 stages

1. **Local edit** (microservice-editor skill): code is modified on the developer's machine.
2. **Git push** (github-flow skill): change is committed and pushed to GitHub.
3. **CI/CD** (this skill): GitHub Actions builds the image, pushes to Docker Hub, then SSH into the OVH server to run `kubectl set image`.

## Workflow file

The CI/CD workflow lives at `.github/workflows/deploy.yml`. It has 4 jobs:

- `detect-changes` — uses `dorny/paths-filter` to identify which microservices changed
- `build-and-push-api` — builds and pushes the API image (only if `api` changed)
- `build-and-push-web` — builds and pushes the web image (only if `web` changed)
- `deploy` — SSH into the server, runs `kubectl set image` with the SHA tag

## Secrets

The following GitHub Actions secrets must be set:

- `DOCKERHUB_USERNAME` — Docker Hub username
- `DOCKERHUB_TOKEN` — Docker Hub access token (Read/Write/Delete scope)
- `OVH_HOST` — IP or hostname of the cluster server
- `OVH_USER` — SSH username on that server
- `OVH_SSH_KEY` — private SSH key (entire file content)

## Tagging strategy

Each image is pushed with TWO tags:

- `latest` — for developer convenience (local pulls)
- `<SHA>` — the commit SHA, immutable, used in production

The manifest references the image by `<SHA>`, never `latest`. This eliminates silent updates.
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

1. **Pods status** — all pods of `api` and `web` deployments are `Running` and `Ready`.
2. **Restart count** — no pod has restarted recently (last 5 min).
3. **HTTP health-check** — `GET /api/health` returns 200 with `{ status: "ok" }`.
4. **Response time** — `/api/health` responds in under 1 second.

## Workflow

1. Use `kubectl get pods` (via SSH if needed) to check pods.
2. Use `scripts/check_health.sh` to verify the HTTP endpoint.
3. If ALL checks pass: report success and the current version.
4. If ANY check fails:
   - Run `kubectl rollout undo deployment/<name>` on the affected deployment.
   - Wait for the rollback to complete (`kubectl rollout status`).
   - Re-run the health-check.
   - Report what was rolled back and why.

## Output format (success)

```
✓ Health check passed (3/3)
  - Pods: 4/4 Ready (api ×2, web ×2)
  - Restart count: 0
  - /api/health: 200 OK (42ms)
  - Version active: v1.0.X

Production protected.
```

## Output format (rollback)

```
✗ Health check FAILED (1/3 failed)
  - /api/health: timeout after 3 attempts

Rolling back deployment/api…
  kubectl rollout undo deployment/api
  kubectl rollout status deployment/api

✓ Rollback complete (18s)
  - Previous version restored: v1.0.X
  - /api/health: 200 OK

⚠ Manual fix required. The bad version was reverted but the bug is still in main.
```

## Rules

- Always rollback the SAME deployment that failed (don't touch the others).
- Maximum 3 retries on `/api/health` before declaring failure.
- Never modify code or manifests — only `kubectl rollout undo`.
EOF

cat > "$SKILLS_DIR/health-monitor/scripts/check_health.sh" <<'EOF'
#!/usr/bin/env bash
# Comprehensive health check.
# Usage: check_health.sh BASE_URL

set -euo pipefail

URL="${1:?BASE_URL required}"
MAX_RETRIES=3
TIMEOUT_SEC=3

for i in $(seq 1 $MAX_RETRIES); do
  start=$(date +%s%N)
  if response=$(curl -fsS -m $TIMEOUT_SEC "${URL}/api/health" 2>/dev/null); then
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
description: Use this skill when the user wants to MANUALLY roll back a deployment to a previous version, either by selecting a specific git SHA, a revision number from kubectl rollout history, or simply "the previous version". Triggers include "rollback to v1.2.3", "revert last deploy", "go back to commit abc1234", "annule le dernier déploiement", "reviens à la version d'hier". Different from health-monitor (which rolls back automatically on health failure) — this skill is for INTENTIONAL human-driven rollbacks.
---

# rollback-manager

Roll back a Kubernetes deployment to a chosen previous revision.

## When to use vs other skills

- **rollback-manager** (this one): user explicitly asks to rollback.
- **health-monitor**: rolls back AUTOMATICALLY when a health check fails after a deploy.
- **k8s-deploy**: deploys a NEW version (forward).

## Workflow

1. Identify which deployment the user wants to roll back (api or web). Ask if ambiguous.
2. Run `scripts/rollback.sh <deploy> list` to display revision history with image SHAs.
3. Help the user pick a target:
   - by revision number (`#3`),
   - by image SHA (the last 7 chars of a git commit),
   - by "previous" (=N-1, simplest case).
4. Run `scripts/rollback.sh <deploy> to <target>`.
5. Wait for `kubectl rollout status` to confirm.
6. Invoke the `health-monitor` skill to validate the rolled-back version is healthy.

## Output format

```
✓ Rolled back deployment/<name>
  - From: <SHA before>  (revision N)
  - To:   <SHA after>   (revision N-1)
  - Duration: <s>s

Suggested next: health-monitor (verify the rolled-back version is healthy)
```

## Rules

- Never modify code or manifests — the rollback uses ONLY `kubectl rollout undo`.
- Always confirm the target with the user if `<target>` is ambiguous.
- After rollback, the previous version is GONE from history unless re-tagged in git.
  If the user wants to keep both options open, prefer `kubectl set image` with an
  explicit SHA tag instead (forward deploy of the older version).
- Display the diff (`git log <from>..<to>`) if both SHAs are available, so the user
  knows what's being reverted.
EOF

cat > "$SKILLS_DIR/rollback-manager/scripts/rollback.sh" <<'EOF'
#!/usr/bin/env bash
# Rollback helper for the rollback-manager skill.
#
# Usage:
#   rollback.sh <deploy>  list                   # show revision history
#   rollback.sh <deploy>  to previous            # undo to N-1
#   rollback.sh <deploy>  to <revision-number>   # undo to specific revision

set -euo pipefail

DEPLOY="${1:?deployment name required (e.g. tp-app-api)}"
ACTION="${2:?action required (list|to)}"

case "$ACTION" in
  list)
    echo "=== Revision history for deployment/${DEPLOY} ==="
    kubectl rollout history "deployment/${DEPLOY}"
    echo
    echo "=== Image per revision ==="
    # Liste les ReplicaSets liés et leur image (donne le tag SHA).
    kubectl get rs -l "app=${DEPLOY}" \
      -o custom-columns=REV:.metadata.annotations.deployment\\.kubernetes\\.io/revision,NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image \
      --sort-by=.metadata.annotations.deployment\.kubernetes\.io/revision
    ;;

  to)
    TARGET="${3:?target required (previous | <revision-number>)}"
    if [[ "$TARGET" == "previous" ]]; then
      echo "Rolling back deployment/${DEPLOY} to previous revision…"
      kubectl rollout undo "deployment/${DEPLOY}"
    elif [[ "$TARGET" =~ ^[0-9]+$ ]]; then
      echo "Rolling back deployment/${DEPLOY} to revision ${TARGET}…"
      kubectl rollout undo "deployment/${DEPLOY}" --to-revision="$TARGET"
    else
      echo "Target must be 'previous' or a revision number (got: ${TARGET})" >&2
      exit 1
    fi
    kubectl rollout status "deployment/${DEPLOY}" --timeout=2m
    echo "current_image=$(kubectl get deploy ${DEPLOY} -o jsonpath='{.spec.template.spec.containers[*].image}')"
    ;;

  *)
    echo "Unknown action: ${ACTION} (use: list | to)" >&2
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
echo "  • .agents/skills/k8s-deploy/ (+ 2 scripts + DEPLOYMENT_GUIDE.md)"
echo "  • .agents/skills/health-monitor/ (+ check_health.sh)"
echo "  • .agents/skills/rollback-manager/ (+ rollback.sh)"
echo "  • .claude/skills → symlink vers .agents/skills"
