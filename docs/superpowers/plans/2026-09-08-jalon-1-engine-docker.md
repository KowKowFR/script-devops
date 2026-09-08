# Jalon 1 — Engine : migration K3s → Docker et dispatcher d'étapes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transformer `bootstrap.sh` d'un orchestrateur de pipeline K3s interactif en un exécuteur d'étapes non-interactif, piloté par JSON, dont la cible de déploiement est Docker Compose.

**Architecture:** Le tableau `PIPELINE` et le suivi d'état sur fichier disparaissent : `engine/bootstrap.sh --workspace <ws> --step <nom>` exécute exactement une étape, lit ses paramètres dans `runs/<ws>/env.json` et `runs/<ws>/spec.json` via `jq`, écrit ses logs sur stderr et une unique ligne JSON de résultat sur stdout. Les manifests Kubernetes sont remplacés par un `deploy/compose.yml` généré depuis `spec.json`, dont le tag d'image est piloté par `deploy/.env` — ce qui devient le mécanisme de rollback. Aucun `source` de fichier de configuration ne subsiste.

**Tech Stack:** bash 3.2+, jq, docker CLI + compose plugin (piloté à distance via `DOCKER_HOST=ssh://`), shellcheck, harnais de test bash maison sans dépendance externe.

## Global Constraints

