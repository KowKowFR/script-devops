# Architecture de DeployMatic

Ce document décrit **l'architecture cible** (celle que les six jalons construisent) et
**l'architecture actuelle** (celle qui existe sur disque aujourd'hui). Les deux sont
signalées sans ambiguïté à chaque section : tout ce qui est marqué *cible* n'existe pas
encore.

Le périmètre fonctionnel de référence est [`ROADMAP.md`](ROADMAP.md). L'état réel,
tâche par tâche, est dans [`CURRENT-STATE.md`](CURRENT-STATE.md).

---

## 1. Les deux architectures, en une table

| | Hier (ce que décrit le `README.md` racine) | Cible (jalons 1 → 6) |
|---|---|---|
| Point d'entrée | `./bootstrap.sh`, TUI `gum` interactive | `docker compose up`, panneau web authentifié |
| Orchestration | tableau `PIPELINE` dans `bootstrap.sh` | constante Python `panel/pipeline.py` + table `Step` |
| Cible de déploiement | k3s (Deployments, Services, Ingress, cert-manager) | Docker Compose sur un hôte joint en SSH |
| Configuration | `.bootstrap-env` chargé par `source` | `runs/<ws>/env.json` + `runs/<ws>/spec.json`, lus par `jq` |
| État / idempotence | fichier `.bootstrap-state` | table `Step` en base Postgres |
| Nombre d'applications | une, `tp-devops-agent-ia` codée en dur | N applications, N cibles |
| Exposition publique | Ingress k3s + cert-manager | BunkerWeb en DMZ, reverse proxy par chemin |
| Interface | Flask + SSE dans `web/` | FastAPI + Jinja2 + SSE dans `panel/` |
| Origine du code applicatif | générateur bash figé (Express + nginx) | génération par LLM validée programmatiquement |

**Aujourd'hui**, seule la colonne de gauche a jamais tourné de bout en bout. Le jalon 1
est en cours : l'engine bash a déjà basculé côté configuration JSON et dispatcher, mais
les étapes de déploiement elles-mêmes sont encore les étapes Kubernetes de l'ancien
système (voir [`CURRENT-STATE.md`](CURRENT-STATE.md)).

---

## 2. Vue d'ensemble (cible)

```
                      ┌──────────────────────────────────────────┐
   navigateur ───────▶│  panel   FastAPI + Jinja2 + SSE          │
                      │          auth, specs, runs, logs         │
                      └───────┬───────────────────────┬──────────┘
                              │ enqueue (RQ)          │ SQL
                      ┌───────▼─────────┐     ┌───────▼─────────┐
                      │  redis          │     │  postgres       │
                      │  file + pub/sub │     │  User, Target,  │
                      └───────┬─────────┘     │  App, Run, Step │
                              │               └─────────────────┘
                      ┌───────▼──────────────────────────────────┐
                      │  worker  RQ                              │
                      │  1. écrit runs/<slug>/{spec,env}.json    │
                      │  2. subprocess engine/bootstrap.sh       │
                      │  3. stderr ──▶ log + Redis pub/sub       │
                      │  4. stdout ──▶ 1 ligne JSON ──▶ Step     │
                      └───────┬───────────────────┬──────────────┘
                              │ SSH               │ HTTP :7070
                              ▼                   ▼
                    hôte(s) cible(s)        BunkerWeb 10.13.3.211
                    docker compose          (DMZ, jalon 4)
```

Les quatre conteneurs `panel`, `worker`, `postgres`, `redis` forment la stack lancée par
le `compose.yml` de la racine. `panel` et `worker` partagent la **même image** — seule la
commande diffère (`gunicorn` d'un côté, `rq worker` de l'autre) — et un **volume partagé
`runs/`** : c'est par le système de fichiers que le worker passe les paramètres à l'engine.

Ce qui n'est **pas** dans la stack, et pourquoi :

- **BunkerWeb** tourne déjà sur `10.13.3.211`, en DMZ, avec son API REST sur le port
  `7070`. Le panneau est un client de cette API, pas son hébergeur.
- **Trivy, Grype, Syft** (jalon 6) tournent en conteneurs éphémères **sur l'hôte cible**,
  à la demande. Ce ne sont pas des services permanents.

---

## 3. « Python orchestre, bash exécute »

C'est la décision structurante du projet, et elle mérite d'être justifiée parce qu'elle
va à l'encontre de l'instinct : on ne réécrit pas le bash en Python, on lui **retire une
responsabilité**.

