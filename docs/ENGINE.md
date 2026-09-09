# `engine/` — contrat de référence

Document de référence pour quiconque écrit un appelant de l'engine — le worker
Python du panneau (jalon 2), un script de test, un humain en ligne de commande.
Il décrit **ce que le code fait aujourd'hui**, pas une intention : chaque
affirmation ci-dessous a été vérifiée en lisant `engine/lib/*.sh` et en
exécutant l'engine, pas en relisant un plan.

Pour le contexte plus large (pourquoi Python orchestre et bash exécute,
topologie réseau, `DOCKER_HOST=ssh://`, durcissement des conteneurs), voir
[`ARCHITECTURE.md`](ARCHITECTURE.md) et [`SECURITY.md`](SECURITY.md). Ce
document-ci se concentre sur le contrat d'appel, étape par étape.

---

## 1. Invocation

```bash
engine/bootstrap.sh --workspace <ws> --step <nom>      # exécute UNE étape
engine/bootstrap.sh --workspace <ws> --all              # exécute toute la séquence (test de l'engine seul)
engine/bootstrap.sh --list-steps                         # liste les étapes connues, une par ligne
engine/bootstrap.sh --workspace <ws> --step <nom> --dry-run   # n'exécute rien de destructif
engine/bootstrap.sh --help
```

`<ws>` doit correspondre à `^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$` et désigner un
répertoire existant sous `runs/<ws>/` — l'engine ne le crée jamais lui-même.
C'est une défense en profondeur : le panel valide déjà le nom d'application
(jalon 2), mais l'engine ne fait jamais confiance à son appelant.

**`--all` n'est pas le chemin nominal.** Le panel n'appelle jamais `--all` : il
appelle `--step` une fois par étape, en lisant la ligne JSON entre chaque
appel. `--all` existe uniquement pour tester l'engine seul, en CLI, sans
lancer la stack Python — c'est aussi ce qui a servi à produire
[`JALON-1-VERIFICATION.md`](JALON-1-VERIFICATION.md).

---

## 2. Entrées

Deux fichiers JSON dans `runs/<ws>/`, **écrits par l'appelant**, **lus avec
`jq`**, jamais avec `source` :

| Fichier | Rôle | Permissions attendues |
|---|---|---|
| `env.json` | paramètres d'exécution et secrets : cible SSH, registre, ports alloués, limites, bloc GitHub optionnel | `600` |
| `spec.json` | description de l'application : ses services, leurs ports, leurs chemins publics | `600` |

