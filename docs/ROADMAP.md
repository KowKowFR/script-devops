# DeployMatic — feuille de route

Six jalons pour transformer `bootstrap-tp` (script bash local, K3s, mono-app) en un
panneau de déploiement conteneurisé, multi-app, intégré à BunkerWeb, avec génération
d'applications par IA.

Ce document est la **source de vérité du périmètre**. Les plans d'exécution détaillés
vivent dans `docs/superpowers/plans/`.

---

## Ce qu'on construit

Un panneau de déploiement web, lancé par `docker compose up` sur une prod perso.
On s'y connecte, on décrit une application, elle est générée, buildée, déployée sur
un hôte cible, exposée derrière BunkerWeb et scannée pour les vulnérabilités.

## Architecture cible

```
bootstrap-tp/
├── compose.yml              la stack du panneau
├── engine/                  l'existant bash, réorienté en exécuteur d'étapes
│   ├── bootstrap.sh           dispatcher : exécute UNE étape nommée
│   └── lib/                   ssh_remote, gen_*, prepare_server…
└── panel/                   le service Python
    ├── api/                   FastAPI : UI, auth, endpoints REST, SSE
    ├── worker/                RQ : exécute les runs en appelant l'engine
    ├── models.py              SQLModel
    └── spec.py                Pydantic : schéma d'application
```

Conteneurs de la stack : `panel`, `worker`, `postgres`, `redis`.

BunkerWeb n'est **pas** dans cette stack : il tourne déjà sur `10.13.3.211` (DMZ),
son API REST écoute sur le port `7070`. Trivy et Grype tournent à la demande, pas en
conteneurs permanents.

## Répartition des responsabilités

**Python orchestre, bash exécute.** Le tableau `PIPELINE` quitte `bootstrap.sh` : la
séquence d'étapes vit en base côté Python. Le bash ne sait plus faire qu'une chose,
exécuter une étape qu'on lui nomme.

## Contrat engine (invariant, ne jamais le casser)

```
engine/bootstrap.sh --workspace <ws> --step <nom_etape>
```