- **Compatibilité bash 3.2** (`/bin/bash` de macOS). Interdits : tableaux associatifs (`declare -A`), `${var,,}` / `${var^^}`, `mapfile` / `readarray`, `**` en glob. Autorisés : tableaux indexés, `${!var}`, `printf -v`.
- **stdout est sacré.** Toute étape écrit **exactement une** ligne JSON sur stdout, en fin d'exécution. Tout le reste — logs, avertissements, sorties de commandes tierces — part sur **stderr**. Un générateur qui `echo` un résumé sur stdout est un bug.
- **Codes de sortie :** `0` succès, `1` échec réessayable, `2` échec fatal (non réessayable : configuration invalide, spec invalide, refus de l'utilisateur).
- **Plus aucun `source` de configuration.** Les paramètres se lisent en JSON avec `jq`. `grep -rn 'source.*env\|\. .*\.bootstrap-env' engine/` doit ne rien remonter.
- **Aucun prompt interactif** dans `engine/`. Toute décision qui était un `ui_confirm` devient une clé d'`env.json` ou un échec code 2.
- **Permissions :** `runs/` en `700`, `runs/<ws>/env.json` et `spec.json` en `600`.
- **Ports :** port CONTENEUR (interne, libre) et port HÔTE (publié, ≥ 1024, fourni par `env.json`) sont strictement distincts. `network_mode: host` est interdit.
- **shellcheck** ne remonte aucun diagnostic de niveau `error` sur les fichiers modifiés.
- **Commentaires et messages en français**, comme le code existant. Commits conventionnels, atomiques.
- **Branche :** `main`. Pas de worktree.
- **Hors périmètre :** BunkerWeb (jalon 4), scanners (jalon 6), IA (jalon 5), allocation de ports (jalon 3), tout code Python. `web/` reste en place et cassé, on ne le touche pas.

## Décisions actées avant rédaction

- **GitHub devient optionnel** (option 1b). Les étapes GitHub sont regroupées et pilotées par `github.enabled` dans `env.json`. Le chemin prioritaire est le chemin panel : build sur la cible via `DOCKER_HOST=ssh://`, puis déploiement. Une panne GitHub ne bloque jamais un déploiement.
- **`step_build_images` existe dès ce jalon** (conséquence directe de 1b) et se place avant `deploy_stack`.
- **L'étape « attendre la fin du workflow CI » disparaît.** Elle n'a plus de sens quand le panel déploie lui-même.
- **Aucune cible SSH de test n'est disponible.** Le critère d'acceptation 6 (`--all` de bout en bout) ne pourra pas être validé dans ce jalon. Il est remplacé par un `--dry-run` qui imprime les commandes distantes sans les exécuter, et la Task 15 exige de le déclarer explicitement.

---

## Structure de fichiers cible

```
bootstrap-tp/
├── engine/
│   ├── bootstrap.sh              dispatcher : --step / --all / --list-steps / --dry-run
│   ├── lib/
│   │   ├── runtime.sh            emit_ok, emit_fail, die, log_init (stderr), trap ERR
│   │   ├── config.sh             cfg, cfg_bool, cfg_req, spec_* (lecture jq)
│   │   ├── units.sh              [NOUVEAU] k8s_cpu_to_docker, k8s_mem_to_docker
│   │   ├── ui.sh                 messages → stderr ; prompts supprimés
│   │   ├── ssh_remote.sh         ssh_remote, scp_remote, docker_host, docker_remote
│   │   ├── prereqs.sh            check_prereqs non-interactif
│   │   ├── steps.sh              fonctions step_*
│   │   ├── gen_microservices.sh  API Express + front nginx-unprivileged
│   │   ├── gen_compose.sh        [NOUVEAU] remplace gen_manifests.sh
│   │   ├── gen_workflow.sh       workflow GitHub Actions (deploy par compose)
│   │   ├── gen_skills.sh         Skills Claude Code (docker-deploy, …)
│   │   ├── prepare_server.sh     provisioning : docker, ufw, fail2ban
│   │   └── diag.sh               cmd_doctor, cmd_logs, cmd_stack_info
│   ├── templates/
│   │   └── spec.demo.json        [NOUVEAU] app de démo (Express + nginx)
│   ├── tools/
│   │   └── migrate-env.sh        [NOUVEAU] .bootstrap-env → env.json
│   └── tests/
│       ├── run.sh                [NOUVEAU] lance tous les test_*.sh
│       ├── helpers.sh            [NOUVEAU] assert_eq, assert_contains, …
│       ├── fixtures/
│       │   ├── env.min.json      [NOUVEAU]
│       │   └── spec.multi.json   [NOUVEAU] api + web + db interne
│       ├── test_units.sh         [NOUVEAU]
│       ├── test_config.sh        [NOUVEAU]
│       ├── test_runtime.sh       [NOUVEAU]
│       ├── test_dispatcher.sh    [NOUVEAU]
│       ├── test_gen_compose.sh   [NOUVEAU]
│       └── test_gen_micro.sh     [NOUVEAU]
├── runs/<ws>/                    env.json, spec.json, <app>/  (gitignoré)
├── web/                          INCHANGÉ, cassé, remplacé au jalon 2
└── docs/superpowers/plans/
```

**Supprimés :** `lib/state.sh`, `lib/collect.sh`, `lib/workspace.sh`, `lib/gen_manifests.sh`.
La gestion du cycle de vie des workspaces remonte au panel (jalon 2). L'engine se contente de résoudre `runs/<ws>/` et de refuser un nom invalide.

## Liste d'étapes (ordre de `--all`)

Constante `STEPS` dans `engine/bootstrap.sh` :

```
check_prereqs
validate_ssh
create_project_dir
generate_microservices
generate_compose
generate_skills
generate_workflow
enable_sudo_nopasswd
prepare_server
build_images
deploy_stack
validate_deployment
github_create_repo      # sauté si github.enabled != true
github_set_secrets      # sauté si github.enabled != true
git_init                # sauté si github.enabled != true
git_push                # sauté si github.enabled != true
```

## Schéma `env.json`

```json
{
  "app":    { "name": "tp-app", "author": "Alex Falzon" },
  "target": { "host": "1.2.3.4", "user": "devops", "auth_method": "key",
              "ssh_key_path": "/Users/kowkow/.ssh/id_ed25519", "password": "",
              "bind_addr": "0.0.0.0" },
  "registry": { "user": "dockerhubuser", "token": "dckr_pat_..." },
  "github": { "enabled": false, "user": "", "repo": "", "token": "" },
  "ports":  { "api": 10001, "web": 10002 },
  "limits": { "cpu": "200m", "memory": "128Mi" },
  "options": { "reuse_existing_dir": true, "allow_existing_repo": true }
}
```

`ports` est une table `service_id → port hôte`. Au jalon 3 elle sera remplie par l'allocateur ; ici elle vient de la main de l'humain. **L'engine ne choisit jamais un port.**

---

## Task 1: Réorganisation `engine/` et harnais de test

**Files:**
- Move: `bootstrap.sh` → `engine/bootstrap.sh`, `lib/` → `engine/lib/`
- Create: `engine/tests/run.sh`, `engine/tests/helpers.sh`, `engine/tests/test_smoke.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: rien.
- Produces: `assert_eq EXPECTED ACTUAL MESSAGE`, `assert_contains HAYSTACK NEEDLE MESSAGE`, `assert_exit_code EXPECTED CMD…`, `finish` (sortie 1 si un assert a échoué), variable `TESTS_DIR`, `ENGINE_DIR`, `REPO_ROOT`.

- [ ] **Step 1: Déplacer les fichiers avec git mv**

```bash
cd /Users/kowkow/Desktop/Projects/bootstrap-tp
mkdir -p engine
git mv bootstrap.sh engine/bootstrap.sh
git mv lib engine/lib
mkdir -p engine/tests/fixtures engine/templates engine/tools
```

- [ ] **Step 2: Corriger le chemin de résolution des modules dans engine/bootstrap.sh**

`SCRIPT_DIR` pointe désormais sur `engine/`. Le dossier `runs/` reste à la racine du repo. Remplacer le bloc de constantes (`engine/bootstrap.sh`, ~ligne 40-66) par :

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT
readonly RUNS_DIR="${REPO_ROOT}/runs"
```

- [ ] **Step 3: Écrire le harnais de test**

Créer `engine/tests/helpers.sh` :

```bash
#!/usr/bin/env bash
# engine/tests/helpers.sh — micro-harnais d'assertions, sans dépendance externe.
# Chaque test_*.sh source ce fichier, appelle des assert_*, puis finish.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ENGINE_DIR/.." && pwd)"
export TESTS_DIR ENGINE_DIR REPO_ROOT

_T_PASS=0
_T_FAIL=0

_t_ok()   { _T_PASS=$((_T_PASS + 1)); printf '  ok   %s\n' "$1"; }
_t_fail() {
  _T_FAIL=$((_T_FAIL + 1))
  printf '  FAIL %s\n' "$1"
  shift
  local line
  for line in "$@"; do printf '       %s\n' "$line"; done
}

assert_eq() {
  # assert_eq ATTENDU OBTENU MESSAGE
  if [[ "$1" == "$2" ]]; then
    _t_ok "$3"
  else
    _t_fail "$3" "attendu : [$1]" "obtenu  : [$2]"
  fi
}

assert_contains() {
  # assert_contains TEXTE MOTIF MESSAGE
  if printf '%s' "$1" | grep -qF -- "$2"; then
    _t_ok "$3"
  else
    _t_fail "$3" "motif absent : [$2]"
  fi
}

assert_not_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then
    _t_fail "$3" "motif présent alors qu'il ne devrait pas : [$2]"
  else
    _t_ok "$3"
  fi
}

assert_exit_code() {
  # assert_exit_code ATTENDU MESSAGE -- cmd args...
  local expected="$1" msg="$2"; shift 2
  [[ "${1:-}" == "--" ]] && shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "$expected" ]]; then
    _t_ok "$msg"
  else
    _t_fail "$msg" "code attendu : $expected" "code obtenu  : $rc"
  fi
}

assert_valid_json() {
  # assert_valid_json TEXTE MESSAGE
  if printf '%s' "$1" | jq -e . >/dev/null 2>&1; then
    _t_ok "$2"
  else
    _t_fail "$2" "JSON invalide : [$1]"
  fi
}

finish() {
  printf '  → %d ok, %d échec(s)\n' "$_T_PASS" "$_T_FAIL"
  [[ "$_T_FAIL" -eq 0 ]]
}
```

- [ ] **Step 4: Écrire le lanceur**

Créer `engine/tests/run.sh` :

```bash
#!/usr/bin/env bash
# engine/tests/run.sh — lance tous les engine/tests/test_*.sh.
# Usage : engine/tests/run.sh [motif]

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PATTERN="${1:-}"

total_fail=0
for f in "$TESTS_DIR"/test_*.sh; do
  [[ -f "$f" ]] || continue
  if [[ -n "$PATTERN" ]] && ! printf '%s' "$(basename "$f")" | grep -q "$PATTERN"; then
    continue
  fi
  printf '\n== %s\n' "$(basename "$f")"
  bash "$f" || total_fail=$((total_fail + 1))
done

printf '\n=== syntaxe (bash -n) ===\n'
for f in "$ENGINE_DIR"/bootstrap.sh "$ENGINE_DIR"/lib/*.sh "$ENGINE_DIR"/tools/*.sh; do
  [[ -f "$f" ]] || continue
  if bash -n "$f" 2>/dev/null; then
    printf '  ok   %s\n' "${f#"$ENGINE_DIR"/}"
  else
    printf '  FAIL %s\n' "${f#"$ENGINE_DIR"/}"
    bash -n "$f" || true
    total_fail=$((total_fail + 1))
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  printf '\n=== shellcheck (niveau error) ===\n'
  if shellcheck --severity=error --shell=bash \
       "$ENGINE_DIR"/bootstrap.sh "$ENGINE_DIR"/lib/*.sh "$ENGINE_DIR"/tools/*.sh; then
    printf '  ok   aucune erreur\n'
  else
    total_fail=$((total_fail + 1))
  fi
else
  printf '\n  (shellcheck absent — vérification sautée)\n'
fi

printf '\n'
if [[ "$total_fail" -eq 0 ]]; then
  printf 'TOUT PASSE\n'; exit 0
fi
printf '%d fichier(s) de test en échec\n' "$total_fail"; exit 1
```

- [ ] **Step 5: Écrire un test de fumée qui échoue d'abord**

Créer `engine/tests/test_smoke.sh` :

```bash
#!/usr/bin/env bash
# Vérifie que la réorganisation est faite et que le harnais fonctionne.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

assert_eq "1" "$([[ -f "$ENGINE_DIR/bootstrap.sh" ]] && echo 1 || echo 0)" \
  "engine/bootstrap.sh existe"
assert_eq "1" "$([[ -d "$ENGINE_DIR/lib" ]] && echo 1 || echo 0)" \
  "engine/lib/ existe"
assert_eq "0" "$([[ -f "$REPO_ROOT/bootstrap.sh" ]] && echo 1 || echo 0)" \
  "plus de bootstrap.sh à la racine"
assert_eq "1" "$(command -v jq >/dev/null 2>&1 && echo 1 || echo 0)" \
  "jq est disponible"

finish
```

- [ ] **Step 6: Rendre exécutable et lancer**

```bash
chmod +x engine/tests/run.sh engine/tests/helpers.sh engine/tests/test_smoke.sh
bash engine/tests/run.sh
```

Attendu : les 4 assertions de `test_smoke.sh` passent. `bash -n` peut échouer sur des fichiers non encore migrés — c'est normal à ce stade, noter lesquels. Si `shellcheck` remonte des erreurs pré-existantes, les corriger maintenant ou les documenter dans le commit.

- [ ] **Step 7: Mettre à jour .gitignore**

Remplacer les lignes « Legacy » de `.gitignore` par :

```
# Workspaces (état local de chaque projet — jamais versionner)
runs/

# Legacy (ancien layout ; supprimé au jalon 1, gardé pour les vieux clones)
.bootstrap-env
.bootstrap-state
.bootstrap.log
.bootstrap.lock
.bootstrap.web.pid
tp-devops-agent-ia/
```

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor(engine): déplace bootstrap.sh et lib/ sous engine/ + harnais de test"
```

---

## Task 2: `lib/units.sh` — conversion des unités Kubernetes → Docker

**Files:**
- Create: `engine/lib/units.sh`, `engine/tests/test_units.sh`

**Interfaces:**
- Consumes: rien.
- Produces: `k8s_cpu_to_docker <valeur>` → chaîne décimale (`"0.2"`), `k8s_mem_to_docker <valeur>` → chaîne avec suffixe Docker (`"128m"`). Les deux renvoient 1 et n'impriment rien sur stdout si l'entrée est invalide. Utilisés par `gen_compose.sh` (Task 8).

- [ ] **Step 1: Écrire le test qui échoue**

Créer `engine/tests/test_units.sh` :

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$ENGINE_DIR/lib/units.sh"

# --- CPU ---
assert_eq "0.2"  "$(k8s_cpu_to_docker 200m)"   "200m → 0.2"
assert_eq "1.5"  "$(k8s_cpu_to_docker 1500m)"  "1500m → 1.5"
assert_eq "0.05" "$(k8s_cpu_to_docker 50m)"    "50m → 0.05"
assert_eq "1"    "$(k8s_cpu_to_docker 1)"      "1 → 1 (déjà en cœurs)"
assert_eq "0.5"  "$(k8s_cpu_to_docker 0.5)"    "0.5 → 0.5 (déjà décimal)"
assert_eq "2"    "$(k8s_cpu_to_docker 2000m)"  "2000m → 2"
assert_exit_code 1 "cpu vide rejeté" -- k8s_cpu_to_docker ""
assert_exit_code 1 "cpu non numérique rejeté" -- k8s_cpu_to_docker "beaucoup"

# --- Mémoire ---
assert_eq "128m" "$(k8s_mem_to_docker 128Mi)" "128Mi → 128m"
assert_eq "1024m" "$(k8s_mem_to_docker 1Gi)"  "1Gi → 1024m"
assert_eq "64m"  "$(k8s_mem_to_docker 65536Ki)" "65536Ki → 64m"
assert_eq "512m" "$(k8s_mem_to_docker 512m)"  "512m (déjà Docker) → inchangé"
assert_eq "244m" "$(k8s_mem_to_docker 256M)"  "256M décimal → 244m (256 Mo = 244 MiB)"
assert_exit_code 1 "mémoire vide rejetée" -- k8s_mem_to_docker ""
assert_exit_code 1 "mémoire non numérique rejetée" -- k8s_mem_to_docker "plein"

finish
```

- [ ] **Step 2: Lancer le test et vérifier qu'il échoue**

```bash
bash engine/tests/run.sh test_units
```

Attendu : ÉCHEC — `engine/lib/units.sh: No such file or directory`.

- [ ] **Step 3: Écrire l'implémentation**

Créer `engine/lib/units.sh` :

```bash
#!/usr/bin/env bash
# engine/lib/units.sh — conversion des unités Kubernetes vers les unités Docker.
#
# Kubernetes exprime le CPU en millicores ("200m") et la mémoire en puissances
# de 2 ("128Mi"). Docker Compose veut des cœurs décimaux ("0.2") et un suffixe
# binaire minuscule ("128m" = 128 MiB).
#
# Les deux fonctions impriment le résultat sur stdout et renvoient 0 ; en cas
# d'entrée invalide elles n'impriment rien et renvoient 1 (à l'appelant de
# décider s'il applique un défaut ou s'il échoue).

# k8s_cpu_to_docker "200m" → "0.2"
k8s_cpu_to_docker() {
  local v="${1:-}"
  [[ -n "$v" ]] || return 1

  if [[ "$v" =~ ^([0-9]+)m$ ]]; then
    # Millicores → cœurs, avec 3 décimales puis nettoyage des zéros inutiles.
    local milli="${BASH_REMATCH[1]}"
    local out
    out=$(awk -v m="$milli" 'BEGIN { printf "%.3f", m / 1000 }')
    # Nettoyage des zéros de queue : 0.200 → 0.2, 2.000 → 2
    out=$(printf '%s' "$out" | sed -e 's/0*$//' -e 's/\.$//')
    printf '%s' "$out"
    return 0
  fi

  if [[ "$v" =~ ^[0-9]+$ ]] || [[ "$v" =~ ^[0-9]*\.[0-9]+$ ]]; then
    printf '%s' "$v"
    return 0
  fi

  return 1
}

# k8s_mem_to_docker "128Mi" → "128m"
k8s_mem_to_docker() {
  local v="${1:-}"
  [[ -n "$v" ]] || return 1

  local num unit mib
  if [[ "$v" =~ ^([0-9]+)(Ki|Mi|Gi|K|M|G|k|m|g)?$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]:-}"
  else
    return 1
  fi

  case "$unit" in
    Ki)      mib=$(( num / 1024 )) ;;
    Mi|m|"") mib="$num" ;;
    Gi|g)    mib=$(( num * 1024 )) ;;
    K|k)     mib=$(( num * 1000 / 1048576 )) ;;
    M)       mib=$(( num * 1000000 / 1048576 )) ;;
    G)       mib=$(( num * 1000000000 / 1048576 )) ;;
    *)       return 1 ;;
  esac

  (( mib < 6 )) && mib=6   # Docker refuse une limite mémoire sous 6 MiB
  printf '%sm' "$mib"
}
```

- [ ] **Step 4: Lancer le test et vérifier qu'il passe**

```bash
bash engine/tests/run.sh test_units
```

Attendu : 13 assertions ok. Ne modifier aucune assertion pour la faire passer : si une conversion diverge, c'est l'implémentation qui a tort. (`256M` vaut bien `244m` : `256 × 10⁶ ÷ 2²⁰ = 244`.)

- [ ] **Step 5: Commit**

```bash
git add engine/lib/units.sh engine/tests/test_units.sh
git commit -m "feat(engine): ajoute lib/units.sh pour convertir les unités k8s en unités Docker"
```

---

## Task 3: `lib/runtime.sh` — contrat de sortie et logs sur stderr

**Files:**
- Modify: `engine/lib/runtime.sh` (réécriture complète)
- Create: `engine/tests/test_runtime.sh`

**Interfaces:**
- Consumes: rien.
- Produces:
  - `emit_ok [JSON_OBJET]` → imprime `{"ok":true,"data":…}` sur stdout, **ne sort pas** du script (l'appelant décide).
  - `emit_fail MESSAGE` → imprime `{"ok":false,"error":"…"}` sur stdout.
  - `die MESSAGE [CODE]` → `emit_fail` puis `exit CODE` (défaut 2).
  - `retryable MESSAGE` → `emit_fail` puis `exit 1`.
  - `install_error_trap` → trap ERR qui appelle `die` avec le contexte.
  - Variable `_CURRENT_STEP`.

**Le point critique de cette tâche :** l'ancien `log_init()` redirigeait stdout ET stderr dans une process substitution qui préfixe chaque ligne d'un horodatage. Avec ça, la ligne JSON sortirait en `[14:32:01] {"ok":true…}` et serait inparsable. `log_init` est **supprimé** : le worker (jalon 2) capture stderr, l'engine ne gère plus de fichier de log.

- [ ] **Step 1: Écrire le test qui échoue**

Créer `engine/tests/test_runtime.sh` :

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

RT="$ENGINE_DIR/lib/runtime.sh"

# emit_ok imprime un JSON valide sur stdout, rien sur stderr
out=$(bash -c "source '$RT'; emit_ok '{\"port\":8080}'" 2>/dev/null)
assert_valid_json "$out" "emit_ok produit du JSON valide"
assert_eq "true"   "$(printf '%s' "$out" | jq -r .ok)"        "emit_ok → ok=true"
assert_eq "8080"   "$(printf '%s' "$out" | jq -r .data.port)" "emit_ok transporte data"

# emit_ok sans argument → data null
out=$(bash -c "source '$RT'; emit_ok" 2>/dev/null)
assert_eq "true" "$(printf '%s' "$out" | jq -r .ok)" "emit_ok sans data reste valide"

# une seule ligne sur stdout, quoi qu'il arrive
lines=$(bash -c "source '$RT'; ui_dummy() { :; }; emit_ok '{\"a\":1}'" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "1" "$lines" "emit_ok imprime exactement une ligne"

# emit_fail
out=$(bash -c "source '$RT'; emit_fail 'ça a cassé'" 2>/dev/null)
assert_eq "false"       "$(printf '%s' "$out" | jq -r .ok)"    "emit_fail → ok=false"
assert_eq "ça a cassé"  "$(printf '%s' "$out" | jq -r .error)" "emit_fail transporte le message"

# les guillemets dans un message ne cassent pas le JSON
out=$(bash -c "source '$RT'; emit_fail 'il a dit \"non\"'" 2>/dev/null)
assert_valid_json "$out" "emit_fail échappe les guillemets"

# die → code 2 par défaut, code personnalisable
assert_exit_code 2 "die sort en 2 par défaut" -- bash -c "source '$RT'; die 'fatal'"
assert_exit_code 1 "die accepte un code"      -- bash -c "source '$RT'; die 'souple' 1"
assert_exit_code 1 "retryable sort en 1"      -- bash -c "source '$RT'; retryable 'réessayable'"

# log_init ne doit plus exister
assert_not_contains "$(cat "$RT")" "log_init" "log_init a disparu de runtime.sh"

finish
```

- [ ] **Step 2: Lancer le test et vérifier qu'il échoue**

```bash
bash engine/tests/run.sh test_runtime
```

Attendu : ÉCHEC sur `emit_ok`, `emit_fail`, `die`, `retryable` (fonctions inexistantes) et sur l'assertion `log_init a disparu`.

- [ ] **Step 3: Réécrire `engine/lib/runtime.sh`**

```bash
#!/usr/bin/env bash
# engine/lib/runtime.sh — contrat de sortie de l'engine et trap d'erreur.
#
# CONTRAT (invariant du projet, cf. docs) :
#   - Les logs partent sur stderr, en clair, ligne par ligne.
#   - stdout ne reçoit QUE la ligne de résultat finale, en JSON.
#   - Codes de sortie : 0 succès, 1 échec réessayable, 2 échec fatal.
#
# Il n'y a plus de log_init() : l'engine n'écrit aucun fichier de log. C'est
# l'appelant (worker du panel, ou le shell interactif) qui capture stderr.
# Rediriger stdout comme le faisait l'ancien log_init corromprait la ligne JSON.

_CURRENT_STEP=""

# emit_ok [JSON_OBJET] — imprime le résultat de succès sur stdout.
# N'appelle pas exit : c'est l'étape qui décide de sa sortie.
emit_ok() {
  local data="${1:-null}"
  if ! printf '%s' "$data" | jq -e . >/dev/null 2>&1; then
    data="null"
  fi
  jq -cn --argjson data "$data" '{ok: true, data: $data}'
}

# emit_fail MESSAGE — imprime le résultat d'échec sur stdout.
emit_fail() {
  jq -cn --arg error "${1:-erreur inconnue}" '{ok: false, error: $error}'
}

# die MESSAGE [CODE] — échec fatal (défaut : 2, non réessayable).
die() {
  emit_fail "${1:-erreur fatale}"
  exit "${2:-2}"
}

# retryable MESSAGE — échec réessayable (code 1).
retryable() {
  emit_fail "${1:-erreur temporaire}"
  exit 1
}

# ----- Trap d'erreur global -------------------------------------------------
# Toute commande qui échoue sous `set -e` passe ici : on transforme la panne en
# résultat JSON pour que l'appelant n'ait jamais à parser du texte libre.
error_handler() {
  local exit_code=$?
  local line="$1"
  local cmd="$2"
  ui_err "Échec dans '${_CURRENT_STEP:-<engine>}' (ligne ${line}, exit=${exit_code})"
  ui_err "Commande : ${cmd}"
  emit_fail "étape '${_CURRENT_STEP:-inconnue}' : ${cmd} (ligne ${line}, exit ${exit_code})"
  exit 1
}

install_error_trap() {
  # `set -E` propage ERR aux fonctions et sous-shells. À appeler après `set -e`.
  set -E
  trap 'error_handler "$LINENO" "$BASH_COMMAND"' ERR
}
```

- [ ] **Step 4: Lancer le test et vérifier qu'il passe**

```bash
bash engine/tests/run.sh test_runtime
```

Attendu : 12 assertions ok. `error_handler` appelle `ui_err` qui vient de `ui.sh` (Task 5) ; dans le test, `runtime.sh` est sourcé seul, donc l'assertion sur `log_init` et les `emit_*` passent sans que `ui_err` soit appelé. Si un test déclenche `error_handler`, ajouter `ui_err() { printf '%s\n' "$*" >&2; }` en garde-fou en tête de `runtime.sh` — mais **ne pas l'ajouter préventivement**, `ui.sh` est toujours sourcé avant en conditions réelles.

- [ ] **Step 5: Commit**

```bash
git add engine/lib/runtime.sh engine/tests/test_runtime.sh
git commit -m "feat(engine): contrat de sortie JSON (emit_ok/emit_fail/die) et logs sur stderr"
```

---

## Task 4: `lib/config.sh` — lecture JSON et outil de migration

**Files:**
- Modify: `engine/lib/config.sh` (réécriture complète)
- Create: `engine/tools/migrate-env.sh`, `engine/tests/test_config.sh`, `engine/tests/fixtures/env.min.json`

**Interfaces:**
- Consumes: `die` (Task 3).
- Produces:
  - `cfg CHEMIN [DÉFAUT]` → valeur scalaire depuis `$ENV_JSON` (chemin pointé : `target.host`). Vide si absente et pas de défaut.
  - `cfg_req CHEMIN` → idem mais `die` en code 2 si absente ou vide.
  - `cfg_bool CHEMIN` → code 0 si la valeur est `true`, 1 sinon.
  - `cfg_port SERVICE_ID` → port hôte depuis `.ports[SERVICE_ID]`, `die` si absent ou < 1024.
  - Variables `ENV_JSON`, `SPEC_JSON` positionnées par `config_init WORKSPACE_DIR`.

- [ ] **Step 1: Écrire la fixture**

Créer `engine/tests/fixtures/env.min.json` :

```json
{
  "app": { "name": "demo-app", "author": "Testeur" },
  "target": {
    "host": "192.0.2.10",
    "user": "devops",
    "auth_method": "key",
    "ssh_key_path": "/tmp/fake_key",
    "password": "",
    "bind_addr": "0.0.0.0"
  },
  "registry": { "user": "reguser", "token": "tok\"avec\"guillemets" },
  "github": { "enabled": false, "user": "", "repo": "", "token": "" },
  "ports": { "api": 10001, "web": 10002, "trop_bas": 80 },
  "limits": { "cpu": "200m", "memory": "128Mi" },
  "options": { "reuse_existing_dir": true, "allow_existing_repo": false }
}
```

- [ ] **Step 2: Écrire le test qui échoue**

Créer `engine/tests/test_config.sh` :

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

RT="$ENGINE_DIR/lib/runtime.sh"
CF="$ENGINE_DIR/lib/config.sh"
FIX="$TESTS_DIR/fixtures/env.min.json"

run_cfg() { bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; $*" 2>/dev/null; }

assert_eq "demo-app"   "$(run_cfg 'cfg app.name')"        "cfg lit un chemin pointé"
assert_eq "192.0.2.10" "$(run_cfg 'cfg target.host')"     "cfg lit un chemin imbriqué"
assert_eq ""           "$(run_cfg 'cfg absent.total')"    "cfg renvoie vide si absent"
assert_eq "repli"      "$(run_cfg 'cfg absent.total repli')" "cfg applique le défaut"
assert_eq ""           "$(run_cfg 'cfg target.password')" "cfg renvoie vide sur chaîne vide"

# La valeur ne doit jamais être interprétée par le shell : c'est tout l'intérêt
# du passage au JSON. Un token contenant des guillemets doit ressortir intact.
assert_eq 'tok"avec"guillemets' "$(run_cfg 'cfg registry.token')" \
  "cfg ne réinterprète pas les guillemets"

# Une valeur contenant une substitution de commande doit ressortir littérale.
tmp=$(mktemp); printf '{"x":"$(touch /tmp/deploymatic_pwned)"}' > "$tmp"
bash -c "source '$RT'; source '$CF'; ENV_JSON='$tmp'; cfg x" >/dev/null 2>&1
assert_eq "0" "$([[ -f /tmp/deploymatic_pwned ]] && echo 1 || echo 0)" \
  "cfg n'exécute pas une substitution de commande présente dans la valeur"
rm -f "$tmp" /tmp/deploymatic_pwned

# cfg_req
assert_exit_code 0 "cfg_req passe quand la clé existe" -- \
  bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; cfg_req app.name"
assert_exit_code 2 "cfg_req meurt en code 2 si absente" -- \
  bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; cfg_req rien.du.tout"

# cfg_bool
assert_exit_code 0 "cfg_bool vrai"  -- \
  bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; cfg_bool options.reuse_existing_dir"
assert_exit_code 1 "cfg_bool faux"  -- \
  bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; cfg_bool options.allow_existing_repo"
assert_exit_code 1 "cfg_bool absent" -- \
  bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; cfg_bool github.enabled"

# cfg_port
assert_eq "10001" "$(run_cfg 'cfg_port api')" "cfg_port lit un port alloué"
assert_exit_code 2 "cfg_port refuse un port < 1024" -- \
  bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; cfg_port trop_bas"
assert_exit_code 2 "cfg_port meurt si le port est absent" -- \
  bash -c "source '$RT'; source '$CF'; ENV_JSON='$FIX'; cfg_port fantome"

# Plus aucune trace de l'ancien mécanisme
assert_not_contains "$(cat "$CF")" "ALL_VARS"  "ALL_VARS a disparu"
assert_not_contains "$(cat "$CF")" "source \"\$ENV_FILE\"" "plus de source du fichier d'env"

finish
```

- [ ] **Step 3: Lancer le test et vérifier qu'il échoue**

```bash
bash engine/tests/run.sh test_config
```

Attendu : ÉCHEC — `cfg: command not found` et les assertions `ALL_VARS a disparu` échouent.

- [ ] **Step 4: Réécrire `engine/lib/config.sh`**

```bash
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
```

- [ ] **Step 5: Lancer le test et vérifier qu'il passe**

```bash
bash engine/tests/run.sh test_config
```

Attendu : 17 assertions ok. Le test « n'exécute pas une substitution de commande » est le plus important du jalon : c'est lui qui prouve que la faille d'injection est fermée.

- [ ] **Step 6: Écrire l'outil de migration**

Créer `engine/tools/migrate-env.sh` :

```bash
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
```

- [ ] **Step 7: Tester la migration sur un cas réel**

```bash
chmod +x engine/tools/migrate-env.sh
printf '%s\n' \
  '# Généré automatiquement' \
  'APP_NAME="tp-app"' \
  'APP_AUTHOR="Alex"' \
  'OVH_HOST="1.2.3.4"' \
  'OVH_USER="devops"' \
  'OVH_AUTH_METHOD="key"' \
  'DOCKERHUB_USER="reg"' \
  'DOCKERHUB_TOKEN="a\"b"' \
  'API_PORT="3000"' \
  'APP_PORT="80"' > /tmp/old-env
bash engine/tools/migrate-env.sh /tmp/old-env /tmp/new-env.json
jq . /tmp/new-env.json
```

Attendu : JSON valide ; `registry.token` vaut exactement `a"b` ; `ports.api` vaut `3000` (≥1024, conservé) ; `ports.web` vaut `10002` (80 rejeté, remplacé par le défaut) ; `github.enabled` est `false` (pas de `GITHUB_USER`).

- [ ] **Step 8: Commit**

```bash
git add engine/lib/config.sh engine/tools/migrate-env.sh \
        engine/tests/test_config.sh engine/tests/fixtures/env.min.json
git commit -m "feat(engine): lecture de la configuration en JSON via jq, supprime la classe d'injection"
```

---

## Task 5: `lib/ui.sh` — messages sur stderr, suppression des prompts

**Files:**
- Modify: `engine/lib/ui.sh`
- Delete: `engine/lib/collect.sh`, `engine/lib/state.sh`, `engine/lib/workspace.sh`
- Modify: `engine/lib/prereqs.sh`

**Interfaces:**
- Consumes: rien.
- Produces: `ui_step`, `ui_info`, `ui_ok`, `ui_warn`, `ui_err`, `ui_skip` — tous vers **stderr**. `check_prereqs` (non-interactif, pure). Plus aucun `ui_prompt` / `ui_choose` / `ui_confirm` / `ensure_gum` / `gum_box`.

- [ ] **Step 1: Réécrire `engine/lib/ui.sh`**

```bash
#!/usr/bin/env bash
# engine/lib/ui.sh — messages de progression de l'engine.
#
# TOUT part sur stderr : stdout est réservé à la ligne de résultat JSON.
# Il n'y a plus de prompt : l'engine est non-interactif par construction, il
# est appelé par un worker sans TTY. Toute décision qui était un ui_confirm est
# devenue une clé d'env.json (cf. lib/config.sh) ou un échec fatal.
#
# gum a disparu avec les prompts. Les couleurs restent, elles ne coûtent rien
# et le worker les nettoie (ANSI strip) avant affichage.

readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'
readonly C_NAVY='\033[38;5;25m'
readonly C_GREEN='\033[38;5;35m'
readonly C_YELLOW='\033[38;5;214m'
readonly C_RED='\033[38;5;160m'
readonly C_BLUE='\033[38;5;39m'

ui_step() { printf '%b\n' "\n${C_NAVY}${C_BOLD}━━━ $* ━━━${C_RESET}" >&2; }
ui_info() { printf '%b\n' "${C_BLUE}ℹ${C_RESET}  $*" >&2; }
ui_ok()   { printf '%b\n' "${C_GREEN}✓${C_RESET}  $*" >&2; }
ui_warn() { printf '%b\n' "${C_YELLOW}⚠${C_RESET}  $*" >&2; }
ui_err()  { printf '%b\n' "${C_RED}✗${C_RESET}  $*" >&2; }
ui_skip() { printf '%b\n' "${C_DIM}↷  $* (sauté)${C_RESET}" >&2; }
```

- [ ] **Step 2: Supprimer les modules devenus morts**

```bash
git rm engine/lib/collect.sh engine/lib/state.sh engine/lib/workspace.sh
```

Justification à mettre dans le message de commit : `collect.sh` était la collecte interactive (remplacée par `env.json`), `state.sh` le suivi d'état sur fichier (remplacé par la table `Step` au jalon 2), `workspace.sh` la gestion du cycle de vie des workspaces (remonte au panel).

- [ ] **Step 3: Rendre `check_prereqs` non-interactif**

Réécrire `engine/lib/prereqs.sh` en entier :

```bash
#!/usr/bin/env bash
# engine/lib/prereqs.sh — vérification des outils requis côté engine.
#
# Non-interactif : aucune installation, aucun prompt. L'engine tourne dans un
# conteneur worker (jalon 2) où l'image apporte ses dépendances ; si un outil
# manque, c'est une erreur de build d'image, pas quelque chose à réparer à chaud.

check_prereqs() {
  local required=("git" "ssh" "scp" "curl" "jq" "docker")
  local missing=() tool

  for tool in "${required[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      ui_ok "${tool} présent"
    else
      ui_err "${tool} manquant (requis)"
      missing+=("$tool")
    fi
  done

  # docker compose est un plugin, pas un binaire du PATH.
  if docker compose version >/dev/null 2>&1; then
    ui_ok "docker compose présent"
  else
    ui_err "plugin 'docker compose' manquant (requis)"
    missing+=("docker-compose-plugin")
  fi

  # gh n'est requis que si le bloc GitHub est activé.
  if cfg_bool github.enabled; then
    if command -v gh >/dev/null 2>&1; then
      ui_ok "gh présent (github.enabled=true)"
    else
      ui_err "gh manquant alors que github.enabled=true"
      missing+=("gh")
    fi
  else
    ui_skip "gh non vérifié (github.enabled=false)"
  fi

  # sshpass n'est requis qu'en authentification par mot de passe.
  if [[ "$(cfg target.auth_method key)" == "password" ]]; then
    if command -v sshpass >/dev/null 2>&1; then
      ui_ok "sshpass présent (auth par mot de passe)"
    else
      ui_err "sshpass manquant alors que target.auth_method=password"
      missing+=("sshpass")
    fi
  fi

  if (( ${#missing[@]} > 0 )); then
    die "outils manquants : ${missing[*]}" 2
  fi

  emit_ok "$(jq -cn --argjson n "${#required[@]}" '{checked: $n}')"
}
```

Noter la disparition de `gh auth login` (interactif, bloquant dans un worker) et de `ensure_sshpass` (installation interactive). `kubectl` et `gum` disparaissent de la liste.

- [ ] **Step 4: Vérifier qu'aucun prompt ne subsiste**

```bash
grep -rn "ui_confirm\|ui_prompt\|ui_choose\|ensure_gum\|gum \|read -r\|gh auth login" engine/lib/ engine/bootstrap.sh
```

Attendu : aucune sortie. Si `engine/bootstrap.sh` ou `engine/lib/steps.sh` en contiennent encore, les laisser pour les Tasks 6 et 11 qui les traitent — mais **noter la liste** pour vérifier qu'elle est vide à la Task 15.

- [ ] **Step 5: Commit**

```bash
git add -A engine/lib
git commit -m "refactor(engine): messages sur stderr, supprime les prompts interactifs et les modules morts"
```

---

## Task 6: Dispatcher `engine/bootstrap.sh`

**Files:**
- Modify: `engine/bootstrap.sh` (réécriture complète)
- Create: `engine/tests/test_dispatcher.sh`

**Interfaces:**
- Consumes: `config_init`, `install_error_trap`, `die`, `emit_ok`, tout `lib/`.
- Produces: la CLI `engine/bootstrap.sh --workspace <ws> {--step <nom> | --all | --list-steps} [--dry-run]`. Variables globales exportées vers les étapes : `WS_NAME`, `WS_DIR`, `WORK_DIR`, `APP_NAME`, `DRY_RUN`.

- [ ] **Step 1: Écrire le test qui échoue**

Créer `engine/tests/test_dispatcher.sh` :

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

BS="$ENGINE_DIR/bootstrap.sh"

# --list-steps ne nécessite pas de workspace
out=$(bash "$BS" --list-steps 2>/dev/null)
assert_contains "$out" "generate_compose" "--list-steps mentionne generate_compose"
assert_contains "$out" "deploy_stack"     "--list-steps mentionne deploy_stack"
assert_not_contains "$out" "kubeconfig"   "--list-steps ne mentionne plus le kubeconfig"

# Noms de workspace : la défense en profondeur contre la traversée de chemin
assert_exit_code 2 "refuse un workspace avec ../" -- \
  bash "$BS" --workspace "../../etc" --step check_prereqs
assert_exit_code 2 "refuse un workspace avec /" -- \
  bash "$BS" --workspace "a/b" --step check_prereqs
assert_exit_code 2 "refuse un workspace vide" -- \
  bash "$BS" --workspace "" --step check_prereqs

# Étape inconnue → code 2, et une ligne JSON quand même
out=$(bash "$BS" --workspace demo --step etape_qui_nexiste_pas 2>/dev/null)
assert_valid_json "$out" "une étape inconnue produit tout de même du JSON"
assert_eq "false" "$(printf '%s' "$out" | jq -r .ok)" "étape inconnue → ok=false"

# env.json manquant → code 2, JSON sur stdout
rm -rf "$REPO_ROOT/runs/_test_dispatch"
mkdir -p "$REPO_ROOT/runs/_test_dispatch"
out=$(bash "$BS" --workspace _test_dispatch --step check_prereqs 2>/dev/null)
assert_valid_json "$out" "env.json manquant produit du JSON"
assert_contains "$(printf '%s' "$out" | jq -r .error)" "env.json" \
  "le message d'erreur nomme env.json"

# Un workspace valide avec une fixture : stdout doit tenir sur UNE ligne
cp "$TESTS_DIR/fixtures/env.min.json" "$REPO_ROOT/runs/_test_dispatch/env.json"
lines=$(bash "$BS" --workspace _test_dispatch --step check_prereqs 2>/dev/null | wc -l | tr -d ' ')
assert_eq "1" "$lines" "une étape imprime exactement une ligne sur stdout"

# --dry-run n'exécute rien mais reste contractuel
out=$(bash "$BS" --workspace _test_dispatch --step validate_ssh --dry-run 2>/dev/null)
assert_valid_json "$out" "--dry-run produit du JSON"
assert_eq "true" "$(printf '%s' "$out" | jq -r .ok)" "--dry-run réussit sans rien faire"

rm -rf "$REPO_ROOT/runs/_test_dispatch"
finish
```

- [ ] **Step 2: Lancer le test et vérifier qu'il échoue**

```bash
bash engine/tests/run.sh test_dispatcher
```

Attendu : ÉCHEC — l'ancien `bootstrap.sh` ne connaît ni `--step` ni `--list-steps`.

- [ ] **Step 3: Réécrire `engine/bootstrap.sh`**

```bash
#!/usr/bin/env bash
# =============================================================================
#  engine/bootstrap.sh — exécuteur d'étapes de DeployMatic.
#
#  Ce script ne décide plus de rien. Il exécute UNE étape qu'on lui nomme, avec
#  les paramètres qu'on lui donne en JSON. La séquence des étapes et le suivi
#  d'avancement vivent côté panel (jalon 2) ; le mode --all n'existe que pour
#  pouvoir tester l'engine seul.
#
#  Usage :
#    bootstrap.sh --workspace <ws> --step <nom>    exécute une étape
#    bootstrap.sh --workspace <ws> --all           exécute toute la séquence
#    bootstrap.sh --list-steps                     liste les étapes connues
#    bootstrap.sh --workspace <ws> --step <nom> --dry-run
#
#  Entrées  : runs/<ws>/env.json et runs/<ws>/spec.json
#  Sortie   : logs sur stderr, UNE ligne JSON sur stdout
#  Codes    : 0 succès, 1 échec réessayable, 2 échec fatal
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT
readonly RUNS_DIR="${REPO_ROOT}/runs"

# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/runtime.sh
source "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=lib/units.sh
source "$SCRIPT_DIR/lib/units.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/ssh_remote.sh
source "$SCRIPT_DIR/lib/ssh_remote.sh"
# shellcheck source=lib/prereqs.sh
source "$SCRIPT_DIR/lib/prereqs.sh"
# shellcheck source=lib/steps.sh
source "$SCRIPT_DIR/lib/steps.sh"
# shellcheck source=lib/diag.sh
source "$SCRIPT_DIR/lib/diag.sh"

# ----- Séquence d'étapes ----------------------------------------------------
# Ordre utilisé par --all uniquement. La séquence de référence vit côté panel.
# Le bloc GitHub est en fin de liste : une panne GitHub ne doit jamais empêcher
# un déploiement d'aboutir.
STEPS=(
  check_prereqs
  validate_ssh
  create_project_dir
  generate_microservices
  generate_compose
  generate_skills
  generate_workflow
  enable_sudo_nopasswd
  prepare_server
  build_images
  deploy_stack
  validate_deployment
  github_create_repo
  github_set_secrets
  git_init
  git_push
)

# ----- Parsing des arguments ------------------------------------------------
WS_NAME=""
STEP_NAME=""
MODE=""
DRY_RUN=0

while (( $# > 0 )); do
  case "$1" in
    --workspace|-w) WS_NAME="${2:-}"; shift 2 ;;
    --step)         STEP_NAME="${2:-}"; MODE="step"; shift 2 ;;
    --all)          MODE="all"; shift ;;
    --list-steps)   MODE="list"; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --help|-h)      MODE="help"; shift ;;
    *)
      printf 'Argument inconnu : %s\n' "$1" >&2
      die "argument inconnu : $1" 2
      ;;
  esac