L'ancien `bootstrap.sh` faisait deux choses en même temps : il savait *quoi* faire (le
tableau `PIPELINE`, dix-huit étapes, l'ordre, les dépendances) et *comment* le faire (les
fonctions `step_*`). Cette double casquette produisait trois défauts constatés dans
l'existant :

1. **L'état vivait dans un fichier** (`.bootstrap-state`), avec des identifiants d'étape
   dupliqués entre `PIPELINE`, `state.sh` et le README — d'où le décalage entre les trois.
2. **L'ordre des étapes n'était pas interrogeable** : impossible d'afficher une
   progression fiable dans une UI sans reparser le bash.
3. **Une reprise après crash était impossible à raisonner** : un `Popen` détaché plus un
   fichier PID laissait des runs bloqués pour toujours.

La séparation retenue :

- **Python décide.** La séquence est une constante Python versionnée avec le code
  (`panel/pipeline.py`), les instances d'exécution sont des lignes de la table `Step`.
  L'idempotence n'est plus un fichier d'état, c'est une requête SQL : au lancement d'un
  run, les étapes déjà `ok` pour cette app passent en `skipped`, sauf les générateurs qui
  sont toujours rejoués.
- **Bash exécute.** `engine/bootstrap.sh` ne sait plus faire qu'une chose : exécuter
  **une** étape qu'on lui nomme. Il ne connaît ni la base, ni le panel, ni l'étape
  suivante.

Le bénéfice concret : l'engine reste testable et pilotable seul, en ligne de commande,
sans lancer la stack Python. C'est précisément ce que permet le mode `--all`, qui n'existe
que pour ça.

---

## 4. Le contrat de l'engine

C'est l'interface la plus stable du projet. Elle est déjà implémentée (jalon 1, tâches 3
et 6) et **ne doit jamais être cassée** : le worker du jalon 2, le CI généré et les Skills
générées s'y adossent tous.

### Invocation

```
engine/bootstrap.sh --workspace <ws> --step <nom>     exécute UNE étape
engine/bootstrap.sh --workspace <ws> --all            exécute toute la séquence (test)
engine/bootstrap.sh --list-steps                      liste les étapes connues
engine/bootstrap.sh --workspace <ws> --step <nom> --dry-run
```

### Entrées

Deux fichiers JSON dans `runs/<ws>/`, écrits par l'appelant, lus par `jq` :

| Fichier | Contenu | Permissions |
|---|---|---|
| `env.json` | paramètres d'exécution et secrets (cible SSH, registre, ports alloués, limites) | `600` |
| `spec.json` | description de l'application : ses services, leurs ports, leurs chemins publics | `600` |

Le répertoire `runs/` est en `700`. **Aucun autre canal d'entrée n'existe** : pas de
variable d'environnement de configuration, pas de fichier `source`, pas de prompt.

### Sorties

- **stderr** : tous les logs, en clair, ligne par ligne. C'est ce que le worker streame
  vers le SSE.
- **stdout** : **exactement une** ligne JSON, en fin d'exécution.

```json
{"ok": true,  "data": {"services_ok": 2}}
{"ok": false, "error": "le service 'api' ne répond pas sur 127.0.0.1:10001/health"}
```

L'invariant est protégé par du code, pas par la discipline. `lib/runtime.sh` pose deux
filets :

- un `trap ERR` qui transforme toute commande échouée sous `set -e` en `{"ok":false,…}` ;
- un `trap EXIT` (`_exit_guard`) qui rattrape les sorties qui ne passent **pas** par
  `ERR` — typiquement une variable non liée sous `set -u`. Sans lui, l'engine pourrait
  sortir sans la moindre ligne JSON, ce que le contrat interdit.

Un drapeau `_RESULT_EMITTED` empêche la double émission, et il est **réarmé à chaque
étape** (`_runtime_begin_step`) : en mode `--all`, plusieurs étapes partagent le même
processus, et une garde à l'échelle du processus ferait silencieusement disparaître de
stdout l'échec de toute étape suivant une étape ayant déjà émis.

### Codes de sortie

| Code | Sens | Réaction attendue du worker |
|---|---|---|
| `0` | succès | passer à l'étape suivante |
| `1` | échec **réessayable** | un retry avec backoff |
| `2` | échec **fatal** | arrêt du run |

La distinction est structurante côté appelant : un serveur SSH momentanément injoignable
est un `1`, un `spec.json` invalide est un `2`. Dans le code, `retryable` produit un `1`,
`die` produit un `2` par défaut, et le `trap ERR` produit un `1` — une commande qui échoue
de manière inattendue est considérée réessayable, seuls les refus explicites sont fatals.