Il n'existe **aucun autre canal d'entrée** : pas de variable d'environnement
de configuration, pas de fichier `source`, pas de prompt interactif. C'est ce
qui ferme la classe d'injection décrite dans
[`SECURITY.md`](SECURITY.md#1--linjection-par-bootstrap-env-est-fermée) : une
valeur qui contiendrait `$(...)` reste une chaîne littérale de bout en bout,
`jq --arg` ne l'évalue jamais.

### 2.1 Schéma `env.json`

Champs lus par `engine/lib/config.sh` (`cfg`/`cfg_req`/`cfg_bool`/`cfg_port`)
et par `engine/lib/ssh_remote.sh` (`_target_port`, `docker_host_url`).

```jsonc
{
  // Identité de l'application. app.name devient APP_NAME (préfixe d'images,
  // nom de projet Compose) ET le nom du sous-dossier de travail sous
  // runs/<ws>/<app.name>/.
  "app": {
    "name": "tp-app",
    "author": "Alex Falzon"
  },

  // La cible SSH sur laquelle tout est déployé. C'est la SEULE cible : il
  // n'y a pas de notion de "hôte local" distincte, y compris pour du
  // 127.0.0.1 — voir §6.
  "target": {
    "host": "1.2.3.4",             // IP, hostname, OU un alias d'~/.ssh/config
    "user": "devops",
    "auth_method": "key",          // "key" ou "password"
    "ssh_key_path": "/home/alex/.ssh/id_ed25519",  // utilisé si auth_method = "key"
    "password": "",                // utilisé si auth_method = "password"
    "port": 22,                    // OPTIONNEL, défaut 22 (cfg target.port 22)
    "bind_addr": "0.0.0.0"         // interface de publication des ports hôtes
  },

  // Docker Hub (ou tout registre compatible). registry.token vide = pas de
  // push (build_images se contente d'images locales à la cible).
  "registry": {
    "user": "dockerhubuser",
    "token": "dckr_pat_…"
  },

  // Bloc GitHub, ENTIÈREMENT OPTIONNEL — voir §5.5. Si enabled=false, les
  // quatre étapes github_* et git_* deviennent des no-op (emit_ok skipped).
  "github": {
    "enabled": false,
    "user": "",
    "repo": "",
    "token": ""
  },

  // Port HÔTE alloué à chaque service exposé, par id de service. L'engine ne
  // choisit JAMAIS un port : il le reçoit ici. cfg_port refuse tout ce qui
  // n'est pas un entier dans [1024, 65535].
  "ports": {
    "api": 10001,
    "web": 10002
  },

  // Limites en unités KUBERNETES (héritage assumé, cf. ARCHITECTURE.md §8),
  // converties par engine/lib/units.sh vers les unités Compose.
  "limits": {
    "cpu": "200m",
    "memory": "128Mi"
  },

  // Décisions qui étaient un prompt interactif dans l'ancienne version :
  // reuse_existing_dir pour create_project_dir, allow_existing_repo pour
  // github_create_repo.
  "options": {
    "reuse_existing_dir": true,
    "allow_existing_repo": true
  }
}
```

Notes de lecture, vérifiées dans le code :

- `cfg CHEMIN [DÉFAUT]` renvoie le défaut si la valeur est absente **ou
  vide** — pas de distinction entre `"target.port"` absent et `""`.
- `cfg_req CHEMIN` meurt fataliment (code 2) si la valeur résolue est vide.
- `cfg_port SERVICE_ID` lit `.ports.<service_id>`, refuse le non-numérique et
  hors de `[1024, 65535]`, meurt en code 2 sinon — jamais un port < 1024,
  parce que les conteneurs buildés tournent en UID 1000.
- `target.port` est **optionnel** ; son absence vaut `22`. Une cible qui
  n'expose pas le port 22 (VM Lima locale, par exemple) doit soit le
  déclarer ici, soit passer par un alias `~/.ssh/config` — voir §6 pour le
  piège que ça peut cacher avec `DOCKER_HOST=ssh://`.

### 2.2 Schéma `spec.json`

Champs lus par `engine/lib/config.sh` (`spec_init`, `spec_get`,
`spec_service_ids`, `spec_is_internal`, `spec_is_exposed`,
`spec_exposed_ids_by_path_length`).

```jsonc
{
  "name": "tp-app",              // nom logique ; n'est pas relu ailleurs dans l'engine
  "services": [
    {
      "id": "api",                // ^[A-Za-z0-9_-]+$, UNIQUE — spec_init meurt (code 2) sinon.
                                   // Sert de clé Compose, de suffixe d'image, de clé dans
                                   // env.json .ports.
      "build": "./services/api",  // service BUILDÉ → durcissement complet (voir SECURITY.md)
                                   // XOR "image" : il faut l'un des deux, spec_init/
                                   // gen_compose meurent (code 2) si aucun n'est présent.
      "port": 3000,                // port CONTENEUR ; injecté en variable PORT pour un
                                   // service buildé
      "health": "/health",         // chemin de santé HTTP, utilisé par le healthcheck
                                   // Compose ET par validate_deployment
      "expose": "/api/",           // chemin PUBLIC → un port hôte (env.json .ports) lui
                                   // est alloué et publié. Absent = pas de port publié.
      "env": { "NODE_ENV": "production" }   // variables d'environnement du conteneur
    },
    {
      "id": "web",
      "build": "./services/web",
      "port": 8080,
      "health": "/",
      "expose": "/"
    },
    {
      "id": "db",
      "image": "postgres:16-alpine",   // service sur IMAGE TIERCE → durcissement PARTIEL
      "internal": true,                // AUCUN port publié, joignable seulement par les
                                        // autres services du réseau Docker de l'app
      "env": { "POSTGRES_PASSWORD": "changeme" },
      "volumes": ["pgdata:/var/lib/postgresql/data"]
    }
  ]
}
```

Ce que `spec_init` rejette explicitement, avec code 2 :

- `services` absent, pas un tableau, ou vide ;
- un id de service hors `[A-Za-z0-9_-]+` (défense en profondeur contre
  l'injection YAML décrite dans `gen_compose.sh` — l'id sert de clé de
  mapping YAML brute) ;
- des ids de service dupliqués.

`spec_get SID CHAMP [DÉFAUT]` distingue **champ absent** (→ défaut), **champ
null** (→ défaut) et **champ présent avec une valeur fausse/vide** (→ cette
valeur, pas le défaut) — un `"health": ""` explicite n'est donc pas remplacé
par un défaut, contrairement à `"health"` absent.

`engine/templates/spec.demo.json` est l'exemple ci-dessus (services `api` +
`web`, sans le `db`) ; la fixture `engine/tests/fixtures/spec.multi.json`
ajoute le cas `db` sur image tierce et un service de test qui couvre les
valeurs falsy (`""`, `false`, `null`, `0`).