done

# ----- Modes sans workspace -------------------------------------------------
case "$MODE" in
  list)
    printf '%s\n' "${STEPS[@]}"
    exit 0
    ;;
  help)
    sed -n '2,20p' "$0" | sed 's/^#  \{0,1\}//'
    exit 0
    ;;
esac

# ----- Validation du nom de workspace ---------------------------------------
# Défense en profondeur : le panel valide déjà (jalon 2), mais l'engine ne fait
# jamais confiance à son appelant. C'est ce qui ferme --workspace ../../etc.
if [[ ! "$WS_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$ ]]; then
  die "nom de workspace invalide : '${WS_NAME}' (attendu : ^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$)" 2
fi

WS_DIR="${RUNS_DIR}/${WS_NAME}"
[[ -d "$WS_DIR" ]] || die "workspace inexistant : ${WS_DIR}" 2

config_init "$WS_DIR"

APP_NAME="$(cfg_req app.name)"
WORK_DIR="${WS_DIR}/${APP_NAME}"
export WS_NAME WS_DIR WORK_DIR APP_NAME DRY_RUN

# ----- Exécution ------------------------------------------------------------
install_error_trap

step_exists() {
  local candidate="$1" s
  for s in "${STEPS[@]}"; do
    [[ "$s" == "$candidate" ]] && return 0
  done
  return 1
}

run_one_step() {
  local name="$1"
  step_exists "$name" || die "étape inconnue : ${name} (voir --list-steps)" 2
  declare -F "step_${name}" >/dev/null \
    || die "étape déclarée mais non implémentée : step_${name}" 2

  _CURRENT_STEP="$name"
  ui_step "$name"
  "step_${name}"
}

case "$MODE" in
  step)
    [[ -n "$STEP_NAME" ]] || die "--step requiert un nom d'étape" 2
    run_one_step "$STEP_NAME"
    ;;
  all)
    # Mode de test de l'engine seul : chaque étape imprime sa ligne JSON, donc
    # stdout contient N lignes. C'est une entorse assumée au contrat, réservée
    # à --all, qui n'est jamais appelé par le panel.
    ui_warn "--all : mode de test, stdout contiendra une ligne JSON par étape"
    for s in "${STEPS[@]}"; do
      run_one_step "$s"
    done
    ;;
  *)
    die "préciser --step <nom>, --all ou --list-steps" 2
    ;;