### Ce que l'engine n'a pas le droit de faire

- écrire dans une base de données ou connaître l'existence du panel ;
- choisir un port (il les reçoit dans `env.json`) ;
- poser une question à un humain (aucun prompt, aucun TTY supposé) ;
- écrire quoi que ce soit sur stdout en dehors de sa ligne de résultat ;
- charger un fichier de configuration par `source`.

### Le cas particulier de `--all`

`--all` imprime **une ligne JSON par étape**, ce qui viole le contrat « une seule ligne ».
C'est une entorse assumée, documentée dans le code, réservée au test de l'engine seul.
Le worker n'appelle jamais `--all`.

---

## 5. Topologie réseau

```
     Internet
        │
        ▼  :80 / :443
┌───────────────────────────────┐
│  BunkerWeb   10.13.3.211      │   DMZ — API REST sur :7070
│  multisite, un vhost par app  │   (jalon 4)
└───────┬───────────────────────┘
        │  REVERSE_PROXY_HOST_n = http://<hôte cible>:<port hôte>
        ▼
┌───────────────────────────────┐        ┌──────────────────────────┐
│  Hôte cible                   │◀── SSH │  worker (conteneur)      │
│  ufw : 22 + ports alloués     │        │  DOCKER_HOST=ssh://…     │
│  docker compose, 1 réseau/app │        │  aucun docker.sock monté │
└───────────────────────────────┘        └──────────────────────────┘
```

Quatre contraintes découlent de cette topologie, et chacune coûte cher à découvrir tard :

1. **Aucun réseau Docker partagé entre BunkerWeb et les applications.** BunkerWeb est sur
   une autre machine ; il ne peut joindre un conteneur applicatif que par un port publié
   sur une interface joignable depuis `10.13.3.211`. D'où l'obligation de publier des
   ports hôtes, et le champ `target.bind_addr` dans `env.json`.
2. **Un runner GitHub Actions hébergé ne peut pas joindre `10.13.3.211`** — c'est une
   adresse RFC1918. Tout health-check en CI passe donc par **SSH sur l'hôte cible** puis
   `curl` sur `127.0.0.1:<port hôte>`, jamais par une URL publique. Le workflow généré est
   écrit dans ce sens (jalon 1, tâche 12).
3. **L'API BunkerWeb ne doit jamais être exposée sur Internet**, et son allowlist par
   défaut (`API_WHITELIST_IPS`) couvre les plages RFC1918. Le worker l'appelle depuis le
   réseau interne.
4. **L'ouverture ufw doit cibler l'IP source réellement vue par l'hôte cible** (jalon 3).
   Si BunkerWeb sort derrière un NAT ou un bridge Docker, une règle
   `ufw allow from 10.13.3.211` ne matchera pas. À vérifier sur la machine, pas dans un
   schéma.

### Port CONTENEUR ≠ port HÔTE

C'est la distinction la plus facile à confondre et elle a déjà produit un bug dans
l'existant (`API_PORT` < 1024 combiné à `runAsUser: 1000`).

| | Port conteneur | Port hôte |
|---|---|---|
| Où il est déclaré | `spec.json`, champ `port` du service | `env.json`, table `ports.<service_id>` |
| Qui le choisit | l'auteur de l'application | l'humain (jalon 1) puis l'allocateur (jalon 3) |
| Plage | libre, y compris < 1024 en théorie | **≥ 1024 obligatoire**, ≤ 65535 |
| Visibilité | interne au réseau Docker de l'app | publié sur `bind_addr`, joignable par BunkerWeb |
| Contrainte | le conteneur tourne en UID 1000, il ne peut **pas** binder < 1024 | doit être libre sur la cible |

`cfg_port` (dans `engine/lib/config.sh`) refuse tout port hôte non numérique ou hors de
`[1024, 65535]`, avec un code 2. C'est aussi ce qui a imposé la bascule du front sur
`nginxinc/nginx-unprivileged`, qui écoute sur 8080 au lieu de 80.

---

## 6. Pilotage de Docker par `DOCKER_HOST=ssh://`

Le worker **ne monte jamais** `/var/run/docker.sock`. Nulle part, dans aucun service de la
stack.

La raison est directe : monter le socket Docker dans un conteneur donne à ce conteneur
l'équivalent de `root` sur la machine hôte — il peut démarrer un conteneur privilégié qui
monte `/`. Or le panneau est, par construction, un service qui exécute du code fourni par
un formulaire web, et au jalon 5 ce code sera écrit par un LLM. Le socket serait le
chaînon qui transforme une injection en compromission de l'hôte du panneau.