---

## 3. Sorties

- **stderr** : tous les logs, en clair, ligne par ligne, via les helpers
  `ui_step`/`ui_info`/`ui_ok`/`ui_warn`/`ui_err`/`ui_skip`
  (`engine/lib/ui.sh`). C'est ce que l'appelant streame (SSE côté panel).
- **stdout** : **exactement une** ligne JSON par appel `--step`, en fin
  d'exécution :

  ```json
  {"ok": true,  "data": {"services_ok": 2}}
  {"ok": false, "error": "le service 'api' ne répond pas sur 127.0.0.1:10001/health"}
  ```

  `data` peut être `null` (`emit_ok` sans argument, ou argument qui n'est pas
  du JSON valide — remplacé silencieusement par `null` plutôt que de
  corrompre la ligne).

Cet invariant n'est pas une discipline d'écriture, c'est du code
(`engine/lib/runtime.sh`) :

- un `trap ERR` (`error_handler`) transforme toute commande qui échoue sous
  `set -e` en `{"ok":false,…}` ;
- un `trap EXIT` (`_exit_guard`) rattrape ce qui **ne passe pas** par `ERR` —
  typiquement une variable non liée sous `set -u`. Sans lui, l'engine
  pourrait sortir sans la moindre ligne JSON ;
- un drapeau `_RESULT_EMITTED`, réarmé à chaque étape (`_runtime_begin_step`,
  appelé par le dispatcher juste avant chaque `step_*`), empêche la double
  émission — y compris en mode `--all`, où plusieurs étapes partagent le
  même process.

**Cas particulier de `--all`** : il imprime une ligne JSON **par étape**, donc
plusieurs lignes sur stdout — une entorse assumée au contrat, réservée au
test de l'engine seul. Le panel n'appelle jamais `--all`.

---

## 4. Codes de sortie

| Code | Sens | Réaction attendue de l'appelant |
|---|---|---|
| `0` | succès | passer à l'étape suivante |
| `1` | échec **réessayable** (`retryable`) | retry avec backoff |
| `2` | échec **fatal** (`die`, défaut de `die` si omis) | arrêt du run, intervention humaine |

Dans le code : `retryable MESSAGE` émet `{"ok":false,…}` et sort en 1 ; `die
MESSAGE [CODE]` fait de même et sort en 2 par défaut ; le `trap ERR` produit
un 1 (une commande qui échoue de façon inattendue est traitée comme
réessayable — seuls les refus explicites et nommés sont fatals). Exemple
vécu pendant la vérification de ce document :
`step_validate_deployment` a échoué en `1` juste après un `deploy_stack` tout
frais, parce que les conteneurs étaient encore dans l'état de santé
`starting` (healthcheck `start_period: 5s`, `retries: 5`) — un retry quelques
secondes plus tard est passé au vert sans aucune intervention. C'est
exactement le comportement que le code 1 est censé produire.

---

## 5. Les étapes