esac
```

- [ ] **Step 4: Lancer le test et vérifier qu'il passe**

```bash
bash engine/tests/run.sh test_dispatcher
```

Attendu : les assertions sur `--list-steps`, les noms de workspace et le JSON passent. Celles qui exécutent réellement `check_prereqs` et `validate_ssh` dépendent des Tasks 5 et 11 : si `steps.sh` n'a pas encore `step_validate_ssh`, l'assertion `--dry-run` échouera. **C'est attendu** — la relancer à la fin de la Task 11.

- [ ] **Step 5: Commit**

```bash
git add engine/bootstrap.sh engine/tests/test_dispatcher.sh
git commit -m "feat(engine): remplace le pipeline par un dispatcher --step piloté par JSON"
```

---

## Task 7: Spécification d'application et helpers de lecture

**Files:**
- Create: `engine/templates/spec.demo.json`, `engine/tests/fixtures/spec.multi.json`
- Modify: `engine/lib/config.sh` (ajout des helpers `spec_*`)

**Interfaces:**
- Consumes: `SPEC_JSON` (Task 4), `die`.
- Produces:
  - `spec_init` → vérifie l'existence et la validité de `spec.json`, `die` en 2 sinon.
  - `spec_service_ids` → un id de service par ligne.
  - `spec_get SERVICE_ID CHAMP [DÉFAUT]` → valeur scalaire d'un champ de service.
  - `spec_is_internal SERVICE_ID` → code 0 si `internal == true`.
  - `spec_is_exposed SERVICE_ID` → code 0 si le service a un `expose` non vide.
  - `spec_exposed_ids_by_path_length` → ids exposés, triés par longueur de chemin **décroissante** (le plus spécifique d'abord — utile dès maintenant pour l'ordre des règles, et indispensable au jalon 4 pour BunkerWeb).

- [ ] **Step 1: Écrire `engine/templates/spec.demo.json`**

```json
{
  "name": "tp-app",
  "services": [
    {
      "id": "api",
      "build": "./services/api",
      "port": 3000,
      "health": "/health",
      "expose": "/api/",
      "env": { "NODE_ENV": "production" }
    },
    {
      "id": "web",
      "build": "./services/web",
      "port": 8080,
      "health": "/",
      "expose": "/"
    }
  ]
}
```

Noter : `port` est le port CONTENEUR. Le port hôte vient d'`env.json`. `health` est le chemin interrogé **dans le conteneur**, donc `/health` pour l'API (pas `/api/health` : le préfixe est retiré par le reverse proxy en amont).

- [ ] **Step 2: Écrire la fixture multi-services**

Créer `engine/tests/fixtures/spec.multi.json` — même forme, plus un service interne, pour prouver que le squelette compose ne s'applique pas uniformément :

```json
{
  "name": "multi-app",
  "services": [
    { "id": "api", "build": "./services/api", "port": 3000,
      "health": "/health", "expose": "/api/",
      "env": { "NODE_ENV": "production", "DB_HOST": "db" } },
    { "id": "web", "build": "./services/web", "port": 8080,
      "health": "/", "expose": "/" },
    { "id": "db", "image": "postgres:16-alpine", "internal": true,
      "env": { "POSTGRES_PASSWORD": "changeme" },
      "volumes": ["pgdata:/var/lib/postgresql/data"] }
  ]
}
```

- [ ] **Step 3: Écrire le test qui échoue**

Ajouter à la fin de `engine/tests/test_config.sh`, **avant** l'appel à `finish` :

```bash
# ----- Helpers de lecture du spec -----------------------------------------
SPEC="$TESTS_DIR/fixtures/spec.multi.json"
run_spec() { bash -c "source '$RT'; source '$CF'; SPEC_JSON='$SPEC'; $*" 2>/dev/null; }

assert_eq "api web db" "$(run_spec 'spec_service_ids' | tr '\n' ' ' | sed 's/ $//')" \
  "spec_service_ids liste les trois services"
assert_eq "3000"  "$(run_spec 'spec_get api port')"           "spec_get lit le port conteneur"
assert_eq "/api/" "$(run_spec 'spec_get api expose')"         "spec_get lit expose"
assert_eq "postgres:16-alpine" "$(run_spec 'spec_get db image')" "spec_get lit image"
assert_eq "repli" "$(run_spec 'spec_get web image repli')"    "spec_get applique le défaut"

assert_exit_code 0 "db est interne"      -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$SPEC'; spec_is_internal db"
assert_exit_code 1 "api n'est pas interne" -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$SPEC'; spec_is_internal api"
assert_exit_code 0 "api est exposé"      -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$SPEC'; spec_is_exposed api"
assert_exit_code 1 "db n'est pas exposé"  -- \
  bash -c "source '$RT'; source '$CF'; SPEC_JSON='$SPEC'; spec_is_exposed db"

# Le plus spécifique d'abord : /api/ (5 caractères) avant / (1 caractère)
assert_eq "api web" \
  "$(run_spec 'spec_exposed_ids_by_path_length' | tr '\n' ' ' | sed 's/ $//')" \
  "les chemins exposés sont triés du plus spécifique au plus général"
```

- [ ] **Step 4: Lancer le test et vérifier qu'il échoue**

```bash
bash engine/tests/run.sh test_config
```

Attendu : les assertions précédentes passent, les 10 nouvelles échouent (`spec_service_ids: command not found`).

- [ ] **Step 5: Ajouter les helpers à `engine/lib/config.sh`**

Ajouter à la fin du fichier :

```bash
# ----- Lecture du spec d'application ---------------------------------------
# spec.json décrit les services de l'application déployée. Il remplace le
# couple "api + web" codé en dur : une app générée par IA (jalon 5) n'aura pas
# toujours cette forme.

spec_init() {
  [[ -f "$SPEC_JSON" ]] || die "spec.json introuvable : ${SPEC_JSON}" 2
  jq -e . "$SPEC_JSON" >/dev/null 2>&1 || die "spec.json n'est pas du JSON valide" 2
  jq -e '.services | type == "array" and length > 0' "$SPEC_JSON" >/dev/null 2>&1 \
    || die "spec.json doit contenir un tableau 'services' non vide" 2
  local dupes
  dupes=$(jq -r '[.services[].id] | group_by(.) | map(select(length > 1) | .[0]) | join(",")' "$SPEC_JSON")
  [[ -z "$dupes" ]] || die "ids de service dupliqués dans spec.json : ${dupes}" 2
}

spec_service_ids() {
  jq -r '.services[].id' "$SPEC_JSON"
}

