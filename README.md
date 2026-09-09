# DeployMatic (jalon 1 — engine Docker)

> **Interface web hors service.** L'ancienne UI Flask (`web/`) est cassée
> depuis que l'orchestrateur a déménagé sous `engine/` — elle ne sera pas
> réparée, elle sera **remplacée** au jalon 2 par un panneau FastAPI. Pour
> l'instant, seule la ligne de commande fonctionne.

[![bash](https://img.shields.io/badge/bash-3.2%2B-blue.svg)](#)
[![license](https://img.shields.io/badge/license-MIT-green.svg)](#licence)

DeployMatic déploie une application (API + frontend, ou toute autre topologie
décrite dans un `spec.json`) sur un serveur distant via SSH et Docker Compose,
avec un pipeline CI/CD GitHub Actions optionnel et des Skills Claude Code
générées pour la piloter en langage naturel.

Le projet est en cours de transformation : l'ancien script bash monolithique
sur Kubernetes devient un **engine bash exécuteur d'étapes**, appelé par un
futur panneau web Python (jalon 2). Ce README décrit **ce qui existe
aujourd'hui** — la ligne de commande de l'engine. Pour le projet cible sur six
jalons, voir [`docs/ROADMAP.md`](docs/ROADMAP.md).

---

## Table des matières

- [Démarrage rapide](#démarrage-rapide)
- [Ce que fait l'engine](#ce-que-fait-lengine)
- [Architecture modulaire](#architecture-modulaire)
- [Format de configuration](#format-de-configuration)
- [Skills Claude Code générées](#skills-claude-code-générées)
- [Sécurité](#sécurité)
- [Pré-requis](#pré-requis)
- [Diagnostic](#diagnostic)
- [Dépannage](#dépannage)
- [Documentation complète](#documentation-complète)
- [Licence](#licence)

---

## Démarrage rapide

Il n'y a pas encore de panneau qui écrit `env.json`/`spec.json` à ta place :
au jalon 1, on les écrit à la main. C'est fastidieux, et c'est temporaire —
c'est précisément ce que le panel du jalon 2 automatise.

```bash
git clone https://github.com/KowKowFR/script-devops.git
cd script-devops

# 1. Un workspace = un répertoire sous runs/, avec deux fichiers JSON.
mkdir -p runs/monprojet
cp engine/templates/spec.demo.json runs/monprojet/spec.json

cat > runs/monprojet/env.json <<'EOF'
{
  "app":      { "name": "tp-app", "author": "Ton Nom" },
  "target":   { "host": "1.2.3.4", "user": "devops", "auth_method": "key",
                "ssh_key_path": "/chemin/vers/ta_cle", "password": "",
                "bind_addr": "0.0.0.0" },
  "registry": { "user": "tondockerhubuser", "token": "dckr_pat_…" },
  "github":   { "enabled": false, "user": "", "repo": "", "token": "" },
  "ports":    { "api": 10001, "web": 10002 },
  "limits":   { "cpu": "200m", "memory": "128Mi" },
  "options":  { "reuse_existing_dir": true, "allow_existing_repo": true }
}
EOF
chmod 600 runs/monprojet/env.json runs/monprojet/spec.json

# 2. Lister les étapes disponibles.
bash engine/bootstrap.sh --list-steps

# 3. Exécuter une étape à la fois — c'est le mode d'appel nominal.
bash engine/bootstrap.sh --workspace monprojet --step validate_ssh
bash engine/bootstrap.sh --workspace monprojet --step prepare_server
# … une par une, dans l'ordre de --list-steps.

# Ou, pour tester l'engine seul de bout en bout (jamais utilisé par le panel) :
bash engine/bootstrap.sh --workspace monprojet --all
```

Chaque appel `--step` écrit ses logs sur **stderr** et imprime **une seule
ligne JSON** sur **stdout** en fin d'exécution :
`{"ok":true,"data":{...}}` ou `{"ok":false,"error":"..."}`. C'est le contrat
que le panel s'appuiera dessus au jalon 2 — voir
[`docs/ENGINE.md`](docs/ENGINE.md) pour la référence complète.

Pas de cible SSH sous la main ? `engine/tools/test-target.sh up` monte une VM
Ubuntu locale (via Lima) en une commande — voir
[`docs/TEST-TARGET.md`](docs/TEST-TARGET.md).

---

## Ce que fait l'engine

`engine/bootstrap.sh --list-steps` est la source de vérité — voici sa sortie
au moment de la rédaction :

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
github_create_repo
github_set_secrets
git_init
git_push
```

C'est aussi l'ordre d'exécution exact de `--all`. Détail étape par étape dans
[`docs/ENGINE.md`](docs/ENGINE.md#5-les-étapes).

En résumé : validation SSH → génération du projet (microservices Express +
nginx, `compose.yml` durci, Skills, workflow CI) → provisioning du serveur
(Docker, ufw, fail2ban) → build des images **sur la cible** via
`DOCKER_HOST=ssh://` → déploiement Compose → validation HTTP locale à la
cible → bloc GitHub **optionnel** (dépôt, secrets, push).

Chaque étape se lance indépendamment (`--step <nom>`) et répond par une seule
ligne JSON. Le détail complet — ce que chaque étape lit dans `env.json`/
`spec.json`, ce qu'elle renvoie, les codes de sortie — est dans
[`docs/ENGINE.md`](docs/ENGINE.md).

---

## Architecture modulaire

```
bootstrap-tp/
├── engine/
│   ├── bootstrap.sh          Dispatcher : exécute UNE étape nommée
│   ├── lib/
│   │   ├── ui.sh                Messages de progression (stderr uniquement)
│   │   ├── runtime.sh           Contrat de sortie JSON + trap d'erreur
│   │   ├── config.sh             cfg/cfg_req/cfg_port (env.json), spec_* (spec.json)
│   │   ├── units.sh               Conversion d'unités Kubernetes → Docker
│   │   ├── ssh_remote.sh          ssh_remote/scp_remote, DOCKER_HOST=ssh://
│   │   ├── prereqs.sh             Vérification des outils requis
│   │   ├── steps.sh                Les 16 fonctions step_*
│   │   ├── gen_compose.sh          Génère deploy/compose.yml
│   │   ├── gen_microservices.sh    Génère l'app de démo (API + Web)
│   │   ├── gen_workflow.sh         Génère .github/workflows/deploy.yml
│   │   ├── gen_skills.sh           Génère les 5 Skills Claude Code
│   │   ├── prepare_server.sh       Provisioning serveur (envoyé via SSH)
│   │   └── diag.sh                 cmd_doctor, cmd_logs, cmd_stack_info
│   ├── templates/
│   │   └── spec.demo.json          spec.json de l'app de démo
│   ├── tools/
│   │   ├── migrate-env.sh          Migre un ancien .bootstrap-env vers env.json
│   │   └── test-target.sh          VM Ubuntu locale (Lima) pour tester l'engine
│   └── tests/                    Suite de tests (bash pur, aucune dépendance)
├── runs/                       Workspaces (gitignoré) : runs/<ws>/{env,spec}.json
├── docs/                       Documentation du projet (ce dossier)
└── web/                        Interface Flask — CASSÉE, ne pas réparer (voir en-tête)
```

`web/`, `bootstrap.sh` et `lib/` à la racine du dépôt sont l'**ancien**
système Kubernetes ; ils restent sur disque pour l'historique mais ne sont
plus le point d'entrée. Tout ce qui est actif vit sous `engine/`.

---

## Format de configuration

Deux fichiers JSON par workspace, **jamais chargés par `source`** — lus avec
`jq`, ce qui ferme la classe d'injection qu'un `.bootstrap-env` shell
autorisait (voir [Sécurité](#sécurité)) :

- **`runs/<ws>/env.json`** — paramètres d'exécution et secrets : cible SSH,
  identifiants du registre, ports hôtes alloués par service, limites de
  ressources, bloc GitHub optionnel.
- **`runs/<ws>/spec.json`** — description de l'application : ses services,
  chacun avec un `id`, soit `build` (nos sources, durcissement complet) soit
  `image` (image tierce, durcissement partiel), un `port` conteneur, un
  `health` optionnel, un `expose` optionnel (chemin public → port hôte
  publié).

Les deux schémas complets, commentés, avec les règles de validation exactes
(`spec_init` rejette par exemple tout id de service hors
`[A-Za-z0-9_-]+`), sont dans [`docs/ENGINE.md`](docs/ENGINE.md#2-entrées).

`runs/` doit être en `700`, les deux fichiers JSON en `600`.

---

## Skills Claude Code générées

Chaque projet déployé reçoit **5 Skills** dans `.agents/skills/` (et un
symlink `.claude/skills/` pour la compatibilité Claude Code) :

| Skill | Rôle |
|---|---|
| `microservice-editor` | Modifie le code de l'API (Express) ou du Front (HTML) en suivant les conventions du projet |
| `github-flow` | Commits conventionnels + push sur `main` (si le bloc GitHub est activé) |
| `docker-deploy` | Déploie une nouvelle version via `DOCKER_HOST=ssh://` + `docker compose up -d` |
| `health-monitor` | Vérifie la santé post-déploiement |
| `rollback-manager` | Rollback ciblé en réécrivant `IMAGE_TAG` dans `deploy/.env` (les 5 derniers tags sont conservés dans `deploy/.image-history`) |

```bash
cd runs/<ws>/<app.name>
claude
> "Ajoute une route /stats à l'API, déploie, vérifie la santé"
```

---

## Sécurité

Résumé — le détail complet, avec ce qui est en place, prévu, ou un écart
documenté, est dans [`docs/SECURITY.md`](docs/SECURITY.md).

- **Plus de `source` de configuration.** L'ancien `.bootstrap-env` shell
  s'exécutait au chargement (`$(...)` s'évaluait) ; `env.json`/`spec.json`
  sont lus avec `jq --arg`, qui ne traverse jamais l'évaluateur du shell.
- **Le socket Docker n'est jamais monté.** L'engine pilote Docker à distance
  par `DOCKER_HOST=ssh://user@host`, y compris pour un hôte local — un seul
  chemin de code, aucune exception. Monter `/var/run/docker.sock` donnerait
  l'équivalent de `root` sur l'hôte à quiconque contrôle le conteneur.
- **Durcissement des conteneurs, en deux niveaux.** Les services **buildés**
  (nos sources, clé `build` du spec) reçoivent le durcissement complet :
  utilisateur non-root (UID 1000), système de fichiers en lecture seule,
  toutes les capabilities Linux retirées, `no-new-privileges`. Les services
  sur **image tierce** (clé `image`) ne reçoivent que `no-new-privileges` :
  forcer l'UID et le read-only sur une image dont on ne maîtrise pas le
  Dockerfile la casse en général (exemple concret :
  `postgres:16-alpine` tourne en UID 70 et doit posséder son datadir en
  écriture). Ce n'est pas un oubli, c'est un arbitrage documenté dans
  [`docs/SECURITY.md`](docs/SECURITY.md#3--durcissement-des-conteneurs-applicatifs).
- **Un port hôte doit être ≥ 1024.** Les conteneurs buildés tournent en UID
  1000, qui ne peut pas binder un port privilégié ; `cfg_port` refuse tout ce
  qui est hors de `[1024, 65535]` avec un code 2.
- **Le token du registre ne transite jamais par la ligne de commande SSH** —
  il est envoyé sur stdin, jamais en argument (visible dans `ps` sinon).
- **Validation du nom de workspace.** `--workspace` devient un nom de
  répertoire ; une regex stricte ferme `--workspace ../../etc`.

---

## Pré-requis

### Poste local (celui qui lance `engine/bootstrap.sh`)

```bash
# macOS
brew install git jq

# Ubuntu / Debian
sudo apt install git jq curl ssh
```

Optionnels selon le bloc utilisé :

- `gh` (CLI GitHub) — seulement si `github.enabled: true`.
- `sshpass` — seulement si `target.auth_method: "password"`.
- `docker` + plugin `compose` — l'engine pilote la cible à distance, mais
  `check_prereqs` vérifie leur présence locale (le worker du jalon 2 les
  embarquera dans son image).

### Serveur cible

- Ubuntu 22.04+ (ou Debian 12+), un utilisateur avec sudo (`devops` par
  défaut).
- Accès SSH par **clé OU mot de passe**.
- `sudo NOPASSWD` configuré pour l'utilisateur SSH — l'étape
  `enable_sudo_nopasswd` détecte l'absence et affiche la commande à coller.
- Rien d'autre : `prepare_server` installe Docker CE, le plugin Compose, ufw
  et fail2ban tout seul sur une machine vierge.

Pas de serveur sous la main ? `engine/tools/test-target.sh up` fournit une VM
Ubuntu locale reproductible — voir [`docs/TEST-TARGET.md`](docs/TEST-TARGET.md).

---

## Diagnostic

`engine/lib/diag.sh` fournit trois fonctions de développement — `cmd_doctor`
(contrôle outils locaux + SSH + démon Docker distant + `compose.yml` +
conteneurs + endpoints), `cmd_logs` (`docker compose logs -f`) et
`cmd_stack_info` (état de la stack). Elles écrivent sur stderr et ne
respectent pas le contrat JSON du §[Ce que fait l'engine](#ce-que-fait-lengine)
— ce ne sont **pas** des étapes, et il n'existe **pas encore** de sous-commande
`bootstrap.sh` pour les invoquer (le dispatcher n'accepte que `--step`,
`--all`, `--list-steps`, `--dry-run`, `--help`). Elles servent au
développement de l'engine lui-même ; le panel du jalon 2 les remplacera par
de vraies vues.

---

## Dépannage

| Problème | Solution |
|---|---|
| `--workspace <nom>` refusé | Le nom doit matcher `^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$` — pas de `/`, pas de `..`, pas de préfixe `-` |
| `paramètre requis manquant dans env.json : ...` | Un champ `cfg_req` est absent ou vide — voir le schéma dans [`docs/ENGINE.md`](docs/ENGINE.md#21-schéma-envjson) |
| `port hôte hors plage pour '<id>'` | Un port dans `env.json .ports` doit être dans `[1024, 65535]` |
| `sudo NOPASSWD requis pour ...` | Colle la commande affichée par l'étape sur le serveur, en root |
| `Permission denied (publickey)` sur `build_images`/`deploy_stack` alors que `validate_ssh` a réussi | Piège connu de `DOCKER_HOST=ssh://` : le CLI `docker` ne sait pas passer `-i`, il faut soit un `ssh-agent` avec la clé chargée, soit un alias `~/.ssh/config` avec `IdentityFile` qui matche `target.host` — détail dans [`docs/ENGINE.md`](docs/ENGINE.md#6-docker_hostssh--ce-qui-a-été-vérifié-en-conditions-réelles) |
| `services non sains : ...` juste après un déploiement | Souvent transitoire : le healthcheck met jusqu'à ~50 s à passer `starting` → `healthy`. C'est un échec **réessayable** (code 1) — relancer l'étape après quelques secondes |
| `docker compose config --quiet` échoue sur `deploy/compose.yml` | Le fichier généré est invalide — relancer `--step generate_compose` et lire le message d'erreur `jq`/Compose |
| `outils manquants : ...` (`check_prereqs`) | Installer ce qui manque ; `docker-compose-plugin` est un plugin, pas un binaire du PATH — `docker compose version` doit fonctionner |
| Interface web ne démarre pas / erreurs Flask | Normal, voir l'encadré en tête de ce README — `web/` est cassé jusqu'au jalon 2, ne pas le réparer |

---

## Documentation complète

- [`docs/ENGINE.md`](docs/ENGINE.md) — référence complète du contrat de
  l'engine : invocation, schémas `env.json`/`spec.json`, sorties, codes de
  sortie, chaque étape en détail, ce que l'engine ne fait pas.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — architecture cible sur six
  jalons (panel Python, worker, BunkerWeb) et ce qui existe déjà.
- [`docs/SECURITY.md`](docs/SECURITY.md) — modèle de menace complet.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — les six jalons.
- [`docs/CURRENT-STATE.md`](docs/CURRENT-STATE.md) — état factuel daté du
  jalon 1.
- [`docs/JALON-1-VERIFICATION.md`](docs/JALON-1-VERIFICATION.md) — état de
  vérification des sept critères d'acceptation du jalon 1.
- [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md) — règles de développement
  (bash 3.2, invariant stdout, convention « step pure »).
- [`docs/TEST-TARGET.md`](docs/TEST-TARGET.md) — VM Ubuntu locale pour tester
  l'engine sans serveur réel.
- [`docs/TEAM-SPLIT.md`](docs/TEAM-SPLIT.md) — répartition entre les rôles du
  projet.

---

## Licence

MIT.