À la place :

```bash
docker_host_url() { printf 'ssh://%s@%s' "$(cfg_req target.user)" "$(cfg_req target.host)"; }
docker_remote()   { DOCKER_HOST="$(docker_host_url)" docker "$@"; }
```

Deux propriétés en découlent :

- **L'hôte local est une cible comme une autre.** Il se déclare avec `is_local: true` et
  un `DOCKER_HOST=ssh://user@172.17.0.1`. Il n'y a qu'un seul chemin de code, donc un seul
  chemin à tester et à sécuriser.
- **Le build se fait sur la cible.** `docker compose --file <chemin local>` lit le fichier
  localement et envoie le **contexte de build par SSH**. Le worker n'a pas besoin de
  copier le projet sur la cible, et il ne compile jamais rien lui-même. C'est le premier
  des quatre invariants du jalon 5.

> *Non vérifié à ce jour* : le transfert du contexte de build par `DOCKER_HOST=ssh://`
> n'a jamais été exercé faute de cible SSH de test. C'est le point le plus incertain du
> jalon 1 (voir [`CURRENT-STATE.md`](CURRENT-STATE.md)).

---

## 7. `spec.json` — ce que l'application *est*

`spec.json` décrit les services de l'application. Il remplace le couple « api + web »
codé en dur dans l'ancien générateur : une application produite par un LLM au jalon 5
n'aura pas toujours cette forme.

Voici `engine/templates/spec.demo.json`, l'app de démo, commenté (le JSON réel ne porte
évidemment pas de commentaires) :

```jsonc
{
  "name": "tp-app",                  // nom logique de l'application
  "services": [
    {
      "id": "api",                   // identifiant : clé dans env.json .ports,
                                     // nom du service Compose, suffixe de l'image
      "build": "./services/api",     // service BUILDÉ : durcissement complet appliqué
      "port": 3000,                  // port CONTENEUR ; injecté en variable PORT
      "health": "/health",           // chemin de santé, sert au healthcheck ET au curl
      "expose": "/api/",             // chemin PUBLIC → un port hôte lui est alloué
      "env": { "NODE_ENV": "production" }
    },
    {
      "id": "web",
      "build": "./services/web",
      "port": 8080,                  // 8080 et pas 80 : nginx-unprivileged, UID 1000
      "health": "/",
      "expose": "/"
    }
  ]
}
```

Et un troisième service, tiré de la fixture `engine/tests/fixtures/spec.multi.json`, qui
montre le cas « image tierce interne » :

```jsonc
{
  "id": "db",
  "image": "postgres:16-alpine",     // service sur IMAGE : durcissement PARTIEL
  "internal": true,                  // aucun port publié, joignable par les autres
                                     // services via le réseau Docker de l'app
  "env": { "POSTGRES_PASSWORD": "changeme" },
  "volumes": ["pgdata:/var/lib/postgresql/data"]
}
```

Sémantique à retenir :

| Champ | Effet |
|---|---|
| `build` | le service est construit depuis nos sources → durcissement complet |
| `image` | image tierce → durcissement partiel (voir [`SECURITY.md`](SECURITY.md)) |
| `expose` | chemin public : un **port hôte** est alloué et publié |
| `internal: true` | **aucun** port publié |
| `port` | port **conteneur** |
| `health` | chemin HTTP de santé, sans dépendance externe |

Les helpers de lecture vivent dans `engine/lib/config.sh` : `spec_init`, `spec_service_ids`,
`spec_get`, `spec_is_internal`, `spec_is_exposed`, et `spec_exposed_ids_by_path_length`.
Ce dernier trie les services exposés par **longueur de chemin décroissante** : le plus
spécifique d'abord. C'est une dette payée d'avance pour le jalon 4, où la précédence des
reverse proxies BunkerWeb numérotés ne doit pas dépendre de l'ordre de déclaration dans
le spec.

`spec_init` refuse un `spec.json` sans tableau `services` non vide, et refuse les
identifiants de service dupliqués — les deux avec un code 2.

---

## 8. `env.json` — comment et où l'application est déployée