# spec_get SERVICE_ID CHAMP [DÉFAUT]
spec_get() {
  local sid="${1:?}" field="${2:?}" default="${3:-}"
  local value
  value=$(jq -r --arg s "$sid" --arg f "$field" '
    .services[] | select(.id == $s) | .[$f] // empty
    | if type == "boolean" or type == "number" then tostring else . end
  ' "$SPEC_JSON" 2>/dev/null || printf '')
  if [[ -z "$value" ]]; then printf '%s' "$default"; else printf '%s' "$value"; fi
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
```

- [ ] **Step 6: Lancer le test et vérifier qu'il passe**

```bash
bash engine/tests/run.sh test_config
```

Attendu : 27 assertions ok.

- [ ] **Step 7: Commit**

```bash
git add engine/lib/config.sh engine/templates/spec.demo.json \
        engine/tests/fixtures/spec.multi.json engine/tests/test_config.sh
git commit -m "feat(engine): schéma spec.json et helpers de lecture des services"
```

---

## Task 8: `lib/gen_compose.sh` — génération du Compose

**Files:**
- Create: `engine/lib/gen_compose.sh`, `engine/tests/test_gen_compose.sh`
- Delete: `engine/lib/gen_manifests.sh`

**Interfaces:**
- Consumes: `spec_*` et `cfg_*` (Tasks 4 et 7), `k8s_cpu_to_docker` / `k8s_mem_to_docker` (Task 2).
- Produces: dans `$WORK_DIR` — `deploy/compose.yml`, `deploy/.env`, `deploy/.env.example`. Appelé par `step_generate_compose` (Task 11).

**Les deux pièges de cette tâche :**
1. `${IMAGE_TAG}` doit arriver **littéral** dans le YAML pour que Compose l'interpole depuis `deploy/.env`. Dans un heredoc non quoté (`<<EOF`), bash le mangerait. On échappe en `\${IMAGE_TAG}`.
2. Le squelette durci **ne s'applique pas uniformément**. Un `postgres:16-alpine` avec `user: "1000:1000"` et `read_only: true` ne démarre pas : il tourne en uid 70 et doit posséder son datadir. Deux squelettes distincts : services buildés, et services `image:` internes.

- [ ] **Step 1: Écrire le test qui échoue**

Créer `engine/tests/test_gen_compose.sh` :

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ENV_FIX="$TESTS_DIR/fixtures/env.min.json"
SPEC_FIX="$TESTS_DIR/fixtures/spec.multi.json"

# La fixture n'a pas de port pour "db" — normal, il est interne.
bash -c "
  source '$ENGINE_DIR/lib/ui.sh'
  source '$ENGINE_DIR/lib/runtime.sh'
  source '$ENGINE_DIR/lib/units.sh'
  source '$ENGINE_DIR/lib/config.sh'
  ENV_JSON='$ENV_FIX'; SPEC_JSON='$SPEC_FIX'
  WORK_DIR='$WORK'; APP_NAME='multi-app'
  source '$ENGINE_DIR/lib/gen_compose.sh'
  gen_compose
" >/dev/null 2>&1

CY="$WORK/deploy/compose.yml"
assert_eq "1" "$([[ -f "$CY" ]] && echo 1 || echo 0)" "deploy/compose.yml est créé"
assert_eq "1" "$([[ -f "$WORK/deploy/.env" ]] && echo 1 || echo 0)" "deploy/.env est créé"
assert_eq "1" "$([[ -f "$WORK/deploy/.env.example" ]] && echo 1 || echo 0)" "deploy/.env.example est créé"

body=$(cat "$CY")

# IMAGE_TAG doit rester littéral pour que Compose l'interpole
assert_contains "$body" '${IMAGE_TAG}' "IMAGE_TAG reste littéral dans le YAML"
assert_eq "IMAGE_TAG=latest" "$(head -1 "$WORK/deploy/.env")" "deploy/.env fixe IMAGE_TAG=latest"

# Ports : hôte:conteneur, hôte pris dans env.json, conteneur dans spec.json
assert_contains "$body" '0.0.0.0:10001:3000' "api publie port_hôte:port_conteneur"
assert_contains "$body" '0.0.0.0:10002:8080' "web publie port_hôte:port_conteneur"

# Le service interne ne publie AUCUN port
db_block=$(awk '/^  db:/{f=1} f && /^  [a-z]/ && !/^  db:/{f=0} f' "$CY")
assert_not_contains "$db_block" "ports:" "un service interne ne publie aucun port"

# Durcissement sur les services buildés uniquement
api_block=$(awk '/^  api:/{f=1} f && /^  [a-z]/ && !/^  api:/{f=0} f' "$CY")
assert_contains "$api_block" 'user: "1000:1000"'          "service buildé : user non-root"
assert_contains "$api_block" 'read_only: true'            "service buildé : read_only"
assert_contains "$api_block" 'no-new-privileges:true'     "service buildé : no-new-privileges"
assert_contains "$api_block" 'healthcheck:'               "service buildé : healthcheck"
assert_not_contains "$db_block" 'read_only: true'         "service image interne : pas de read_only"
assert_not_contains "$db_block" 'user: "1000:1000"'       "service image interne : pas de user forcé"

# Conversion des unités
assert_contains "$body" "cpus: \"0.2\"" "limite CPU convertie de 200m"
assert_contains "$body" "memory: 128m"  "limite mémoire convertie de 128Mi"

# Interdits absolus
assert_not_contains "$body" "network_mode"      "pas de network_mode"
assert_not_contains "$body" "/var/run/docker.sock" "pas de montage du socket Docker"
assert_not_contains "$body" "privileged"        "pas de privileged"

# Réseau dédié et volume déclaré
assert_contains "$body" "networks:"  "un réseau est déclaré"
assert_contains "$body" "pgdata:"    "le volume nommé du spec est déclaré"

# Compose lui-même doit accepter le fichier
if command -v docker >/dev/null 2>&1; then
  rc=0
  (cd "$WORK/deploy" && docker compose config --quiet) >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "docker compose config --quiet accepte le fichier généré"
else
  printf '  (docker absent — validation compose sautée)\n'
fi

finish
```

- [ ] **Step 2: Lancer le test et vérifier qu'il échoue**

```bash
bash engine/tests/run.sh test_gen_compose
```

Attendu : ÉCHEC — `deploy/compose.yml` n'est pas créé.

- [ ] **Step 3: Écrire `engine/lib/gen_compose.sh`**

```bash
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
```

- [ ] **Step 4: Supprimer le générateur Kubernetes**

```bash
git rm engine/lib/gen_manifests.sh
```

- [ ] **Step 5: Lancer le test et vérifier qu'il passe**

```bash
bash engine/tests/run.sh test_gen_compose
```

Attendu : 22 assertions ok, dont `docker compose config --quiet` (docker est présent sur cette machine). Si `docker compose config` râle sur `build.context` parce que `../services/api` n'existe pas dans le tmpdir, **c'est un vrai signal** : ajouter `mkdir -p "$WORK/services/api" "$WORK/services/web"` dans le test avant l'appel à `gen_compose`.

- [ ] **Step 6: Commit**

```bash
git add engine/lib/gen_compose.sh engine/tests/test_gen_compose.sh
git rm --cached engine/lib/gen_manifests.sh 2>/dev/null || true
git commit -m "feat(engine): génère deploy/compose.yml depuis spec.json, remplace les manifests k8s"
```

---

## Task 9: `lib/gen_microservices.sh` — front nginx non privilégié

**Files:**
- Modify: `engine/lib/gen_microservices.sh`
- Create: `engine/tests/test_gen_micro.sh`

**Interfaces:**
- Consumes: `spec_*`, `cfg_*`.
- Produces: dans `$WORK_DIR/services/<id>/` les sources et le Dockerfile de chaque service buildé. **Le chemin change** : `microservices/` devient `services/`, pour coller au `build: "./services/api"` du spec.

**Le piège :** le front tournait sur nginx port 80 avec `runAsUser: 1000` — impossible de binder un port privilégié en non-root. On bascule sur `nginxinc/nginx-unprivileged`, qui écoute sur 8080 et n'a pas besoin de root. Combiné à `read_only: true`, il faut les tmpfs `/tmp`, `/var/run` et `/var/cache/nginx` (déjà posés en Task 8).

- [ ] **Step 1: Écrire le test qui échoue**

Créer `engine/tests/test_gen_micro.sh` :

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

bash -c "
  source '$ENGINE_DIR/lib/ui.sh'
  source '$ENGINE_DIR/lib/runtime.sh'
  source '$ENGINE_DIR/lib/config.sh'
  ENV_JSON='$TESTS_DIR/fixtures/env.min.json'
  SPEC_JSON='$ENGINE_DIR/templates/spec.demo.json'
  WORK_DIR='$WORK'; APP_NAME='tp-app'
  source '$ENGINE_DIR/lib/gen_microservices.sh'
  gen_microservices
" >/dev/null 2>&1

assert_eq "1" "$([[ -f "$WORK/services/api/server.js" ]] && echo 1 || echo 0)" \
  "l'API est générée sous services/api/"
assert_eq "1" "$([[ -f "$WORK/services/web/Dockerfile" ]] && echo 1 || echo 0)" \
  "le front est généré sous services/web/"
assert_eq "0" "$([[ -d "$WORK/microservices" ]] && echo 1 || echo 0)" \
  "plus de répertoire microservices/"

web_df=$(cat "$WORK/services/web/Dockerfile")
assert_contains "$web_df" "nginxinc/nginx-unprivileged" "le front utilise nginx-unprivileged"
assert_not_contains "$web_df" "FROM nginx:alpine" "plus de nginx:alpine privilégié"
assert_contains "$web_df" "EXPOSE 8080" "le front expose 8080, pas 80"

api_srv=$(cat "$WORK/services/api/server.js")
assert_contains "$api_srv" "process.env.PORT" "l'API lit son port depuis PORT"

api_df=$(cat "$WORK/services/api/Dockerfile")
assert_contains "$api_df" "USER node" "l'API tourne en utilisateur non-root"

nginx_conf=$(cat "$WORK/services/web/nginx.conf")
assert_contains "$nginx_conf" "listen       8080" "la conf nginx écoute sur 8080"

finish
```

- [ ] **Step 2: Lancer le test et vérifier qu'il échoue**

```bash
bash engine/tests/run.sh test_gen_micro
```

Attendu : ÉCHEC — le générateur est encore un script autonome qui écrit dans `microservices/`.

- [ ] **Step 3: Convertir `gen_microservices.sh` en module sourcé**

Le fichier actuel est un script autonome (`set -euo pipefail` + arguments positionnels). Le transformer en module exposant `gen_microservices()`. Modifications à apporter :

1. Remplacer l'en-tête (lignes 1-20) par une définition de fonction :

```bash
#!/usr/bin/env bash
# engine/lib/gen_microservices.sh — génère les sources de l'application de démo.
#
# Sourcé par lib/steps.sh (plus exécuté en sous-processus : il a besoin des
# helpers spec_*/cfg_*).
#
# Écrit dans $WORK_DIR/services/<id>/ — le chemin correspond au "build" du
# spec ("./services/api"). L'ancien répertoire microservices/ disparaît.

gen_microservices() {
  spec_init

  local author; author="$(cfg app.author "$APP_NAME")"
  local api_port; api_port="$(spec_get api port 3000)"
  local web_port; web_port="$(spec_get web port 8080)"

  mkdir -p "$WORK_DIR/services/api" "$WORK_DIR/services/web"
  # … suite du corps existant, avec $WORK_DIR/services/… au lieu de
  #   $WORK_DIR/microservices/…
}
```

2. Remplacer partout `$WORK_DIR/microservices/` par `$WORK_DIR/services/`.
3. Remplacer `$APP_AUTHOR` par `$author`, `$API_PORT` par `$api_port`, `$APP_PORT` par `$web_port`.
4. Remplacer les trois `echo` finaux (lignes 313-315) par des `ui_ok "…"` — ils écrivaient sur stdout, ce qui casserait le contrat.
5. Fermer la fonction par `}`.

- [ ] **Step 4: Basculer le front sur nginx-unprivileged**

Remplacer le bloc conditionnel Dockerfile/nginx.conf (lignes 109-121 et 255-268 de l'original) par un bloc unique, sans condition — le front écoute **toujours** sur 8080 :

```bash
  # nginx-unprivileged écoute sur 8080 et tourne en uid 101 sans root. C'est
  # ce qui permet le user non-root et le read_only du compose ; nginx:alpine
  # voulait binder le port 80, impossible sans privilège.
  cat > "$WORK_DIR/services/web/nginx.conf" <<EOF
server {
    listen       ${web_port};
    server_name  _;
    root         /usr/share/nginx/html;
    index        index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  cat > "$WORK_DIR/services/web/Dockerfile" <<EOF
FROM nginxinc/nginx-unprivileged:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
EXPOSE ${web_port}
EOF
```

- [ ] **Step 5: Rendre le port de l'API pilotable**

Dans le `server.js` généré, la ligne `const PORT = process.env.PORT || ${API_PORT};` devient `const PORT = process.env.PORT || ${api_port};`. Le compose injecte déjà `PORT` (Task 8) — c'est cohérent avec le contrat d'application du jalon 5.

- [ ] **Step 6: Lancer le test et vérifier qu'il passe**

```bash
bash engine/tests/run.sh test_gen_micro
```

Attendu : 9 assertions ok.

- [ ] **Step 7: Commit**

```bash
git add engine/lib/gen_microservices.sh engine/tests/test_gen_micro.sh
git commit -m "feat(engine): front nginx non privilégié sur 8080, sources sous services/"
```

---

## Task 10: `lib/prepare_server.sh` — provisioning Docker

**Files:**
- Modify: `engine/lib/prepare_server.sh`

**Interfaces:**
- Consumes: variable d'environnement `REGISTRY_USER` et stdin pour le token (passés par `step_prepare_server`, Task 11).
- Produces: un serveur avec docker-ce, docker-compose-plugin, ufw (22 seul), fail2ban, MOTD.

Ce script s'exécute **sur la cible**, envoyé par `ssh … bash -s`. Il n'a accès ni à `jq` localement ni aux helpers de l'engine. Il garde ses propres `log`/`ok`/`warn` sur stderr.

- [ ] **Step 1: Retirer tout Kubernetes**

Supprimer les sections 3 (k3s), 4 (kubectl), 5 (Helm), 6 (metrics-server) et 7 (cert-manager) — lignes 46-127 de l'original.

- [ ] **Step 2: Rendre l'installation Docker inconditionnelle et ajouter le plugin compose**

Remplacer la section 2 par :

```bash
# ----- 2. Docker CE + plugin Compose ----------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installation de Docker…"

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  sudo usermod -aG docker "$USER"
  ok "Docker installé"
else
  ok "Docker déjà installé ($(docker --version))"
fi

# Le plugin compose peut manquer sur une install Docker plus ancienne.
if ! docker compose version >/dev/null 2>&1; then
  log "Installation du plugin docker compose…"
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-compose-plugin
fi
ok "docker compose : $(docker compose version --short 2>/dev/null || echo inconnu)"
```

- [ ] **Step 3: Corriger le pare-feu**

L'hôte cible n'est plus exposé directement : BunkerWeb est le seul point d'entrée public, et il n'atteint les applications que par les ports alloués (ouverts au jalon 3, source restreinte). Remplacer la section ufw :

```bash
# ----- 3. UFW ---------------------------------------------------------------
# Seul SSH reste ouvert. Les ports applicatifs sont ouverts un par un par
# l'étape open_firewall_ports (jalon 3), et uniquement depuis l'IP BunkerWeb.
# 80/443 ne sont plus ouverts : l'hôte cible n'est plus joignable publiquement.
# 6443 disparaît avec k3s.
if command -v ufw >/dev/null 2>&1; then
  sudo ufw --force default deny incoming
  sudo ufw --force default allow outgoing
  sudo ufw allow 22/tcp comment "SSH"
  sudo ufw delete allow 80/tcp   >/dev/null 2>&1 || true
  sudo ufw delete allow 443/tcp  >/dev/null 2>&1 || true
  sudo ufw delete allow 6443/tcp >/dev/null 2>&1 || true
  sudo ufw --force enable
  ok "UFW actif (22 seul ; ports applicatifs ouverts à la demande)"
fi
```

- [ ] **Step 4: Corriger le bug fail2ban**

`apt-get install fail2ban` s'exécutait sans `apt-get update` garanti quand `curl` était déjà présent (le `update` de la section 1 est conditionnel). Rendre l'installation autonome :

```bash
# ----- 4. fail2ban ----------------------------------------------------------
if ! command -v fail2ban-server >/dev/null 2>&1; then
  log "Installation de fail2ban…"
  sudo apt-get update -qq          # requis : le update de la section 1 est conditionnel
  sudo apt-get install -y -qq fail2ban
  sudo systemctl enable --now fail2ban
  ok "fail2ban installé et actif"
else
  ok "fail2ban déjà présent"
fi
```

- [ ] **Step 5: Renuméroter les sections**

L'original a **deux sections numérotées « 9 »** (fail2ban et MOTD). Renuméroter la totalité du fichier de 1 à N, sans doublon.

- [ ] **Step 6: Authentifier Docker Hub sans exposer le token**

Ajouter une section, avant le récapitulatif :

```bash
# ----- N. Authentification au registre --------------------------------------
# Le token arrive sur stdin, jamais en argument : un argument de ligne de
# commande est visible dans `ps` par tout utilisateur de la machine.
if [ -n "${REGISTRY_USER:-}" ]; then
  if [ -n "${REGISTRY_TOKEN:-}" ]; then
    printf '%s' "$REGISTRY_TOKEN" \
      | sudo docker login --username "$REGISTRY_USER" --password-stdin >/dev/null 2>&1 \
      && ok "docker login réussi ($REGISTRY_USER)" \
      || warn "docker login échoué — les images privées seront inaccessibles"
    unset REGISTRY_TOKEN
  else
    warn "REGISTRY_TOKEN absent : pas de docker login"
  fi
fi
```

- [ ] **Step 7: Nettoyer le MOTD et le récapitulatif**

Dans le bloc MOTD, remplacer la section « Cluster Kubernetes » (lignes 202-214) par un état Docker :

```sh
if command -v docker >/dev/null 2>&1; then
    printf "  ${BOLD}Docker${RESET}\n"
    printf "    Version     : %s\n" "$(docker --version 2>/dev/null | cut -d, -f1)"
    printf "    Conteneurs  : %s en marche / %s au total\n" \
      "$(docker ps -q 2>/dev/null | wc -l)" "$(docker ps -aq 2>/dev/null | wc -l)"
    echo
fi
```

Dans le récapitulatif final, retirer les lignes `k3s`, `kubectl`, `Helm`, `Nœuds K8s` et ajouter `docker compose`.

- [ ] **Step 8: Vérifier**

```bash
bash -n engine/lib/prepare_server.sh
shellcheck --severity=error engine/lib/prepare_server.sh
grep -in 'k3s\|kubectl\|kubeconfig\|helm\|cert-manager\|metrics-server\|6443' engine/lib/prepare_server.sh
grep -c '^# ----- 9\.' engine/lib/prepare_server.sh
```

Attendu : `bash -n` et `shellcheck` silencieux ; le `grep` Kubernetes ne remonte rien ; le compte de sections « 9 » vaut au plus 1.

- [ ] **Step 9: Commit**

```bash
git add engine/lib/prepare_server.sh
git commit -m "feat(engine): provisionne Docker au lieu de k3s, durcit ufw, corrige fail2ban et la numérotation"
```

---

## Task 11: `lib/steps.sh` — étapes réécrites

**Files:**
- Modify: `engine/lib/steps.sh` (réécriture complète)
- Modify: `engine/lib/ssh_remote.sh` (ajout de `docker_remote`)

**Interfaces:**
- Consumes: tout ce qui précède.
- Produces: les fonctions `step_check_prereqs`, `step_validate_ssh`, `step_create_project_dir`, `step_generate_microservices`, `step_generate_compose`, `step_generate_skills`, `step_generate_workflow`, `step_enable_sudo_nopasswd`, `step_prepare_server`, `step_build_images`, `step_deploy_stack`, `step_validate_deployment`. Chacune termine par un `emit_ok` ou meurt via `die` / `retryable`. Les étapes GitHub sont en Task 12.

- [ ] **Step 1: Ajouter le pilotage Docker distant à `ssh_remote.sh`**

Ajouter à la fin de `engine/lib/ssh_remote.sh` :

```bash
# ----- Pilotage Docker à distance -------------------------------------------
# Le worker ne monte JAMAIS /var/run/docker.sock. Il pilote le démon distant par
# DOCKER_HOST=ssh://, y compris pour l'hôte local, qui est une cible comme une
# autre. Un seul chemin de code, aucune exception.

docker_host_url() {
  printf 'ssh://%s@%s' "$(cfg_req target.user)" "$(cfg_req target.host)"
}

# docker_remote ARGS… — exécute une commande docker sur la cible.
docker_remote() {
  if (( ${DRY_RUN:-0} == 1 )); then
    ui_info "[dry-run] DOCKER_HOST=$(docker_host_url) docker $*"
    return 0
  fi
  DOCKER_HOST="$(docker_host_url)" docker "$@"
}

# compose_remote ARGS… — docker compose sur la cible, dans deploy/.
compose_remote() {
  docker_remote compose \
    --project-name "$APP_NAME" \
    --file "${WORK_DIR}/deploy/compose.yml" \
    --env-file "${WORK_DIR}/deploy/.env" \
    "$@"
}
```

Note : `docker compose --file <chemin local>` avec `DOCKER_HOST=ssh://` lit le fichier **localement** et envoie le contexte de build par SSH. C'est le comportement voulu : le worker n'a pas besoin de copier le projet sur la cible.

- [ ] **Step 2: Écrire les étapes**

Réécrire `engine/lib/steps.sh` :

```bash
#!/usr/bin/env bash
# engine/lib/steps.sh — les étapes exécutables de l'engine.
#
# CONVENTION (celle qui était documentée mais violée avant ce jalon)
# Une step_* fait son travail et rien d'autre : pas de titre affiché (le
# dispatcher s'en charge), pas de suivi d'état (il vit côté panel), pas de
# prompt (le worker n'a pas de TTY). Elle se termine par emit_ok, ou meurt par
# die (fatal, code 2) ou retryable (code 1).

# shellcheck source=gen_compose.sh
source "$(dirname "${BASH_SOURCE[0]}")/gen_compose.sh"
# shellcheck source=gen_microservices.sh
source "$(dirname "${BASH_SOURCE[0]}")/gen_microservices.sh"

# ----- Pré-requis -----------------------------------------------------------
step_check_prereqs() { check_prereqs; }

# ----- Accès SSH ------------------------------------------------------------
step_validate_ssh() {
  local host user
  host="$(cfg_req target.host)"
  user="$(cfg_req target.user)"

  if (( DRY_RUN == 1 )); then
    ui_info "[dry-run] ssh ${user}@${host} 'hostname'"
    emit_ok '{"dry_run":true}'
    return 0
  fi

  ui_info "Test de connexion à ${user}@${host}…"
  local banner
  if banner=$(ssh_remote -o ConnectTimeout=10 "${user}@${host}" \
       'echo "$(hostname) — $(lsb_release -ds 2>/dev/null || uname -s)"' 2>&1); then
    ui_ok "Connexion SSH réussie : ${banner}"
    emit_ok "$(jq -cn --arg b "$banner" '{banner: $b}')"
  else
    retryable "connexion SSH impossible vers ${user}@${host} : ${banner}"
  fi
}

# ----- Dossier de projet ----------------------------------------------------
step_create_project_dir() {
  if [[ -d "$WORK_DIR" ]]; then
    # Ce qui était un ui_confirm est devenu une clé de configuration : l'engine
    # n'a personne à qui demander.
    if cfg_bool options.reuse_existing_dir; then
      ui_ok "Réutilisation du dossier existant : ${WORK_DIR}"
    else
      die "le dossier ${WORK_DIR} existe déjà et options.reuse_existing_dir est faux" 2
    fi
  else
    mkdir -p "$WORK_DIR"
    ui_ok "Dossier créé : ${WORK_DIR}"
  fi
  emit_ok "$(jq -cn --arg d "$WORK_DIR" '{work_dir: $d}')"
}

# ----- Générateurs ----------------------------------------------------------
# Rejoués à chaque exécution : c'est ce qui garde le projet en phase avec
# spec.json et env.json.
step_generate_microservices() {
  gen_microservices
  emit_ok "$(jq -cn --arg d "$WORK_DIR/services" '{services_dir: $d}')"
}

step_generate_compose() {
  gen_compose
  emit_ok "$(jq -cn --arg f "$WORK_DIR/deploy/compose.yml" '{compose_file: $f}')"
}

step_generate_skills() {
  bash "$(dirname "${BASH_SOURCE[0]}")/gen_skills.sh" "$WORK_DIR" >&2
  ui_ok "Skills générées (.agents/skills/)"
  emit_ok '{"skills":5}'
}

step_generate_workflow() {
  APP_NAME="$APP_NAME" \
  AUTH_METHOD="$(cfg target.auth_method key)" \
  SPEC_JSON="$SPEC_JSON" \
    bash "$(dirname "${BASH_SOURCE[0]}")/gen_workflow.sh" "$WORK_DIR" >&2
  emit_ok "$(jq -cn --arg f "$WORK_DIR/.github/workflows/deploy.yml" '{workflow: $f}')"
}

# ----- sudo NOPASSWD --------------------------------------------------------
step_enable_sudo_nopasswd() {
  local host user
  host="$(cfg_req target.host)"; user="$(cfg_req target.user)"

  if (( DRY_RUN == 1 )); then
    ui_info "[dry-run] vérification sudo -n sur ${user}@${host}"
    emit_ok '{"dry_run":true}'
    return 0
  fi

  if ssh_remote "${user}@${host}" 'sudo -n true' 2>/dev/null; then
    ui_ok "sudo NOPASSWD déjà actif pour ${user}"
    emit_ok '{"already_configured":true}'
    return 0
  fi

  # L'ancienne version ouvrait un TTY et demandait le mot de passe sudo. Un
  # worker n'a pas de TTY : on échoue fatalement avec la marche à suivre.
  ui_err "sudo NOPASSWD n'est pas configuré pour ${user} sur ${host}"
  ui_info "Sur le serveur, en tant que root :"
  ui_info "  echo \"${user} ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/${user}-deploymatic"
  ui_info "  sudo chmod 440 /etc/sudoers.d/${user}-deploymatic"
  die "sudo NOPASSWD requis pour ${user}@${host} (configuration manuelle nécessaire)" 2
}

# ----- Provisioning ---------------------------------------------------------
step_prepare_server() {
  local host user
  host="$(cfg_req target.host)"; user="$(cfg_req target.user)"

  if (( DRY_RUN == 1 )); then
    ui_info "[dry-run] envoi de prepare_server.sh vers ${user}@${host}"
    emit_ok '{"dry_run":true}'
    return 0
  fi

  ui_info "Provisioning de ${host} (docker, ufw, fail2ban)…"
  # Le token part par l'environnement de la session SSH, pas en argument.
  REGISTRY_TOKEN="$(cfg registry.token)" \
  ssh_remote "${user}@${host}" \
    "REGISTRY_USER='$(cfg registry.user)' REGISTRY_TOKEN='$(cfg registry.token)' bash -s" \
    < "$(dirname "${BASH_SOURCE[0]}")/prepare_server.sh" >&2 \
    || retryable "le provisioning du serveur a échoué"

  ui_ok "Serveur prêt"
  emit_ok "$(jq -cn --arg h "$host" '{host: $h}')"
}

# ----- Build ----------------------------------------------------------------
# Chemin panel : on construit sur la CIBLE via DOCKER_HOST=ssh://, jamais sur
# l'hôte du panneau. Le contexte de build voyage par SSH.
step_build_images() {
  spec_init

  if (( DRY_RUN == 1 )); then
    ui_info "[dry-run] docker compose build + push sur $(docker_host_url)"
    emit_ok '{"dry_run":true}'
    return 0
  fi

  ui_info "Build des images sur la cible…"
  compose_remote build --pull >&2 || retryable "le build des images a échoué"

  # Push vers le registre : le CI et les redéploiements en dépendent.
  if [[ -n "$(cfg registry.token)" ]]; then
    ui_info "Publication des images sur le registre…"
    compose_remote push >&2 || ui_warn "push échoué — le déploiement local reste possible"
  else
    ui_warn "registry.token absent : pas de push, images locales à la cible seulement"
  fi

  ui_ok "Images construites"
  emit_ok "$(jq -cn --argjson n "$(spec_service_ids | wc -l | tr -d ' ')" '{built: $n}')"
}

# ----- Déploiement ----------------------------------------------------------
step_deploy_stack() {
  if (( DRY_RUN == 1 )); then
    ui_info "[dry-run] docker compose up -d --remove-orphans"
    emit_ok '{"dry_run":true}'
    return 0
  fi

  ui_info "Démarrage de la stack…"
  compose_remote pull --ignore-buildable >&2 || ui_warn "pull partiel (images locales)"
  compose_remote up -d --remove-orphans >&2 || retryable "docker compose up a échoué"

  ui_ok "Stack démarrée"
  emit_ok "$(jq -cn --arg p "$APP_NAME" '{project: $p}')"
}

# ----- Validation -----------------------------------------------------------
# Plus aucun curl sur une IP publique : l'hôte cible n'est plus exposé, et
# l'ancienne validation cassait dès qu'un hostname d'ingress était configuré.
# On valide depuis la cible, sur 127.0.0.1:<port hôte>.
step_validate_deployment() {
  spec_init
  local host user
  host="$(cfg_req target.host)"; user="$(cfg_req target.user)"

  if (( DRY_RUN == 1 )); then
    ui_info "[dry-run] contrôle de santé des services exposés"
    emit_ok '{"dry_run":true}'
    return 0
  fi

  # 1) Tous les conteneurs sont-ils en marche et sains ?
  local unhealthy
  unhealthy=$(compose_remote ps --format json 2>/dev/null \
    | jq -rs '
        (if type == "array" then . else [.] end)
        | map(select(.State != "running"
                     or ((.Health // "") | test("^(unhealthy|starting)$"))))
        | map(.Service) | join(",")
      ' 2>/dev/null || printf 'indéterminé')

  if [[ -n "$unhealthy" && "$unhealthy" != "indéterminé" ]]; then
    retryable "services non sains : ${unhealthy}"
  fi
  ui_ok "Tous les conteneurs sont en marche"

  # 2) Chaque service exposé répond-il sur son port hôte, depuis la cible ?
  local sid port health checked=0
  for sid in $(spec_exposed_ids_by_path_length); do
    port="$(cfg_port "$sid")"
    health="$(spec_get "$sid" health /)"
    if ssh_remote "${user}@${host}" \
         "curl -fsS -m 5 -o /dev/null 'http://127.0.0.1:${port}${health}'" 2>/dev/null; then
      ui_ok "${sid} répond sur 127.0.0.1:${port}${health}"
      checked=$((checked + 1))
    else
      retryable "le service '${sid}' ne répond pas sur 127.0.0.1:${port}${health}"
    fi
  done

  emit_ok "$(jq -cn --argjson n "$checked" '{services_ok: $n}')"
}
```

- [ ] **Step 3: Vérifier la syntaxe et l'absence d'interactif**

```bash
bash -n engine/lib/steps.sh engine/lib/ssh_remote.sh
shellcheck --severity=error engine/lib/steps.sh engine/lib/ssh_remote.sh
grep -n "ui_confirm\|ui_prompt\|ui_choose\|read -r\|kubectl\|kubeconfig" engine/lib/steps.sh
```

Attendu : les deux premières commandes silencieuses, le `grep` sans résultat.

- [ ] **Step 4: Relancer le test du dispatcher**

```bash
bash engine/tests/run.sh test_dispatcher
```

Attendu : toutes les assertions passent maintenant, y compris `--dry-run` qui échouait à la Task 6.

- [ ] **Step 5: Vérifier un run complet en dry-run**

```bash
mkdir -p runs/demo
cp engine/tests/fixtures/env.min.json runs/demo/env.json
cp engine/templates/spec.demo.json runs/demo/spec.json
chmod 700 runs && chmod 600 runs/demo/*.json
bash engine/bootstrap.sh --workspace demo --all --dry-run 2>/dev/null | jq -c .
```

Attendu : une ligne JSON par étape, toutes avec `"ok":true`. Les étapes de génération s'exécutent réellement (elles n'ont pas besoin du réseau) — vérifier ensuite :

```bash
ls runs/demo/tp-app/deploy/ runs/demo/tp-app/services/
(cd runs/demo/tp-app/deploy && docker compose config --quiet && echo "compose valide")
```

- [ ] **Step 6: Commit**

```bash
git add engine/lib/steps.sh engine/lib/ssh_remote.sh
git commit -m "feat(engine): étapes Docker (build sur la cible, deploy compose, validation locale)"
```

---

## Task 12: Bloc GitHub optionnel et workflow Compose

**Files:**
- Modify: `engine/lib/steps.sh` (ajout des étapes GitHub)
- Modify: `engine/lib/gen_workflow.sh`

**Interfaces:**
- Consumes: `cfg_bool github.enabled`, `cfg github.*`.
- Produces: `step_github_create_repo`, `step_github_set_secrets`, `step_git_init`, `step_git_push`. Toutes sortent immédiatement en `emit_ok {"skipped":true}` si `github.enabled` est faux.

- [ ] **Step 1: Ajouter les étapes GitHub à `steps.sh`**

```bash
# ----- Bloc GitHub (optionnel) ----------------------------------------------
# Décision d'architecture : GitHub est un extra, pas le chemin de déploiement.
# Le panel déploie lui-même (build_images + deploy_stack). Une panne GitHub ne
# doit jamais empêcher une application de tourner — d'où la position de ce bloc
# en fin de séquence, et le court-circuit ci-dessous.

_github_skip_if_disabled() {
  if ! cfg_bool github.enabled; then
    ui_skip "bloc GitHub désactivé (github.enabled=false)"
    emit_ok '{"skipped":true}'
    return 0
  fi
  return 1
}

_gh() {
  # gh s'authentifie par GH_TOKEN, jamais par `gh auth login` (interactif).
  GH_TOKEN="$(cfg_req github.token)" gh "$@"
}

step_github_create_repo() {
  _github_skip_if_disabled && return 0
  local repo; repo="$(cfg_req github.user)/$(cfg_req github.repo)"

  if _gh repo view "$repo" >/dev/null 2>&1; then
    if cfg_bool options.allow_existing_repo; then
      ui_ok "Dépôt existant réutilisé : ${repo}"
      emit_ok "$(jq -cn --arg r "$repo" '{repo: $r, created: false}')"
      return 0
    fi
    die "le dépôt ${repo} existe déjà et options.allow_existing_repo est faux" 2
  fi

  _gh repo create "$repo" --public \
    --description "Déployé par DeployMatic" >&2 \
    || retryable "création du dépôt ${repo} impossible"
  ui_ok "Dépôt créé : https://github.com/${repo}"
  emit_ok "$(jq -cn --arg r "$repo" '{repo: $r, created: true}')"
}

step_github_set_secrets() {
  _github_skip_if_disabled && return 0
  local repo; repo="$(cfg_req github.user)/$(cfg_req github.repo)"

  local n=0
  _gh secret set DOCKERHUB_USERNAME --repo "$repo" --body "$(cfg_req registry.user)" >&2 && n=$((n+1))
  _gh secret set DOCKERHUB_TOKEN    --repo "$repo" --body "$(cfg_req registry.token)" >&2 && n=$((n+1))
  _gh secret set TARGET_HOST        --repo "$repo" --body "$(cfg_req target.host)" >&2 && n=$((n+1))
  _gh secret set TARGET_USER        --repo "$repo" --body "$(cfg_req target.user)" >&2 && n=$((n+1))

  if [[ "$(cfg target.auth_method key)" == "password" ]]; then
    _gh secret set TARGET_PASSWORD --repo "$repo" --body "$(cfg_req target.password)" >&2 && n=$((n+1))
  else
    local key_path; key_path="$(cfg_req target.ssh_key_path)"
    ssh-keygen -y -f "$key_path" >/dev/null 2>&1 \
      || die "clé SSH invalide ou protégée par passphrase : ${key_path} (le runner CI ne peut pas la déverrouiller)" 2
    # Une clé sans saut de ligne final provoque "error in libcrypto" côté runner.
    local tmp; tmp=$(mktemp)
    cat "$key_path" > "$tmp"
    [[ -z "$(tail -c1 "$tmp")" ]] || printf '\n' >> "$tmp"
    _gh secret set TARGET_SSH_KEY --repo "$repo" < "$tmp" >&2 && n=$((n+1))
    rm -f "$tmp"
  fi

  ui_ok "${n} secrets configurés"
  emit_ok "$(jq -cn --argjson n "$n" '{secrets: $n}')"
}

step_git_init() {
  _github_skip_if_disabled && return 0
  local url="https://github.com/$(cfg_req github.user)/$(cfg_req github.repo).git"
  (
    cd "$WORK_DIR" || exit 1
    [[ -d .git ]] || git init -q -b main
    cat > .gitignore <<'GITIGNORE'
node_modules/
npm-debug.log
*.log
.DS_Store
.vscode/
.idea/
deploy/.env
GITIGNORE
    git remote add origin "$url" 2>/dev/null || git remote set-url origin "$url"
  ) >&2 || retryable "initialisation git impossible dans ${WORK_DIR}"

  ui_ok "Dépôt local initialisé, origin → ${url}"
  emit_ok "$(jq -cn --arg u "$url" '{remote: $u}')"
}

step_git_push() {
  _github_skip_if_disabled && return 0
  local user; user="$(cfg_req github.user)"
  (
    cd "$WORK_DIR" || exit 1
    git add .
    if git diff --cached --quiet; then
      echo "aucun changement à commiter" >&2
    else
      git -c user.email="${user}@users.noreply.github.com" -c user.name="$user" \
          commit -q -m "chore: déploiement initial par DeployMatic"
    fi
    GH_TOKEN="$(cfg_req github.token)" git push -u origin main
  ) >&2 || retryable "push vers origin/main impossible"

  ui_ok "Push réussi"
  emit_ok "$(jq -cn --arg u "https://github.com/${user}/$(cfg_req github.repo)" '{repo_url: $u}')"
}
```

Noter que `deploy/.env` est dans le `.gitignore` généré alors que `deploy/.env.example` est committé : le tag d'image déployé est un état de la cible, pas du dépôt.

- [ ] **Step 2: Réécrire le job `deploy` de `gen_workflow.sh`**

Le workflow garde `paths-filter`, `gitleaks` et `trivy` **inchangés** (jalon 6). Seul le job `deploy` change. Remplacer son contenu (lignes 194-256 de l'original) par :

```yaml
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
```

Construire `HEALTH_CHECK_CMDS` en tête du générateur, depuis le spec :

```bash
# Un curl local par service exposé, enchaînés par &&.
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
```

Renommer aussi les secrets `OVH_*` en `TARGET_*` dans `SETUP_SSH_BLOCK` et `SSH_ENV`, pour rester cohérent avec `step_github_set_secrets`.

- [ ] **Step 3: Vérifier le YAML généré**

```bash
bash engine/bootstrap.sh --workspace demo --step generate_workflow 2>/dev/null | jq -c .
python3 -c "import sys,yaml; yaml.safe_load(open('runs/demo/tp-app/.github/workflows/deploy.yml')); print('YAML valide')"
grep -c 'kubectl\|rollout' runs/demo/tp-app/.github/workflows/deploy.yml
```

Attendu : `{"ok":true,…}`, « YAML valide », et le `grep` renvoie `0`.

- [ ] **Step 4: Commit**

```bash
git add engine/lib/steps.sh engine/lib/gen_workflow.sh
git commit -m "feat(engine): bloc GitHub optionnel et workflow de déploiement par compose avec rollback"
```

---

## Task 13: `lib/diag.sh` — diagnostic Docker

**Files:**
- Modify: `engine/lib/diag.sh` (réécriture complète)

**Interfaces:**
- Consumes: `compose_remote`, `cfg_*`, `spec_*`.
- Produces: `cmd_doctor`, `cmd_logs SERVICE`, `cmd_stack_info`, plus un alias déprécié `cmd_cluster_info`.

- [ ] **Step 1: Réécrire `engine/lib/diag.sh`**

```bash
#!/usr/bin/env bash
# engine/lib/diag.sh — diagnostic d'une application déployée.
#
# Ces commandes sont appelées à la main pendant le développement de l'engine ;
# le panel les remplacera par des vues (jalon 2). Elles écrivent sur stderr et
# ne respectent pas le contrat JSON — ce ne sont pas des étapes.

cmd_doctor() {
  local fails=0 host user
  host="$(cfg_req target.host)"; user="$(cfg_req target.user)"

  ui_step "Doctor — ${APP_NAME} sur ${host}"

  ui_info "Outils locaux :"
  local tool
  for tool in git ssh curl jq docker; do
    if command -v "$tool" >/dev/null 2>&1; then ui_ok "$tool"
    else ui_err "$tool absent"; fails=$((fails + 1)); fi
  done

  ui_info "Accès à la cible :"
  if ssh_remote -o ConnectTimeout=5 "${user}@${host}" true 2>/dev/null; then
    ui_ok "SSH"
    if docker_remote version >/dev/null 2>&1; then ui_ok "démon Docker joignable"
    else ui_err "démon Docker injoignable via DOCKER_HOST"; fails=$((fails + 1)); fi
  else
    ui_err "SSH inaccessible"; fails=$((fails + 1))
  fi

  ui_info "Fichier compose :"
  if compose_remote config --quiet 2>/dev/null; then ui_ok "compose.yml valide"
  else ui_err "compose.yml invalide"; fails=$((fails + 1)); fi

  ui_info "Conteneurs :"
  compose_remote ps >&2 || fails=$((fails + 1))

  ui_info "Endpoints (depuis la cible) :"
  local sid port health
  for sid in $(spec_exposed_ids_by_path_length 2>/dev/null); do
    port="$(cfg_port "$sid")"; health="$(spec_get "$sid" health /)"
    if ssh_remote "${user}@${host}" \
         "curl -fsS -m 5 -o /dev/null 'http://127.0.0.1:${port}${health}'" 2>/dev/null; then
      ui_ok "${sid} → 127.0.0.1:${port}${health}"
    else
      ui_err "${sid} → 127.0.0.1:${port}${health}"; fails=$((fails + 1))
    fi
  done

  if (( fails == 0 )); then ui_ok "Tous les contrôles passent"; return 0; fi
  ui_err "${fails} contrôle(s) en échec"
  return 1
}

cmd_logs() {
  local service="${1:-}"
  if [[ -z "$service" ]]; then
    compose_remote logs -f --tail=200 >&2
  else
    compose_remote logs -f --tail=200 "$service" >&2
  fi
}

cmd_stack_info() {
  ui_step "État de la stack ${APP_NAME}"
  compose_remote ps >&2
  echo >&2
  compose_remote images >&2
  echo >&2
  docker_remote system df >&2
}

# Alias déprécié — l'ancien nom parlait de cluster Kubernetes.
cmd_cluster_info() {
  ui_warn "cmd_cluster_info est déprécié : utiliser cmd_stack_info (il n'y a plus de cluster)"
  cmd_stack_info
}
```

- [ ] **Step 2: Vérifier**

```bash
bash -n engine/lib/diag.sh
shellcheck --severity=error engine/lib/diag.sh
grep -in 'kubectl\|kubeconfig\|k3s' engine/lib/diag.sh
```

Attendu : les deux premières silencieuses, le `grep` sans résultat.

- [ ] **Step 3: Commit**

```bash
git add engine/lib/diag.sh
git commit -m "refactor(engine): diagnostic basé sur docker compose, cmd_cluster_info déprécié"
```

---

## Task 14: `lib/gen_skills.sh` — Skills Docker

**Files:**
- Modify: `engine/lib/gen_skills.sh`

**Interfaces:**
- Consumes: `$WORK_DIR` en argument positionnel (reste un script autonome, il n'a besoin d'aucun helper).
- Produces: `.agents/skills/` avec `microservice-editor`, `github-flow`, `docker-deploy`, `health-monitor`, `rollback-manager`.

- [ ] **Step 1: Renommer la skill de déploiement**

`k8s-deploy` → `docker-deploy`. Dans son `SKILL.md` :
- Description : remplacer « deploy to the Kubernetes cluster » par « deploy a new version via the CI/CD pipeline or the DeployMatic panel ».
- Section « Workflow » : le bump de version reste, mais l'étape de déploiement devient « push → le CI réécrit `deploy/.env` avec le SHA et relance `docker compose up -d` ».
- Règles : remplacer « Never run `kubectl set image` » par « Never run `docker compose up` from the local machine — the deployment happens on the target, driven by the CI or the panel ».
- Adapter le chemin dans `bump_version.sh` : `microservices/api/server.js` → `services/api/server.js`.

- [ ] **Step 2: Réécrire `health-monitor`**

Remplacer les instructions `kubectl rollout status` / `kubectl get pods` par :

```markdown
## Checks performed (in order)

1. **Container status** — `docker compose ps` : every service is `running`, and
   every service that declares a healthcheck is `healthy`.
2. **Restart count** — no container has restarted in the last 5 minutes
   (`docker inspect -f '{{.RestartCount}}'`).
3. **HTTP health-check** — each exposed service answers on
   `http://127.0.0.1:<host port><health path>`, **from the target host**. Never
   from a public URL: the target is not publicly reachable.
4. **Response time** — under 1 second.

## Rollback

There is no `rollback undo` with Compose. The rollback is:

    cd deploy
    cp .env .env.failed
    # take the previous SHA from .image-history
    sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=<previous SHA>/" .env
    docker compose pull && docker compose up -d --remove-orphans
```

Réécrire `scripts/check_health.sh` pour qu'il prenne `HOST_PORT` et `HEALTH_PATH` en arguments et interroge `127.0.0.1`, au lieu d'une URL publique.

- [ ] **Step 3: Réécrire `rollback-manager`**

Remplacer `scripts/rollback.sh` :

```bash
#!/usr/bin/env bash
# Rollback helper — remet un tag d'image antérieur dans deploy/.env.
#
# Usage :
#   rollback.sh list                  affiche l'historique des tags déployés
#   rollback.sh to previous           revient au tag précédent
#   rollback.sh to <sha>              revient à un SHA précis

set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-deploy}"
ENV_FILE="${DEPLOY_DIR}/.env"
HISTORY="${DEPLOY_DIR}/.image-history"

current_tag() { grep '^IMAGE_TAG=' "$ENV_FILE" | cut -d= -f2; }

case "${1:?usage: rollback.sh list|to <cible>}" in
  list)
    echo "Tag actuel : $(current_tag)"
    echo "Historique (du plus récent au plus ancien) :"
    [[ -f "$HISTORY" ]] && cat "$HISTORY" || echo "  (vide)"
    ;;
  to)
    target="${2:?usage: rollback.sh to previous|<sha>}"
    if [[ "$target" == "previous" ]]; then
      [[ -f "$HISTORY" ]] || { echo "pas d'historique" >&2; exit 1; }
      target=$(sed -n '2p' "$HISTORY")
      [[ -n "$target" ]] || { echo "pas de tag précédent" >&2; exit 1; }
    fi
    echo "Rollback : $(current_tag) → ${target}"
    sed -i.bak "s/^IMAGE_TAG=.*/IMAGE_TAG=${target}/" "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
    (cd "$DEPLOY_DIR" && docker compose pull && docker compose up -d --remove-orphans)
    echo "current_tag=$(current_tag)"
    ;;
  *)
    echo "Action inconnue : $1 (list | to)" >&2; exit 1 ;;