- **Entrées** : `runs/<ws>/spec.json` (description de l'app) et `runs/<ws>/env.json`
  (paramètres et secrets), écrits par le worker, lus avec `jq`.
- **Logs** : sur **stderr**, en clair, ligne par ligne.
- **Résultat** : **une seule** ligne JSON sur **stdout**, en fin d'exécution :
  `{"ok": true, "data": {...}}` ou `{"ok": false, "error": "message"}`.
- **Codes de sortie** : `0` succès, `1` échec réessayable, `2` échec fatal.
- Aucune étape n'écrit dans une base ni ne connaît l'existence du panel.

**Règle absolue : plus jamais de `source` sur un fichier de configuration.** Les
paramètres arrivent en JSON et se lisent avec `jq`. C'est ce qui supprime la classe
d'injection qui existait dans l'ancien `.bootstrap-env`.

## Topologie réseau

```
Internet ─▶ BunkerWeb 10.13.3.211 (DMZ, :80/:443)
                │  /api/  ─▶ http://<hôte cible>:<port alloué>/
                │  /      ─▶ http://<hôte cible>:<port alloué>
                ▼
        Hôte(s) cible(s), joints en SSH depuis le worker
```

Contraintes qui en découlent :

- Aucun réseau Docker partagé entre BunkerWeb et les applications : les conteneurs
  applicatifs publient des ports sur une interface joignable depuis `10.13.3.211`.
- Distinguer strictement port **CONTENEUR** (interne, libre) et port **HÔTE**
  (publié, alloué dynamiquement, toujours ≥ 1024).
- Le panneau parle à l'API BunkerWeb (`10.13.3.211:7070`) depuis le worker. Un runner
  GitHub Actions hébergé ne peut **pas** joindre cette adresse RFC1918 : tout
  health-check en CI passe par SSH sur l'hôte cible, jamais par une URL publique.
- Le worker ne monte **jamais** `/var/run/docker.sock`. Il pilote Docker via
  `DOCKER_HOST=ssh://user@hôte`, y compris pour l'hôte local, qui est une cible
  comme une autre. Un seul chemin de code, aucune exception.

## Conventions

- Réutiliser les helpers bash existants (`ui_step`, `ui_ok`, `ui_warn`, `die`,
  `ssh_remote`, `scp_remote`) plutôt que d'en créer.
- Les images applicatives vont sur Docker Hub (`DOCKERHUB_USER` / `DOCKERHUB_TOKEN`).
- Commits conventionnels, atomiques par fichier.
- Montrer un plan avant de coder. En cas d'ambiguïté dans l'existant, demander
  plutôt que supposer.

---

# Jalon 1 — Engine : K3s → Docker

**Objectif** : la cible de déploiement devient Docker Compose, et `bootstrap.sh`
devient un dispatcher d'étapes piloté par JSON. À la fin, l'engine se pilote en
ligne de commande, étape par étape, sans panel.

**Prérequis** : aucun. C'est le point de départ.

**Plan d'exécution détaillé** : `docs/superpowers/plans/2026-09-08-jalon-1-engine-docker.md`

## Travail

**A. Réorganisation.** `bootstrap.sh` et `lib/` passent sous `engine/`. `web/` reste
en place et cesse de fonctionner pendant ce jalon — attendu et accepté, il est
remplacé au jalon 2.

**B. Dispatcher.** `engine/bootstrap.sh --workspace <ws> --step <nom>` n'exécute que
cette étape. Suppression de `run_pipeline`, du tableau `PIPELINE` et de
`lib/state.sh`. Un mode `--all` subsiste pour tester l'engine seul. Helper
`emit_result()` dans `lib/runtime.sh`.

**C. Configuration en JSON.** Suppression de `.bootstrap-env` et de tout `source` de
configuration. Helper `cfg <clé>` lisant `runs/<ws>/env.json` avec `jq`. Script de
migration `engine/tools/migrate-env.sh`. Fichiers en 600, `runs/` en 700.

**D. Fichier de spécification d'application.** `runs/<ws>/spec.json` décrit les
services. Le générateur de compose le lit au lieu d'avoir « api + web » codés en dur.

```json
{
  "name": "mon-app",
  "services": [
    { "id": "api", "build": "./services/api", "port": 3000,
      "health": "/api/health", "expose": "/api/",
      "env": { "NODE_ENV": "production" } },
    { "id": "web", "build": "./services/web", "port": 8080,
      "health": "/", "expose": "/" },
    { "id": "db", "image": "postgres:16-alpine", "internal": true,
      "volumes": ["pgdata:/var/lib/postgresql/data"] }
  ]
}
```

Sémantique : `expose` = chemin public (un port hôte est alloué et publié),
`internal: true` = aucun port publié, joignable seulement par les autres services.
`engine/templates/spec.demo.json` correspond à l'app de démo (Express + nginx).

**E. Migration K3s → Docker.** Suppression de `lib/gen_manifests.sh`. Nouveau
`lib/gen_compose.sh` produisant `deploy/compose.yml`, `deploy/.env`
(`IMAGE_TAG=latest`) et `deploy/.env.example`. Durcissement par service :
`user: "1000:1000"`, `read_only`, `tmpfs`, `cap_drop: [ALL]`,
`no-new-privileges`, healthcheck, limites de ressources, logging borné.
`IMAGE_TAG` est interpolé par Compose depuis `deploy/.env`, pas par bash — c'est le
CI qui réécrit cette ligne avec le SHA du commit, et c'est le mécanisme de rollback.
Chaque application obtient son propre réseau Docker. `network_mode: host` interdit.

**F. Trois pièges de conversion.**
1. **Unités.** `200m` de CPU et `128Mi` de mémoire sont des unités Kubernetes ;
   Compose veut `cpus: "0.2"` et `memory: 128m`. Nouveau `lib/units.sh`.
2. **nginx non-root.** Le front tournait en nginx sur le port 80 avec
   `runAsUser: 1000` — impossible de binder un port privilégié. Bascule sur
   `nginxinc/nginx-unprivileged` (écoute 8080).
3. **Répliques.** Compose ne load-balance pas plusieurs répliques derrière un port
   hôte publié. Une réplique par service ; le scaling n'est pas dans le périmètre.

**G. Étapes réécrites.** `install_k3s` → `install_docker`, `generate_manifests` →
`generate_compose`, `apply_initial_manifests` → `deploy_stack`, `fetch_kubeconfig`
supprimée, `validate_deployment` réécrite (`docker compose ps` puis curl sur
`127.0.0.1:<port hôte>` depuis l'hôte cible, plus aucun curl sur une IP publique).
Correction de `check_prereqs` et `collect_credentials` qui violaient la convention
« step pure ».

**H. Provisioning serveur.** Retrait de k3s, kubectl, helm, cert-manager. Ajout de
docker-ce + docker-compose-plugin. `apt-get update` garanti avant fail2ban.
ufw : retrait de 6443, 80 et 443 ; seul 22 reste. `docker login` par
`--password-stdin`, jamais en argument de ligne de commande.

**I. Workflow GitHub Actions.** Le job `deploy` réécrit `IMAGE_TAG` avec le SHA,
fait `docker compose pull && up -d`, attend les healthchecks, teste la santé depuis
l'hôte cible, et restaure le tag précédent en cas d'échec. `paths-filter`,
`gitleaks` et `trivy` restent en l'état — le jalon 6 s'en occupe.

**J. Diagnostic.** `cmd_doctor` sur `docker compose ps`/`config`, `cmd_logs` sur
`docker compose logs -f`, `cmd_cluster_info` → `cmd_stack_info` avec alias déprécié.

**K. Skills Claude Code générées.** `k8s-deploy` → `docker-deploy` ;
`health-monitor` passe de `kubectl rollout status` à une boucle sur
`docker compose ps` ; `rollback-manager` remet un ancien SHA dans `deploy/.env`
et conserve les 5 derniers dans `deploy/.image-history`. Correction du décompte
« 4 Skills » alors qu'il y en a 5.

**L. Documentation.** Mise à jour du README et du guide de déploiement.

## Ne pas faire dans ce jalon

BunkerWeb (jalon 4), scanners (jalon 6), IA (jalon 5), code Python (jalon 2),
allocation de ports (jalon 3 — les ports hôtes sont lus depuis `env.json`).

## Critères d'acceptation

1. `bash -n` passe sur tous les `.sh` modifiés.
2. `shellcheck` ne remonte aucune erreur de niveau `error`.
3. Plus aucune mention involontaire de k3s / kubectl / kubeconfig / ingress /
   cert-manager / ClusterIssuer sous `engine/`.
4. Plus aucun `source` de fichier de configuration.
5. Chaque `--step` renvoie exactement une ligne JSON valide sur stdout.
6. `--all` avec `spec.demo.json` déploie l'app de démo de bout en bout sur une
   cible SSH de test.
7. Le compose généré passe `docker compose config --quiet`.

---

# Jalon 2 — Panel minimal

**Objectif** : `docker compose up` donne une URL fonctionnelle. Auth, une app, logs
en direct. C'est le jalon qui rend le produit réel.

**Prérequis** : jalon 1.

## Suppression

`web/` disparaît entièrement — Flask, templates, JS, `start.sh`. Ce qui était utile
(le formulaire, la vue de progression, le SSE) est réimplémenté avec un modèle de
données derrière.

## Modèle de données (`panel/models.py`, SQLModel)

```
User      id, username, password_hash (argon2), created_at, last_login
Target    id, name, host, ssh_user, auth_method, ssh_key_path|password_ref,
          bind_addr, is_local, created_at
App       id, name, slug, target_id, spec (JSON), env (JSON), status,
          created_at, updated_at
Run       id, app_id, trigger (manual|ci|api), status, started_at,
          finished_at, error
Step      id, run_id, name, ordinal, status (pending|running|ok|failed|skipped),
          started_at, finished_at, exit_code, log_path
```

La séquence d'étapes est une constante Python (`panel/pipeline.py`), pas une table :
elle est versionnée avec le code. `Step` enregistre les instances d'exécution.

`state_has`/`state_mark` sur fichier disparaissent. **L'idempotence, c'est la table
`Step`** : au lancement d'un run, les étapes déjà `ok` pour cette app sont `skipped`,
sauf celles marquées « toujours rejouées » (les générateurs).

## Secrets

Pas de tokens ni de mots de passe en clair dans Postgres. Chiffrement symétrique
(Fernet) avec une clé lue depuis `PANEL_SECRET_KEY`, fournie par un secret Docker ou
une variable d'environnement, jamais committée. Les secrets ne sortent qu'au moment
d'écrire `runs/<ws>/env.json` pour le worker.

## Authentification

Le panneau est un exécuteur de code à distance. L'auth n'est pas du confort.

- Mot de passe unique, haché en argon2, défini au premier démarrage via
  `PANEL_ADMIN_PASSWORD` ou un assistant d'initialisation.
- Session par cookie signé, `HttpOnly`, `SameSite=Strict`, `Secure`.
- Token CSRF sur toutes les mutations. Une auth d'edge ne protège pas du CSRF.
- Vérification de l'en-tête `Origin` sur les POST/PATCH/DELETE.
- Rate limiting sur `/login` (5 tentatives / 5 min / IP).
- Le modèle `User` prépare le multi-utilisateur, mais un seul compte suffit.

Documenter que la mise derrière BunkerWeb avec `auth_basic` et une allowlist IP est
recommandée **en plus**, pas à la place.

## API (`panel/api/`)

```
POST   /login, /logout
GET    /targets                 liste
POST   /targets                 créer + tester la connexion SSH
DELETE /targets/{id}
GET    /apps
POST   /apps                    créer depuis un spec
GET    /apps/{id}
POST   /apps/{id}/deploy        met un run en file, renvoie run_id
GET    /runs/{id}
GET    /runs/{id}/events        SSE : étapes + logs en direct
GET    /healthz, /readyz
```

Entrées validées par Pydantic. Le nom d'app est contraint par une regex stricte
(`^[a-z][a-z0-9-]{1,30}$`) — c'est ce qui devient un nom de workspace, de répertoire
et de réseau Docker. C'est le correctif définitif de la traversée de chemin
`--workspace ../../foo`.

## Worker (`panel/worker/`)

RQ sur Redis. Un job = un run. Pour chaque étape :

1. écrire `runs/<slug>/spec.json` et `env.json` (600)
2. `subprocess.run(["engine/bootstrap.sh", "--workspace", slug, "--step", name])`
3. streamer stderr ligne par ligne vers un fichier de log ET vers Redis pub/sub
   (c'est ce que le SSE consomme)
4. parser la ligne JSON de stdout, écrire le résultat dans `Step`
5. code 1 → un retry avec backoff ; code 2 → arrêt du run

**Réconciliation au démarrage** : tout `Run` en statut `running` dont le job RQ
n'existe plus est marqué `failed` avec un message explicite. Sans ça, un redémarrage
du conteneur laisse des runs bloqués pour toujours — c'est le défaut du modèle
`Popen` détaché + fichier PID qu'on remplace.

Timeout global par run (30 min) et par étape (10 min).

## Frontend

HTML rendu côté serveur (Jinja2) + JS vanilla. Pas de framework. Trois écrans :
cibles, applications, run en direct (étapes à gauche, logs SSE à droite, auto-scroll,
codes ANSI nettoyés).

## Stack Docker

`compose.yml` à la racine : `panel` (gunicorn + workers uvicorn, port interne 8000),
`worker` (même image, commande `rq worker`), `postgres` 16-alpine, `redis` 8-alpine.

- Gunicorn avec des workers threads, pas gevent : le worker lance des subprocess.
- Volume partagé `runs/` entre `panel` et `worker`.
- Aucun montage de `/var/run/docker.sock`, nulle part.
- `panel` et `worker` en UID non-root, `no-new-privileges`.
- La clé SSH du worker arrive par un secret Docker monté en lecture seule.
- Healthchecks sur les quatre services, `depends_on` avec `condition: service_healthy`.
- Port du panel publié sur `127.0.0.1` uniquement : BunkerWeb le reverse-proxifie.

## Critères d'acceptation

1. `docker compose up -d` puis une URL qui répond, sur une machine vierge.
2. Login obligatoire, une requête non authentifiée renvoie 401.
3. Un POST sans token CSRF est rejeté.
4. Un nom d'app invalide (`../foo`, `A_b`, 40 caractères) est rejeté par l'API.
5. Un déploiement complet de l'app de démo passe, logs visibles en direct.
6. `docker compose restart worker` pendant un run : le run est marqué `failed`
   proprement, pas bloqué en `running`.
7. Aucun secret en clair dans une requête `SELECT * FROM app`.
8. `pytest` : au moins les tests d'auth, de validation de nom, et de réconciliation.

---

# Jalon 3 — Multi-app

**Objectif** : plusieurs applications, sur plusieurs cibles, sans collision, avec un
cycle de vie complet incluant la destruction.

**Prérequis** : jalon 2.

## Allocateur de ports

Avec N apps sur un même hôte, les ports hôtes ne peuvent plus venir de la config.

Nouvelle table : `PortAllocation (id, target_id, app_id, service_id, port, allocated_at)`

- Plage configurable par cible, défaut 10000-19999.
- Allocation atomique : transaction avec `SELECT … FOR UPDATE` sur la cible, ou
  contrainte d'unicité `(target_id, port)` et retry sur conflit.
- Vérification que le port est réellement libre sur l'hôte avant de le confirmer
  (`ss -ltn` via SSH) : la base peut diverger de la réalité.
- Libération à la destruction de l'app.
- Une commande de réconciliation qui compare la base à l'état réel de l'hôte.

Les ports alloués sont injectés dans `env.json` avant l'appel à l'engine.
**L'engine ne décide jamais d'un port, il les reçoit.**

## Ouverture ufw dynamique

Nouvelle étape `open_firewall_ports` : pour chaque port alloué,
`ufw allow from <IP BunkerWeb> to any port <port> proto tcp`, avec un commentaire
`deploymatic:<app-slug>` pour pouvoir nettoyer. Étape symétrique
`close_firewall_ports` à la destruction, qui supprime les règles par commentaire.

Attention : vérifier que l'IP source vue par l'hôte cible est bien celle de
BunkerWeb. Si BunkerWeb sort derrière un NAT ou un bridge Docker, la règle ne
matchera pas. Documenter comment le vérifier — c'est le genre de détail qui coûte
une heure de débogage.

## Cibles multiples

- L'hôte local est une cible comme les autres, avec `is_local: true` et un
  `DOCKER_HOST=ssh://user@172.17.0.1`. Même chemin de code, aucune exception.
- Test de connexion à la création d'une cible : SSH, `docker version`, version de
  Compose, espace disque.
- Une étape de provisioning **par cible**, pas par app : `prepare_server.sh` ne
  tourne qu'une fois, marqué au niveau de `Target`.

## Destruction d'application

C'est ce qui manque le plus : le pipeline sait créer, pas détruire. Sans ça, on
accumule des stacks orphelines, des ports fantômes et des règles ufw mortes.

Séquence `destroy`, avec confirmation explicite dans l'UI (retaper le nom de l'app) :

1. `docker compose down --volumes --remove-orphans` sur la cible
2. suppression des images de l'app
3. suppression du réseau Docker
4. fermeture des règles ufw
5. libération des ports en base
6. suppression du répertoire `runs/<slug>/`
7. suppression du service BunkerWeb (jalon 4, prévoir le point d'extension)
8. le dépôt GitHub n'est **pas** supprimé — proposer un lien, laisser l'humain décider

Chaque étape doit être tolérante à l'absence : détruire une app à moitié créée doit
fonctionner.

## Concurrence

- Un seul run actif par app (verrou en base, pas de fichier lock).
- Plusieurs apps peuvent se déployer en parallèle sur la même cible.
- Sérialiser les opérations qui touchent un état global de la cible (ufw,
  provisioning) avec un verrou par cible.

## Critères d'acceptation

1. Trois apps déployées simultanément sur la même cible, sans collision de port.
2. Deux cibles, dont l'hôte local, avec une app sur chacune.
3. Destruction complète d'une app : plus de conteneur, plus de règle ufw, port
   réutilisable immédiatement.
4. Destruction d'une app dont le déploiement avait échoué à mi-parcours.
5. Deux déploiements concurrents sur la même cible n'entrelacent pas leurs
   modifications ufw.

---

# Jalon 4 — BunkerWeb

**Objectif** : chaque application est exposée automatiquement derrière BunkerWeb,
avec TLS, et son service est supprimé avec elle.

**Prérequis** : jalon 3.

**Cible** : BunkerWeb 1.6.x, service `bw-api` actif, sur `10.13.3.211:7070`,
multisite activé.

## Ce que dit la documentation officielle (vérifié)

Authentification :
- `POST /auth` avec Basic auth renvoie un token Biscuit ; le réutiliser en
  `Authorization: Bearer <token>`.
- Un utilisateur admin peut aussi appeler directement en Basic.
- `API_TOKEN` sert de Bearer d'override admin (bris-de-glace uniquement).
- TTL du Biscuit : `API_BISCUIT_TTL_SECONDS`, 3600 par défaut.

Endpoints utiles : `GET /ping`, `GET /health`, `GET /services`,
`GET /services/{service}`, `POST /services`, `PATCH /services/{service}`,
`DELETE /services/{service}`, `POST /instances/reload?test=yes|no`.

Deux avertissements à prendre au sérieux :
- L'API ne doit pas être exposée sur Internet ; allowlist IP par défaut sur les
  plages RFC1918 (`API_WHITELIST_IPS`).
- Les permissions `service_create`, `service_update`, `config_create`,
  `config_update`, `plugin_create` et `global_settings_update` sont
  **admin-équivalentes** : leur contenu est rendu verbatim en configuration
  NGINX/OpenResty Lua, donc un token qui les porte peut exécuter du code sur les
  workers BunkerWeb. Le compte utilisé par le panneau est un compte admin de fait :
  le traiter comme tel, le chiffrer en base comme les autres secrets, le documenter.

## Client (`panel/bunkerweb.py`)

- Authentification avec cache du token et renouvellement avant expiration.
- Timeouts, retry avec backoff sur 5xx, pas de retry sur 4xx.
- Toutes les erreurs remontées avec le message de l'API.
- Un mode `dry_run` qui journalise les appels sans les émettre.

## Mapping spec → service BunkerWeb

Chaque service du spec ayant un `expose` devient un reverse proxy numéroté :

```
SERVER_NAME          = <hostname public de l'app>
USE_REVERSE_PROXY    = yes
REVERSE_PROXY_URL_1  = /api/
REVERSE_PROXY_HOST_1 = http://<hôte cible>:<port api>/
REVERSE_PROXY_URL_2  = /
REVERSE_PROXY_HOST_2 = http://<hôte cible>:<port web>
AUTO_LETS_ENCRYPT    = yes        (si TLS demandé)
```

Deux points à vérifier sur une app de test avant de généraliser :
- Le `/` final sur `REVERSE_PROXY_HOST_1` est ce qui retire le préfixe `/api`, comme
  un `proxy_pass` NGINX classique. C'est le remplaçant du middleware `stripPrefix`
  de Traefik. **Confirmer le comportement réel plutôt que de le supposer.**
- L'ordre des reverse proxies numérotés et la précédence des chemins : le plus
  spécifique doit gagner. Ordonner par longueur de chemin décroissante à la
  génération, pour ne pas dépendre de l'ordre de déclaration.

## Étapes ajoutées

- `register_bunkerweb` : idempotente. `GET /services/{slug}` → `POST` si absent,
  `PATCH` si présent. Puis `POST /instances/reload`.
- `unregister_bunkerweb` : `DELETE /services/{slug}`, branchée dans `destroy`.
- `validate_public` : `curl` sur l'URL publique, avec fallback en
  `curl -H "Host: <server_name>" http://<ip bunkerweb>/` si le DNS ne résout pas
  encore. C'est le correctif du bug historique où la validation par IP prenait un
  404 dès qu'un hostname était configuré.

## Configuration du panneau

`BW_API_URL` (défaut `http://10.13.3.211:7070`), `BW_API_USERNAME`,
`BW_API_PASSWORD`, `BW_DEFAULT_DOMAIN`, `BW_AUTO_TLS`. Un bouton « tester la
connexion BunkerWeb » dans l'UI (`GET /ping` puis `POST /auth`).

## Critères d'acceptation

1. Déploiement d'une app → service créé dans BunkerWeb, app joignable en HTTPS.
2. Redéploiement → `PATCH`, pas de doublon, pas d'erreur.
3. Changement de port hôte → le service BunkerWeb suit.
4. Destruction → service supprimé, plus de vhost.
5. `/api/health` répond via l'URL publique, préfixe correctement retiré.
6. API BunkerWeb injoignable → message d'erreur clair, pas de trace Python brute,
   et l'app reste déployée (l'exposition est une étape, pas le déploiement).

---

# Jalon 5 — Génération par IA

**Objectif** : décrire une application en langage naturel et obtenir un spec validé,
du code, et un déploiement — avec une approbation humaine avant le build.

**Prérequis** : jalon 4.

## Ce qu'on construit, dit franchement

Un formulaire web qui produit du code exécuté sur une prod. Chaque maillon est voulu ;
l'ensemble est exactement ce qu'un attaquant chercherait à obtenir. Les garde-fous de
ce jalon ne sont pas de la décoration, ils sont la raison pour laquelle la chose est
déployable.

Quatre invariants :

1. **Jamais de build sur l'hôte du panneau.** Le build va sur la cible via
   `DOCKER_HOST=ssh://`. Le panneau orchestre, il ne compile pas.
2. **Approbation humaine obligatoire avant build.** Le run s'arrête après génération,
   affiche le spec et le diff des fichiers, attend une approbation explicite. Sans
   cette étape, un prompt suffit à exécuter du code arbitraire.
3. **Validation programmatique de la sortie**, jamais la confiance dans le prompt.
4. **Réseau par app, pas d'egress libre** pour les conteneurs générés.

## Contrat d'application

Ce que toute app générée doit respecter, à la fois dans le prompt système **et** dans
un validateur qui vérifie après coup :

- Port lu depuis la variable d'environnement `PORT`, jamais codé en dur
- Un endpoint de santé qui répond 200 sans dépendance externe
- Dockerfile multi-stage, `USER 1000` en dernière instruction
- Image de base dans une allowlist (`node:*-alpine`, `python:*-slim`,
  `nginxinc/nginx-unprivileged`, `golang:*-alpine`, `postgres:*-alpine`…)
- Aucun `privileged`, `network_mode: host`, montage de socket Docker, ou bind mount
  d'un chemin hôte
- Aucun secret en dur dans le code ou le Dockerfile
- Pas de `curl | sh` dans le Dockerfile

## Validateur (`panel/validator.py`)

Trois niveaux, tous bloquants :

1. **Schéma** : la sortie du LLM est parsée en `AppSpec` Pydantic. Un JSON invalide
   ou hors schéma est rejeté sans discussion.
2. **Statique** : parcours des Dockerfiles et des fichiers générés pour les motifs
   interdits. Regex plus, si possible, un parseur de Dockerfile.
3. **Cohérence** : chaque service référencé dans `expose` existe, les ports sont
   distincts, les dépendances déclarées existent, aucun cycle.

En cas d'échec : régénération avec le rapport d'erreur en feedback, **deux tentatives
maximum**, puis échec explicite. Jamais de déploiement d'un spec non validé, jamais de
contournement manuel.

## Intégration LLM (`panel/generator.py`)

- Appel à l'API Anthropic, modèle et clé configurables, clé chiffrée en base.
- Sortie structurée : JSON strict, sans préambule ni balises Markdown, nettoyé
  défensivement avant parsing.
- **Deux appels séparés** plutôt qu'un monolithique : d'abord le spec (petit,
  structuré, validable), puis le code de chaque service (guidé par le spec déjà
  validé). Plus fiable et plus facile à déboguer.
- Journaliser prompt et réponse dans `Run` pour l'audit.
- Timeout, gestion du rate limit, coût estimé affiché.

## Nouvelles étapes

```
ai_generate_spec       → spec.json validé
ai_generate_code       → arborescence de services
validate_generated     → les trois niveaux
await_approval         → pause, attend l'humain
(puis la séquence de déploiement existante)
```

`await_approval` met le run en statut `pending_approval` avec une expiration (24h).
L'UI affiche le spec rendu lisiblement, l'arborescence, le contenu des Dockerfiles,
et deux boutons.

## Critères d'acceptation

1. Prompt « une API REST de gestion de tâches avec Postgres » → spec à trois services
   valide, code cohérent, déploiement complet après approbation.
2. Un spec forgé demandant un montage de `/var/run/docker.sock` est rejeté.
3. Un Dockerfile finissant par `USER root` est rejeté.
4. Un run laissé sans approbation expire proprement au bout de 24h.
5. Aucun appel de build n'est émis avant l'approbation — vérifié par un test.
6. La clé API n'apparaît ni dans les logs, ni dans les réponses HTTP, ni en clair
   en base.

---

# Jalon 6 — Scanners

**Objectif** : Trivy conservé, Grype ajouté, scan bloquant avant le premier
déploiement et pas seulement en CI.

**Prérequis** : jalon 5.

## Pourquoi deux scanners

Trivy est conservé. Grype est ajouté à côté, avec Syft qui produit le SBOM. Le gain
n'est pas la redondance mais le **recoupement** : bases de vulnérabilités différentes,
donc couvertures différentes. Syft produit en plus un SBOM (CycloneDX) qui devient un
artefact conservé, utile bien après le déploiement.

Docker Scout est écarté : il exige un compte Docker Hub. Trivy et Grype tournent hors
ligne une fois leur base à jour.

## Où ça tourne

Sur l'**hôte cible**, en conteneurs éphémères (`aquasec/trivy`, `anchore/grype`,
`anchore/syft`), après le build et **avant** le premier `compose up`. Pas sur l'hôte
du panneau. Le cache de base de vulnérabilités est monté sur un volume nommé par
cible, sinon chaque scan retélécharge des centaines de mégaoctets.

## Étapes ajoutées

```
scan_images       trivy + grype sur chaque image construite
generate_sbom     syft, CycloneDX, un fichier par image
scan_dockerfiles  hadolint sur les Dockerfiles
scan_compose      trivy config sur compose.yml
```

Toutes placées après `build_images` et avant `deploy_stack`.

## Politique

Configurable par app, avec un défaut sensé :

```
fail_on: HIGH,CRITICAL
ignore_unfixed: true
grace_period_days: 0
```

Un échec de scan bloque le déploiement. Prévoir une **dérogation explicite,
horodatée, avec justification obligatoire**, enregistrée dans `Run` — parce que sans
soupape documentée les gens désactivent le scan entièrement.

Nouvelle table `ScanResult` : run_id, image, scanner, severity, count, findings
(JSON), sbom_path.

## Workflow CI généré

Aligner `gen_workflow.sh` sur la même politique : gitleaks, puis build, puis trivy et
grype en parallèle, puis deploy. Une variable `SCANNERS="trivy grype"` pilote une
matrice, pour qu'ajouter un scanner reste une seule ligne à changer. Uploader les
SBOM en artefacts du run GitHub.

## UI

Un onglet Sécurité par app : dernier scan, comparaison des deux scanners, tendance
sur les derniers runs, lien de téléchargement du SBOM. Afficher clairement ce que
l'un trouve et pas l'autre — c'est tout l'intérêt d'en avoir deux.

## Critères d'acceptation

1. Une image volontairement vulnérable bloque le déploiement.
2. Les deux scanners tournent et leurs résultats sont comparables dans l'UI.
3. Le SBOM est généré, stocké, téléchargeable.
4. Une dérogation permet de déployer et laisse une trace exploitable.
5. Le deuxième scan sur la même cible est nettement plus rapide (cache effectif).
6. Le workflow CI généré applique la même politique que le panneau.

---

# Dette technique traitée en chemin

Points relevés à la lecture initiale du dépôt, et le jalon qui les règle :

| # | Problème | Réglé au |
|---|---|---|
| 1 | `INGRESS_HOST` casse la validation finale | 4 (`validate_public` avec en-tête Host) |
| 2 | `API_PORT` < 1024 + `runAsUser: 1000` | 1 (port conteneur ≠ port hôte, nginx unprivileged) |
| 3 | Fuite de thread SSE | 2 (réécriture complète du SSE) |
| 4 | `--workspace` non validé | 2 (regex stricte côté API) |
| 5 | Injection via `.bootstrap-env` | 1 (JSON + `jq`, plus aucun `source`) |
| 6 | Pas de CSRF sur la web UI | 2 (token CSRF + Origin + auth) |
| 7 | Security context sur un seul service | 1 (appliqué uniformément) |
| 8 | « 4 Skills » alors qu'il y en a 5 | 1 |
| 9 | Doc SHA vs manifest `:latest` | 1 (`deploy/.env` + `IMAGE_TAG`) |
| 10 | `run_step()` documentée mais inexistante | 1 (disparaît avec `run_pipeline`) |
| 11 | Étapes violant la convention « step pure » | 1 |
| 12 | Triple duplication du nombre d'étapes et des variables | 2 (modèle unique en base) |
| 13 | `PROJECT_NAME` figé | 2 (slug de l'app) |
| 14 | Banner ASCII dupliqué | 1 |
| 15 | Deux sections « 9 », fail2ban sans `apt-get update` | 1 |
| 16 | Zéro test, zéro shellcheck, aucune CI | 1 et 2 (critères d'acceptation) |
| 17 | `--reset` incomplet | 3 (séquence `destroy`) |

# Hors périmètre

Décidé volontairement, à rouvrir seulement si le besoin devient réel :

- **Scaling horizontal des applications** (plusieurs répliques derrière un port hôte).
  La bonne réponse à cette échelle serait Swarm ou un retour à un orchestrateur.
- **Multi-utilisateur avec rôles.** Le modèle `User` le permettra, rien de plus.
- **Sauvegarde et restauration des volumes applicatifs.**
- **Métriques et alerting** (Prometheus). Les healthchecks Docker suffisent d'abord.
- **Déploiement de dépôts Git existants**, en complément de la génération par IA.