Liste produite par `bash engine/bootstrap.sh --list-steps` (ordre = ordre
d'exécution de `--all`) :

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

Pour chacune : ce qu'elle lit dans `env.json`/`spec.json`, ce qu'elle renvoie
dans `data`. « Réseau » = elle contacte réellement la cible (jamais en
`--dry-run`, qui court-circuite ces étapes-là et renvoie `{"dry_run":true}`).

| Étape | Réseau ? | Consomme | `data` en cas de succès |
|---|---|---|---|
| `check_prereqs` | non | `github.enabled`, `target.auth_method` (pour savoir si `gh`/`sshpass`/`ssh-keygen` sont requis) | `{"checked": N}` — nombre d'outils vérifiés |
| `validate_ssh` | oui | `target.host`, `target.user` (+ `auth_method`/`ssh_key_path` ou `password`/`port` via `ssh_remote`) | `{"banner": "<hostname> — <os>"}` |
| `create_project_dir` | non | `app.name` (→ `WORK_DIR`), `options.reuse_existing_dir` | `{"work_dir": "<chemin absolu>"}` |
| `generate_microservices` | non | `spec.json` entier (ports `api`/`web` par défaut 3000/8080 si absents), `app.author` | `{"services_dir": "<chemin>"}` |
| `generate_compose` | non | `spec.json` entier, `registry.user`, `target.bind_addr`, `limits.cpu`, `limits.memory`, `.ports.<sid>` pour chaque service exposé | `{"compose_file": "<chemin>"}` |
| `generate_skills` | non | rien (générique, indépendant du spec) | `{"skills": 5}` |
| `generate_workflow` | non | `app.name`, `target.auth_method`, `spec.json` (services exposés + `health`), `env.json .ports` | `{"workflow": "<chemin>"}` |
| `enable_sudo_nopasswd` | oui | `target.host`, `target.user` | `{"already_configured": true}` — ou meurt en 2 avec la commande à coller manuellement si `sudo -n` échoue |
| `prepare_server` | oui | `target.host`, `target.user`, `registry.user`, `registry.token` (passés sur **stdin**, jamais en argument SSH) | `{"host": "<host>"}` |
| `build_images` | oui | `spec.json` (services, `build`/`image`), cible via `DOCKER_HOST=ssh://` (§6), `registry.token` (optionnel, pour le push) | `{"built": N}` — nombre de services du spec |
| `deploy_stack` | oui | `deploy/compose.yml` + `deploy/.env` déjà générés, `app.name`, cible via `DOCKER_HOST=ssh://` | `{"project": "<app.name>"}` |
| `validate_deployment` | oui | `spec.json` (services exposés, `health`), `env.json .ports`, `target.host`/`user` | `{"services_ok": N}` |
| `github_create_repo` | oui, si activé | `github.enabled` (sinon skip), `github.user`, `github.repo`, `github.token`, `options.allow_existing_repo` | `{"repo": "<user>/<repo>", "created": bool}` ou `{"skipped": true}` |
| `github_set_secrets` | oui, si activé | `github.*`, `registry.user`/`token`, `target.host`/`user`, `target.auth_method` + `ssh_key_path` ou `password` | `{"secrets": N}` ou `{"skipped": true}` |
| `git_init` | non (locale) | `github.user`, `github.repo` | `{"remote": "<url .git>"}` ou `{"skipped": true}` |
| `git_push` | oui, si activé | `github.user`, `github.token`, `github.repo` | `{"repo_url": "<url>"}` ou `{"skipped": true}` |

Les quatre dernières étapes forment le **bloc GitHub, entièrement
optionnel** : si `github.enabled` est faux, chacune renvoie
immédiatement `{"ok":true,"data":{"skipped":true}}` sans toucher au réseau.
Décision d'architecture assumée : GitHub est un extra, le panel déploie
lui-même via `build_images` + `deploy_stack` ; une panne GitHub ne doit
jamais empêcher une application de tourner.

---

## 6. `DOCKER_HOST=ssh://` — ce qui a été vérifié en conditions réelles

`build_images` et `deploy_stack` pilotent Docker sur la cible via
`DOCKER_HOST=ssh://<user>@<host>:<port>` (`docker_host_url`,
`engine/lib/ssh_remote.sh`) — **jamais** via un socket monté. Voir
[`SECURITY.md`](SECURITY.md#4-le-socket-docker-nest-jamais-monté) pour le
pourquoi.

**Point vérifié pour la première fois lors de la rédaction de ce document**
(voir [`JALON-1-VERIFICATION.md`](JALON-1-VERIFICATION.md) pour le détail
complet) : le transfert du contexte de build par SSH fonctionne. Mais il y a
un piège d'identité SSH à connaître, propre à `DOCKER_HOST=ssh://` :

- `ssh_remote`/`scp_remote` (utilisés par `validate_ssh`,
  `enable_sudo_nopasswd`, `prepare_server`, `validate_deployment`) passent
  **explicitement** `-i "$(cfg_req target.ssh_key_path)"` à `ssh`. Un
  `target.host` en IP brute fonctionne très bien avec eux.
- Le CLI `docker`, lui, construit **son propre** appel `ssh` en interne à
  partir de la seule URL `ssh://user@host:port` — il n'existe **aucune
  syntaxe** dans une URL `ssh://` pour lui faire passer `-i`. Cet appel
  interne ne peut donc s'authentifier que si l'identité est résolue par
  ailleurs : un `ssh-agent` avec la clé chargée, **ou** une entrée
  `Host <nom> … IdentityFile …` dans `~/.ssh/config` qui matche le
  `target.host` déclaré.

Concrètement : si `target.host` est une IP brute et que la clé n'est ni dans
l'agent ni dans un chemin par défaut (`~/.ssh/id_rsa`, `~/.ssh/id_ed25519`…),
`build_images`/`deploy_stack` échouent en `Permission denied (publickey)`
alors même que `validate_ssh` (qui, lui, passe `-i` explicitement) vient de
réussir sur la même cible l'instant d'avant. C'est précisément ce qui a été
observé en testant contre la VM Lima : `target.host="127.0.0.1"` faisait
réussir `validate_ssh` mais échouer `build_images`, jusqu'à basculer
`target.host` sur l'alias `~/.ssh/config` prévu à cet effet (voir
[`TEST-TARGET.md`](TEST-TARGET.md)) — après quoi les deux ont fonctionné.

**Ce que ça implique pour un appelant réel (jalon 2)** : soit la clé SSH du
worker vit dans un chemin par défaut d'OpenSSH ou dans un agent partagé, soit
`target.host` doit résoudre vers une entrée `~/.ssh/config` qui porte
`IdentityFile`. Un `target.ssh_key_path` à un emplacement arbitraire, avec
une IP brute en `target.host` et sans agent, est un cas qui **casse
`build_images`/`deploy_stack` silencieusement du point de vue de l'appelant**
(l'erreur vient de Docker, pas d'un die() de l'engine) alors que
`validate_ssh` aurait laissé croire que tout allait bien. À traiter au jalon
2, quand le worker gère vraiment des clés variables par cible.

---

## 7. Ce que l'engine ne fait pas

- Il n'écrit dans aucune base de données et ne connaît pas l'existence du
  panel.
- Il ne choisit jamais un port : il les reçoit dans `env.json .ports`.
  `cfg_port` refuse tout port hôte hors de `[1024, 65535]`.
- Il ne pose aucune question à un humain : aucun prompt, aucun TTY supposé.
  Toute décision qui était un prompt interactif dans l'ancienne version
  Kubernetes est devenue soit une clé d'`env.json` (`options.*`), soit un
  échec fatal accompagné de la marche à suivre manuelle.
- Il ne monte **jamais** `/var/run/docker.sock` — ni pour une cible distante,
  ni pour l'hôte local, qui est une cible SSH comme une autre
  (`DOCKER_HOST=ssh://`, un seul chemin de code, aucune exception).
- Il ne trace pas d'état entre deux invocations : pas de fichier
  `.bootstrap-state`, pas d'idempotence côté engine. L'idempotence des
  générateurs (`generate_*`) vient du fait qu'ils réécrivent leur sortie à
  chaque appel ; celle des autres étapes (`already_configured`, `docker
  compose up -d` qui ne recrée pas ce qui tourne déjà) vient des outils
  qu'elles appellent, pas d'un mécanisme de l'engine lui-même.
- Il n'authentifie pas son appelant. Rien n'empêche un utilisateur local
  d'invoquer `bootstrap.sh` directement : c'est voulu, le contrôle d'accès
  est le métier du panel (jalon 2) — voir
  [`SECURITY.md`](SECURITY.md#10-ce-qui-nest-pas-protégé-aujourdhui).
- Il ne source **jamais** un fichier de configuration. `env.json` et
  `spec.json` sont lus avec `jq`, jamais évalués par le shell.

---

## 8. Documents liés

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — le contrat de l'engine resitué dans
  l'architecture cible complète (panel, worker, BunkerWeb).
- [`SECURITY.md`](SECURITY.md) — le modèle de menace : pourquoi JSON plutôt
  que `source`, pourquoi jamais de socket Docker monté.
- [`CONVENTIONS.md`](CONVENTIONS.md) — comment écrire une étape qui respecte
  ce contrat (invariant stdout/stderr, compatibilité bash 3.2, convention «
  step pure »).
- [`TEST-TARGET.md`](TEST-TARGET.md) — la cible SSH de test utilisée pour
  vérifier ce document.
- [`JALON-1-VERIFICATION.md`](JALON-1-VERIFICATION.md) — l'état de
  vérification des sept critères d'acceptation du jalon 1.