esac
```

Ajouter un `scripts/record_tag.sh` qui pousse le tag courant en tête de `.image-history` et tronque à 5 lignes — c'est ce qui rend `to previous` possible.

- [ ] **Step 4: Corriger le décompte des skills**

L'en-tête du fichier dit « les 4 Skills » alors qu'il en génère 5. Corriger :
- ligne 3 de `gen_skills.sh` : « Génère les 5 Skills Claude Code custom du projet. »
- dans `gen_microservices.sh`, le README généré : « 4 Skills Claude Code custom » → 5, et `k8s/base/` → `deploy/`.
- dans `steps.sh`, le message de commit de `step_git_push` ne mentionne plus de décompte (déjà réécrit en Task 12).

- [ ] **Step 5: Corriger `DEPLOYMENT_GUIDE.md`**

L'affirmation « The manifest references the image by `<SHA>`, never `latest` » était fausse. Elle devient vraie avec `deploy/.env` — réécrire la section « Tagging strategy » :

```markdown
## Tagging strategy

Each image is pushed with TWO tags:

- `latest` — developer convenience
- `<SHA>` — the commit SHA, immutable

`deploy/compose.yml` references `${IMAGE_TAG}`, interpolated by Compose from
`deploy/.env`. The CI rewrites that single line with the commit SHA on every
deploy, so the running stack is always pinned to an immutable tag — never to
`latest`. Rolling back means putting an older SHA back in that line and running
`docker compose up -d`.
```

Remplacer aussi la liste des 4 jobs (`kubectl set image`) par la nouvelle, et les secrets `OVH_*` par `TARGET_*`.

- [ ] **Step 6: Vérifier**

```bash
bash -n engine/lib/gen_skills.sh
bash engine/bootstrap.sh --workspace demo --step generate_skills 2>/dev/null | jq -c .
ls runs/demo/tp-app/.agents/skills/
grep -rn "kubectl\|k8s-deploy" runs/demo/tp-app/.agents/skills/ || echo "aucune trace de kubernetes"
```

Attendu : 5 répertoires de skills dont `docker-deploy` ; le `grep` ne remonte rien.

- [ ] **Step 7: Commit**

```bash
git add engine/lib/gen_skills.sh engine/lib/gen_microservices.sh
git commit -m "feat(engine): skills docker-deploy et rollback par IMAGE_TAG, corrige le décompte à 5"
```

---

## Task 15: Documentation et vérification des critères d'acceptation

**Files:**
- Modify: `README.md`
- Create: `docs/ENGINE.md`

- [ ] **Step 1: Écrire `docs/ENGINE.md`**

Document de référence du contrat, à destination du jalon 2 :

```markdown
# Contrat de l'engine

    engine/bootstrap.sh --workspace <ws> --step <nom>