```jsonc
{
  "app":    { "name": "tp-app", "author": "Alex Falzon" },

  "target": { "host": "1.2.3.4",
              "user": "devops",
              "auth_method": "key",          // "key" ou "password"
              "ssh_key_path": "/Users/…/.ssh/id_ed25519",
              "password": "",                // utilisé si auth_method = password
              "bind_addr": "0.0.0.0" },      // interface de publication des ports hôtes

  "registry": { "user": "dockerhubuser", "token": "dckr_pat_…" },

  "github": { "enabled": false,              // GitHub est OPTIONNEL depuis le jalon 1
              "user": "", "repo": "", "token": "" },

  "ports":  { "api": 10001, "web": 10002 },  // service_id → port HÔTE. L'engine ne
                                             // choisit JAMAIS un port, il les reçoit.
  "limits": { "cpu": "200m", "memory": "128Mi" },   // unités k8s, converties par units.sh

  "options": { "reuse_existing_dir": true, "allow_existing_repo": true }
}
```

Deux points non évidents :

- **`ports` vient de l'humain au jalon 1**, de la table `PortAllocation` au jalon 3. Le
  contrat ne change pas entre les deux : c'est toujours l'appelant qui décide.
- **`limits` reste en unités Kubernetes** alors que la cible est Compose. Ce n'est pas un
  oubli : c'est la forme dans laquelle les limites arrivaient de l'existant, et
  `engine/lib/units.sh` fait la conversion (`200m` → `0.2`, `128Mi` → `128m`). Garder les
  unités d'origine évite une migration de données pour rien.

Les clés se lisent par chemin pointé : `cfg target.host`, `cfg_req app.name`,
`cfg_bool github.enabled`, `cfg_port api`.

---

## 9. Déploiement et rollback par `IMAGE_TAG`

Le générateur `lib/gen_compose.sh` (jalon 1, tâche 8) produit trois fichiers dans
`$WORK_DIR/deploy/` :

| Fichier | Rôle |
|---|---|
| `compose.yml` | la stack de l'application, un service par entrée de `spec.json` |
| `.env` | **une seule ligne** : `IMAGE_TAG=latest` — en `600`, non committé |
| `.env.example` | la même ligne, commentée, committable |

Dans `compose.yml`, chaque service buildé porte :

```yaml
image: <registry_user>/<app_name>-<service_id>:${IMAGE_TAG}
```

`${IMAGE_TAG}` arrive **littéral** dans le YAML : c'est **Compose** qui l'interpole depuis
`deploy/.env`, pas bash. (Dans le générateur, le heredoc l'échappe en `\${IMAGE_TAG}` —
oublier l'échappement est le piège n°1 de cette tâche.)

Le mécanisme complet, qui sert à la fois de déploiement et de rollback :

```
   CI (job deploy)                          Rollback
   ──────────────────                       ────────────────────────────
   cp .env .env.prev                        remettre un ancien SHA dans .env
   sed -i s/^IMAGE_TAG=.*/IMAGE_TAG=<sha>/  docker compose pull
   docker compose pull                      docker compose up -d
   docker compose up -d --remove-orphans
   attendre les healthchecks (30 × 3 s)     échec du CI ⇒ mv .env.prev .env
   curl 127.0.0.1:<port hôte><health>                  puis pull + up -d
```

Trois conséquences :

- Le rollback n'a **aucune** mécanique propre : c'est une ligne de texte à réécrire. La
  Skill `rollback-manager` générée conserve les cinq derniers tags dans
  `deploy/.image-history` (jalon 1, tâche 14).
- La documentation historique promettait un déploiement par SHA alors que les manifests
  utilisaient `:latest` — l'incohérence n°9 de la dette technique. Elle disparaît ici.
- Le health-check du CI passe par SSH, jamais par une URL publique (§5, contrainte 2).

---

## 10. Une réplique par service, et pourquoi

Compose ne répartit pas la charge entre plusieurs répliques derrière un port hôte publié :
seule la première réplique reçoit le trafic, les autres échouent à binder. Le champ
`REPLICAS_*` de l'ancienne configuration disparaît donc du modèle. `engine/tools/migrate-env.sh`
ne le supprime pas en silence : il avertit explicitement sur stderr quand il en trouve un
différent de 1.

Le scaling horizontal est **hors périmètre** de la feuille de route. La bonne réponse à
cette échelle serait Swarm ou un retour à un orchestrateur, pas un contournement.

---

## 11. Documents liés

- [`CURRENT-STATE.md`](CURRENT-STATE.md) — ce qui existe réellement aujourd'hui.
- [`CONVENTIONS.md`](CONVENTIONS.md) — comment écrire du code qui respecte ces contrats.
- [`SECURITY.md`](SECURITY.md) — le modèle de menace et les défenses en place.
- [`TEAM-SPLIT.md`](TEAM-SPLIT.md) — qui construit quoi.
- `docs/ENGINE.md` — *à venir* (jalon 1, tâche 15) : référence détaillée du contrat de
  l'engine, étape par étape.