## Entrées

- `runs/<ws>/env.json` — paramètres et secrets (600)
- `runs/<ws>/spec.json` — description de l'application (600)

Écrits par l'appelant (le worker du panel au jalon 2), lus avec `jq`.
**Jamais `source`.**

## Sorties

- **stderr** : les logs, en clair, ligne par ligne.
- **stdout** : exactement une ligne JSON, en fin d'exécution.
  - succès : `{"ok": true, "data": {…}}`
  - échec  : `{"ok": false, "error": "message"}`

## Codes de sortie

| Code | Sens | Réaction attendue de l'appelant |
|---|---|---|
| 0 | succès | étape suivante |
| 1 | échec réessayable | un retry avec backoff |
| 2 | échec fatal | arrêt du run, intervention humaine |

## Étapes

(Liste produite par `engine/bootstrap.sh --list-steps`, avec pour chacune une
ligne décrivant ce qu'elle consomme dans `env.json` et ce qu'elle renvoie
dans `data`.)

## Schéma env.json / spec.json

(Reprendre les deux schémas du plan.)

## Ce que l'engine ne fait pas

- Il n'écrit dans aucune base et ne connaît pas l'existence du panel.
- Il ne choisit jamais un port : il les reçoit dans `.ports`.
- Il ne pose aucune question : toute décision est une clé de configuration.
- Il ne monte jamais `/var/run/docker.sock` : Docker est piloté par
  `DOCKER_HOST=ssh://`, y compris pour l'hôte local.
```

- [ ] **Step 2: Mettre à jour le README**

Sections à réécrire :
- **Démarrage rapide** : `./web/start.sh` disparaît (l'interface web est cassée jusqu'au jalon 2 — le dire explicitement). Le démarrage devient l'engine en ligne de commande.
- **Ce que fait le script** : remplacer le tableau des 18 étapes k8s par la sortie de `--list-steps`.
- **Architecture modulaire** : nouvelle arborescence `engine/`.
- **Paramètres collectés** : remplacer le tableau des variables par le schéma `env.json`.
- **Sécurité** : retirer les mentions cert-manager / ClusterIssuer / ingress ; dire que le durcissement des conteneurs s'applique aux services buildés et pourquoi il est partiel sur les images tierces ; mentionner la fermeture de la classe d'injection.
- **Dépannage** : retirer les lignes `kubectl`, `ImagePullBackOff`, `6443` ; ajouter « le port hôte doit être ≥ 1024 » et « `docker compose config --quiet` pour valider le fichier généré ».
- Ajouter en tête un encadré : **interface web hors service, remplacée au jalon 2**.

- [ ] **Step 3: Passer les critères d'acceptation un par un**

```bash
cd /Users/kowkow/Desktop/Projects/bootstrap-tp

echo "--- 1. bash -n sur tous les .sh ---"
for f in engine/bootstrap.sh engine/lib/*.sh engine/tools/*.sh engine/tests/*.sh; do
  bash -n "$f" || echo "ÉCHEC : $f"
done

echo "--- 2. shellcheck niveau error ---"
shellcheck --severity=error --shell=bash engine/bootstrap.sh engine/lib/*.sh engine/tools/*.sh

echo "--- 3. plus aucune trace de Kubernetes ---"
grep -rin 'k3s\|kubectl\|kubeconfig\|ingress\|cert-manager\|ClusterIssuer' engine/ \
  | grep -v 'déprécié\|deprecated\|remplace\|ancien'

echo "--- 4. plus aucun source de configuration ---"
grep -rn 'source.*env\|\. .*\.bootstrap-env' engine/

echo "--- 5. une ligne JSON par étape ---"
for s in $(bash engine/bootstrap.sh --list-steps); do
  n=$(bash engine/bootstrap.sh --workspace demo --step "$s" --dry-run 2>/dev/null | wc -l | tr -d ' ')
  printf '%-24s %s ligne(s)\n' "$s" "$n"
done

echo "--- 7. le compose généré est valide ---"
(cd runs/demo/tp-app/deploy && docker compose config --quiet && echo "OK")

echo "--- suite de tests complète ---"
bash engine/tests/run.sh
```

Attendu : critères 1, 2, 4, 5 et 7 verts. Le critère 3 peut légitimement remonter des mentions volontaires (l'alias déprécié `cmd_cluster_info`, les commentaires historiques) — les lire une par une et confirmer.

- [ ] **Step 4: Déclarer explicitement le critère 6 comme non vérifié**

Le critère 6 (`--all` déploie l'app de démo de bout en bout sur une cible SSH) **ne peut pas être validé** : aucune cible SSH de test n'est disponible. Créer `docs/JALON-1-VERIFICATION.md` :

```markdown
# Jalon 1 — état de vérification

| # | Critère | État |
|---|---|---|
| 1 | `bash -n` sur tous les `.sh` | ✅ vérifié |
| 2 | `shellcheck` sans erreur | ✅ vérifié |
| 3 | Plus de mentions Kubernetes involontaires | ✅ vérifié |
| 4 | Plus aucun `source` de configuration | ✅ vérifié |
| 5 | Une ligne JSON par étape | ✅ vérifié |
| 6 | `--all` déploie de bout en bout | ❌ **NON VÉRIFIÉ** |
| 7 | `docker compose config --quiet` passe | ✅ vérifié |

## Pourquoi le critère 6 n'est pas vérifié

Aucune cible SSH n'était disponible au moment de l'implémentation. Ce qui a été
vérifié à la place :

- `--all --dry-run` traverse les seize étapes sans erreur, et chacune imprime
  une ligne JSON `ok:true` ;
- les étapes de génération ont réellement tourné et produit un `compose.yml`
  que `docker compose config --quiet` accepte.

Ce qui reste à vérifier dès qu'une cible existe, dans cet ordre :

1. `validate_ssh` — connexion effective
2. `prepare_server` — installation de Docker sur une Ubuntu vierge
3. `build_images` — `DOCKER_HOST=ssh://` et le transfert du contexte de build
4. `deploy_stack` — démarrage réel des conteneurs
5. `validate_deployment` — les healthchecks et les curls locaux

Le point le plus incertain est le 3 : `docker compose build` via `DOCKER_HOST=ssh://`
transfère le contexte de build par SSH, ce qui n'a jamais été exercé ici.
```

- [ ] **Step 5: Commit final**

```bash
git add README.md docs/ENGINE.md docs/JALON-1-VERIFICATION.md
git commit -m "docs: contrat de l'engine, README aligné sur Docker, état de vérification du jalon 1"
```

---

## Self-review (effectuée à la rédaction)

**Couverture du prompt du jalon 1 :**

| Section du prompt | Task |
|---|---|
| A. Réorganisation | 1 |
| B. Dispatcher, suppression de `PIPELINE` / `state.sh`, `emit_result`, `--all` | 3, 5, 6 |
| C. Configuration JSON, `cfg`, `migrate-env.sh`, permissions | 4 |
| D. `spec.json`, `spec.demo.json` | 7 |
| E. `gen_compose.sh`, `deploy/.env`, réseau par app | 8 |
| F1. Unités | 2 |
| F2. nginx non-root | 9 |
| F3. Répliques | **voir écart ci-dessous** |
| G. Étapes réécrites, convention « step pure » | 11 |
| H. `prepare_server.sh` | 10 |
| I. Workflow GitHub Actions | 12 |
| J. `diag.sh` | 13 |
| K. Skills | 14 |
| L. Documentation | 15 |

**Écarts assumés par rapport au prompt d'origine, à valider :**

1. **F3 (répliques) — TRANCHÉ.** `spec.json` n'a pas de champ `replicas` : la
   notion disparaît du modèle. `migrate-env.sh` (Task 4) émet un avertissement
   explicite quand un ancien `REPLICAS_API` / `REPLICAS_WEB` valait autre chose
   que 1, pour que la régression soit visible plutôt que silencieuse.
2. **`step_build_images` est un ajout** au prompt d'origine, conséquence de la
   décision 1b actée avec toi.
3. **L'étape « attendre le workflow CI » est supprimée** plutôt que réécrite.
4. **`microservices/` devient `services/`** pour coller au `build` du spec ;
   le prompt ne le demandait pas explicitement.
