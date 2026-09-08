# Répartition du travail entre trois personnes

Ce document découpe [la feuille de route](ROADMAP.md) — les six jalons — entre trois
rôles techniques. Il dit qui fait quoi, ce qui bloque quoi, ce qui peut avancer en
parallèle, et par quoi commencer.

L'état réel du projet au moment de la rédaction est dans
[`CURRENT-STATE.md`](CURRENT-STATE.md) : le jalon 1 en est à 7 tâches sur 15.

---

## 1. Les trois rôles

Le découpage est **par domaine technique durable**, pas par lots numérotés. Chacun garde
le même périmètre du jalon 1 au jalon 6. La raison est pratique : deux personnes qui
éditent `engine/lib/steps.sh` la même semaine passent leur temps à résoudre des conflits,
alors que deux personnes qui éditent l'une `engine/`, l'autre `panel/`, ne se croisent que
sur des contrats — et un contrat, ça se négocie une fois puis ça tient.

| Rôle | Périmètre | Fichiers qu'il « possède » | Compétences |
|---|---|---|---|
| **Engine / Bash** | l'exécuteur d'étapes | `engine/**` : `bootstrap.sh`, `lib/*.sh`, `templates/`, `tests/`, `tools/` — y compris le provisioning serveur, les Skills générées et le workflow CI **généré** | bash 3.2, `jq`, SSH, Docker CLI et Compose, `shellcheck` |
| **Panel / Python** | le panneau web | `panel/**` : FastAPI, worker RQ, SQLModel, Jinja2 + JS vanilla, auth, génération par IA | Python 3.11+, FastAPI, Pydantic, SQLModel, RQ/Redis, SSE, `pytest` |
| **Infra & Sécurité** | tout ce qui entoure | `compose.yml` racine, `Dockerfile`, secrets Docker, BunkerWeb, allocation et ouverture de ports, ufw, scanners, SBOM, durcissement, **la CI du dépôt lui-même** | Docker, Compose, réseau, ufw/iptables, BunkerWeb, Trivy/Grype/Syft, GitHub Actions |

### Deux exceptions assumées à la règle « Python = Panel »

1. **`panel/bunkerweb.py` (jalon 4) revient à Infra & Sécurité.** C'est du Python, mais la
   difficulté n'est pas FastAPI : c'est la sémantique de BunkerWeb (tokens Biscuit,
   `REVERSE_PROXY_*` numérotés, précédence des chemins, rechargement des instances). Le
   module est une feuille — rien d'autre dans `panel/` ne l'importe hormis le câblage des
   étapes — donc le risque de collision est faible. À la charge d'Infra de livrer une
   interface Python propre et testée avec un `dry_run`.
2. **Le workflow CI généré (`engine/lib/gen_workflow.sh`) reste à Engine**, alors que la
   CI du dépôt lui-même est à Infra. Ce sont deux choses différentes : l'une est un
   générateur de texte piloté par `spec.json`, l'autre est la qualité de ce dépôt-ci. Les
   deux doivent appliquer la même politique de scan au jalon 6 — c'est un point de
   synchronisation, pas un transfert de propriété.

---

## 2. Synthèse par jalon

Les pourcentages sont une **estimation de charge relative à l'intérieur d'un jalon**, pas
des jours-hommes. Ils servent à repérer les déséquilibres, pas à facturer.

| Jalon | Engine / Bash | Panel / Python | Infra & Sécurité | Déséquilibre |
|---|---|---|---|---|
| **1 — Engine : K3s → Docker** (reste : tâches 8→15) | **70 %** — tâches 8, 9, 11, 12, 13, 14, 15 | 10 % — sous-chargé | 20 % — tâche 10 (provisioning) | fortement Engine |
| **2 — Panel minimal** | 10 % — sous-chargé | **65 %** — tout le panneau | 25 % — la stack Docker | **massivement Python** |
| **3 — Multi-app** | 30 % — étapes ufw + destroy | **45 %** — allocateur, verrous, cycle de vie | 25 % — politique ufw, plages, réconciliation terrain | équilibré |
| **4 — BunkerWeb** | 15 % — sous-chargé | 30 % — UI, câblage, config | **55 %** — client, mapping, TLS, vérifications | **massivement Infra** |
| **5 — Génération par IA** | 15 % — sous-chargé | **65 %** — LLM, validateur, approbation | 20 % — réseau par app, allowlist, secret de clé | massivement Python |
| **6 — Scanners** | 25 % — étapes de scan + workflow généré | 35 % — modèle, UI, dérogations | **40 %** — scanners, cache, SBOM, politique | équilibré |

Deux jalons sont franchement déséquilibrés (2 et 4) et deux le sont un peu (1 et 5). Le
§9 propose comment les lisser, jalon par jalon, plutôt que de laisser quelqu'un attendre.

---

## 3. Les interfaces de contact

Ce sont les endroits où deux rôles touchent le **même contrat**. La règle : on se met
d'accord **avant** d'écrire, on écrit le contrat quelque part de lisible, et celui qui
veut le changer prévient l'autre.

| # | Contrat | Qui | Où il vit | À figer avant |
|---|---|---|---|---|
| **C1** | **Contrat de l'engine** — invocation, stdout = 1 ligne JSON, stderr = logs, codes 0/1/2 | Engine ↔ Panel | `engine/lib/runtime.sh`, `docs/ENGINE.md` (à venir) | le worker du jalon 2 |
| **C2** | **Noms et ordre des étapes** — `STEPS` dans `engine/bootstrap.sh` ↔ `panel/pipeline.py` | Engine ↔ Panel | les deux fichiers, dupliqués **à dessein** | le worker du jalon 2 ; à revalider à chaque ajout d'étape (jalons 3, 4, 5, 6) |
| **C3** | **Schéma `spec.json`** — champs `id`, `build`/`image`, `port`, `health`, `expose`, `internal`, `env`, `volumes` | Engine (lecteur) ↔ Panel (producteur, `AppSpec` Pydantic) | `engine/templates/spec.demo.json`, `panel/spec.py` | l'API `POST /apps` du jalon 2, et le validateur du jalon 5 |
| **C4** | **Format `env.json`** — `app`, `target`, `registry`, `github`, `ports`, `limits`, `options` | Panel (écrivain) ↔ Engine (lecteur) ↔ Infra (`target.bind_addr`, `registry`) | `engine/lib/config.sh`, le worker | le worker du jalon 2 |
| **C5** | **Table `PortAllocation` → `env.json .ports`** | Panel (alloue) ↔ Engine (consomme) ↔ Infra (ouvre ufw) | `panel/models.py`, `cfg_port` | le jalon 3 |
| **C6** | **`deploy/.env` et `IMAGE_TAG`** — mécanisme de déploiement **et** de rollback | Engine (générateur) ↔ Infra (CI) | `engine/lib/gen_compose.sh`, `gen_workflow.sh` | la tâche 8 du jalon 1 |
| **C7** | **Image et stack du panneau** — image commune `panel`/`worker`, UID non-root, volume `runs/`, secret SSH | Infra ↔ Panel | `Dockerfile`, `compose.yml` racine | le jalon 2 |
| **C8** | **Mapping `spec.json` → service BunkerWeb** — `SERVER_NAME`, `REVERSE_PROXY_URL_n`/`HOST_n`, ordre par longueur de chemin | Infra ↔ Panel | `panel/bunkerweb.py` | le jalon 4 |

**C1, C3 et C4 sont déjà écrits et implémentés** (jalon 1, tâches 3, 4, 6, 7). Ils ne sont
pas à négocier, ils sont à lire. C'est ce qui permet au Panel de démarrer sans attendre.

---

## 4. Jalon 1 — Engine : K3s → Docker (tâches 8 à 15)

**Objectif** : la cible de déploiement devient Docker Compose et `bootstrap.sh` devient un
dispatcher d'étapes piloté par JSON.

### Engine / Bash — 70 %

| Lot | Livrables concrets |
|---|---|
| **Tâche 8 — générateur Compose** | `engine/lib/gen_compose.sh` : `gen_compose()`, `_gen_compose_service()`, `_gen_compose_volumes()`. Produit `deploy/compose.yml`, `deploy/.env` (600), `deploy/.env.example`. Supprime `engine/lib/gen_manifests.sh`. Test `engine/tests/test_gen_compose.sh`, dont un `docker compose config --quiet` |
| **Tâche 9 — générateur de services** | `engine/lib/gen_microservices.sh` converti en **module sourcé** ; le chemin passe de `microservices/` à `services/` (pour coller au `build: "./services/api"` du spec) ; front sur `nginxinc/nginx-unprivileged` (port 8080) ; port de l'API pilotable. Test `test_gen_micro.sh` |
| **Tâche 11 — étapes** | Réécriture complète de `engine/lib/steps.sh` : `step_check_prereqs`, `step_validate_ssh`, `step_create_project_dir`, `step_generate_microservices`, `step_generate_compose`, `step_generate_skills`, `step_generate_workflow`, `step_enable_sudo_nopasswd`, `step_prepare_server`, `step_build_images`, `step_deploy_stack`, `step_validate_deployment`. Ajout de `docker_host_url`, `docker_remote`, `compose_remote` à `ssh_remote.sh` — **et conversion des lectures `OVH_*` vers `cfg target.*`** (voir [`CURRENT-STATE.md`](CURRENT-STATE.md) §4) |
| **Tâche 12 — GitHub optionnel** | `step_github_create_repo`, `step_github_set_secrets`, `step_git_init`, `step_git_push`, toutes court-circuitées par `emit_ok {"skipped":true}` si `github.enabled` est faux. `gen_workflow.sh` : job `deploy` réécrit (pull/up/healthchecks/rollback), secrets `OVH_*` → `TARGET_*` |
| **Tâche 13 — diagnostic** | `engine/lib/diag.sh` : `cmd_doctor`, `cmd_logs SERVICE`, `cmd_stack_info`, alias déprécié `cmd_cluster_info` |
| **Tâche 14 — Skills** | `engine/lib/gen_skills.sh` : `k8s-deploy` → `docker-deploy`, `health-monitor` sur `docker compose ps`, `rollback-manager` sur `deploy/.env` + `deploy/.image-history` (5 derniers), décompte corrigé à 5 Skills |
| **Tâche 15 — documentation** | `docs/ENGINE.md`, réécriture du `README.md` racine, `docs/JALON-1-VERIFICATION.md` déclarant le critère 6 non vérifié |

### Infra & Sécurité — 20 %

| Lot | Livrables concrets |
|---|---|
| **Tâche 10 — provisioning** | `engine/lib/prepare_server.sh` : retrait de k3s, kubectl, helm, metrics-server, cert-manager ; docker-ce + docker-compose-plugin inconditionnels ; `apt-get update` **avant** fail2ban ; ufw réduit au seul port 22 ; `docker login --password-stdin` ; MOTD nettoyé ; sections renumérotées |
| **Revue de sécurité** | relire le durcissement produit par la tâche 8 (deux squelettes, cf. [`SECURITY.md`](SECURITY.md) §3) et corriger l'écart de transmission du token de registre relevé au §5 |
| **CI du dépôt** | premier workflow GitHub Actions **de ce dépôt** : `bash -n` + `shellcheck --severity=error` + `bash engine/tests/run.sh` à chaque push. C'est le point n°16 de la dette technique et personne ne l'a encore pris |

### Panel / Python — 10 % (sous-chargé, voir §9)

Rien de bloquant à faire dans le périmètre du jalon. Le travail utile est préparatoire :
lire `engine/lib/runtime.sh` et `config.sh`, être **relecteur désigné de `docs/ENGINE.md`**
(c'est lui le consommateur du contrat), et commencer les lots non bloqués du jalon 2
(§5).

### Dépendances internes au jalon 1

```
T8 gen_compose ──▶ T9 gen_micro ──┐
T10 prepare_server ───────────────┼──▶ T11 steps ──▶ T12 github+workflow ──▶ T15 doc
                                  │                  T13 diag ─────────────▶
                                  └──────────────────T14 skills ──────────▶
```

- **T9 dépend de T8** : les tmpfs `/tmp`, `/var/run`, `/var/cache/nginx` que réclame
  nginx-unprivileged en `read_only` sont posés par le squelette de T8.
- **T11 dépend de T8, T9 et T10** : elle câble les trois.
- **T13 et T14 sont indépendantes de T11** : `diag.sh` et `gen_skills.sh` ne consomment que
  `compose_remote` et `$WORK_DIR`.
- **T10 est totalement indépendante** — c'est ce qui la rend parallélisable.

### Ce qui se parallélise ici

✅ **T10 (Infra) et T8+T9 (Engine) en parallèle, sans aucun contact.** `prepare_server.sh`
s'exécute *sur la cible*, via `ssh … bash -s` ; il n'a accès ni à `jq` localement ni aux
helpers de l'engine, et garde ses propres `log`/`ok`/`warn`. Aucun fichier commun.

✅ **La CI du dépôt (Infra) en parallèle de tout.**

❌ **T11 ne se parallélise pas.** Elle réécrit intégralement `engine/lib/steps.sh` et
touche `ssh_remote.sh`. Une seule personne dessus, et personne d'autre dans ces deux
fichiers pendant ce temps.

### Point de synchronisation obligatoire

**À la fin de T12** : la liste définitive des seize étapes est figée. C'est le contrat
**C2**, et c'est le signal de départ du worker du jalon 2. Tant qu'elle bouge, le Panel ne
doit pas écrire son `pipeline.py`.

---

## 5. Jalon 2 — Panel minimal

**Objectif** : `docker compose up` donne une URL fonctionnelle. Auth, une app, logs en
direct.

**Prérequis** : jalon 1.

### Panel / Python — 65 %

| Lot | Livrables concrets | Bloqué par |
|---|---|---|
| **Modèles** | `panel/models.py` (SQLModel) : `User`, `Target`, `App`, `Run`, `Step`. Migrations | **rien** — démarrable immédiatement |
| **Authentification** | argon2, cookie signé `HttpOnly`/`SameSite=Strict`/`Secure`, token CSRF sur toutes les mutations, vérification `Origin`, rate limiting `/login` (5 / 5 min / IP) | **rien** |
| **Validation** | `panel/spec.py` (Pydantic `AppSpec`), regex de nom d'app `^[a-z][a-z0-9-]{1,30}$` | contrat **C3** (déjà figé) |
| **API** | `panel/api/` : `POST /login`, `/logout` ; CRUD `/targets` (avec test SSH à la création) ; `/apps`, `POST /apps/{id}/deploy` ; `GET /runs/{id}`, `GET /runs/{id}/events` (SSE) ; `/healthz`, `/readyz` | modèles + auth |
| **Pipeline** | `panel/pipeline.py` : la séquence d'étapes en **constante Python**, pas en table | contrat **C2** — fin de T12 du jalon 1 |
| **Worker** | `panel/worker/` : job RQ = un run. Écrit `spec.json`/`env.json` en 600, `subprocess.run` sur `engine/bootstrap.sh`, streame stderr vers un fichier **et** Redis pub/sub, parse la ligne JSON de stdout, écrit dans `Step`. Code 1 → un retry avec backoff, code 2 → arrêt. Timeouts : 30 min par run, 10 min par étape | contrats **C1**, **C2**, **C4** |
| **Réconciliation** | au démarrage, tout `Run` en `running` dont le job RQ n'existe plus est marqué `failed` avec un message explicite | worker |
| **Secrets** | chiffrement Fernet, clé depuis `PANEL_SECRET_KEY` ; déchiffrement **uniquement** au moment d'écrire `env.json` | modèles + **C7** (d'où vient la clé) |
| **Frontend** | Jinja2 + JS vanilla, pas de framework. Trois écrans : cibles, applications, run en direct (étapes à gauche, logs SSE à droite, auto-scroll, codes ANSI nettoyés) | API |
| **Tests** | `pytest` : auth, validation de nom, réconciliation au minimum | au fil de l'eau |
| **Suppression** | `web/` disparaît entièrement : Flask, templates, JS, `start.sh` | — |

### Infra & Sécurité — 25 %

| Lot | Livrables concrets | Bloqué par |
|---|---|---|
| **Image** | `Dockerfile` unique pour `panel` et `worker` (mêmes dépendances, commandes différentes), UID non-root, `jq` + client SSH + client Docker embarqués | — |
| **Stack** | `compose.yml` racine : `panel` (gunicorn + workers **threads**, pas gevent — le worker lance des subprocess), `worker` (`rq worker`), `postgres:16-alpine`, `redis:8-alpine` | — |
| **Durcissement de la stack** | `no-new-privileges`, UID non-root, healthchecks sur les **quatre** services, `depends_on: { condition: service_healthy }`, port du panel publié sur `127.0.0.1` **uniquement** | — |
| **Volumes et secrets** | volume partagé `runs/` entre `panel` et `worker` ; clé SSH du worker par **secret Docker** en lecture seule ; `PANEL_SECRET_KEY` par secret ou variable d'environnement, jamais committée. **Aucun montage de `/var/run/docker.sock`, nulle part** | — |
| **Documentation d'exploitation** | comment mettre le panneau derrière BunkerWeb avec `auth_basic` + allowlist IP — **en plus** de l'auth applicative, pas à la place | jalon 4 pour la partie BunkerWeb |
| **CI du dépôt** | ajout de `pytest` au workflow existant | tests Panel |

### Engine / Bash — 10 % (sous-chargé, voir §9)

| Lot | Livrables concrets |
|---|---|
| **Support du worker** | corriger ce que l'intégration réelle révèle du contrat (le premier vrai consommateur trouve toujours quelque chose) |
| **Dette de test** | écrire le test de **pureté stdout** des `ui_*` et de `check_prereqs`, reporté au jalon 1 — c'est l'invariant le plus sensible du projet et il n'a aujourd'hui aucune garde en régression |
| **Avance sur le jalon 3** | écrire et tester `step_open_firewall_ports` / `step_close_firewall_ports` et les étapes de `destroy`, avec des fixtures ; elles ne dépendent que d'`env.json` |

### Ce qui se parallélise ici

✅ **Beaucoup, et c'est le moment de l'exploiter.** Modèles, auth et validation (Panel) ne
dépendent d'**aucun** contrat avec l'engine : le Panel peut écrire une semaine de code sans
parler à personne. L'image et la stack (Infra) sont indépendantes du contenu de `panel/`
tant que **C7** est fixé (nom de l'image, chemin du volume `runs/`, utilisateur, variables
d'environnement attendues) — une demi-heure de discussion en début de jalon suffit.

❌ **Le worker ne se parallélise pas avec le jalon 1.** Il est le consommateur direct de
**C1** et **C2**. L'écrire pendant que la liste d'étapes bouge encore, c'est le réécrire.

### Points de synchronisation obligatoires

1. **Début de jalon** : figer **C7** (image, volume, UID, secrets) entre Panel et Infra.
2. **Avant d'écrire le worker** : **C1** et **C2** confirmés — donc `docs/ENGINE.md` lu et
   accepté par le Panel.
3. **Recette** : le critère d'acceptation n°6 (`docker compose restart worker` pendant un
   run → run marqué `failed`, pas bloqué en `running`) se teste à deux, Panel et Infra.

---

## 6. Jalon 3 — Multi-app

**Objectif** : plusieurs applications, sur plusieurs cibles, sans collision, avec un cycle
de vie complet **incluant la destruction**.

**Prérequis** : jalon 2.

### Panel / Python — 45 %

| Lot | Livrables concrets |
|---|---|
| **Allocateur de ports** | table `PortAllocation (id, target_id, app_id, service_id, port, allocated_at)` ; plage configurable par cible (défaut 10000-19999) ; allocation **atomique** — transaction avec `SELECT … FOR UPDATE` sur la cible, ou contrainte d'unicité `(target_id, port)` + retry sur conflit ; libération à la destruction |
| **Injection** | les ports alloués sont écrits dans `env.json` avant l'appel à l'engine. **L'engine ne décide jamais d'un port** |
| **Cibles multiples** | l'hôte local est une cible comme les autres (`is_local: true`, `DOCKER_HOST=ssh://user@172.17.0.1`) ; test de connexion à la création : SSH, `docker version`, version de Compose, espace disque ; provisioning marqué **au niveau de `Target`**, pas de l'app |
| **Séquence `destroy`** | orchestration des 7 étapes, confirmation explicite dans l'UI (retaper le nom de l'app), point d'extension pour la suppression BunkerWeb (jalon 4), **le dépôt GitHub n'est pas supprimé** — proposer un lien, laisser l'humain décider |
| **Concurrence** | un seul run actif par app (**verrou en base**, pas de fichier lock) ; plusieurs apps en parallèle sur la même cible ; verrou **par cible** pour les opérations qui touchent un état global (ufw, provisioning) |

### Engine / Bash — 30 %

| Lot | Livrables concrets |
|---|---|
| **Pare-feu dynamique** | `step_open_firewall_ports` : pour chaque port alloué, `ufw allow from <IP BunkerWeb> to any port <port> proto tcp`, avec le commentaire `deploymatic:<app-slug>`. `step_close_firewall_ports` : suppression **par commentaire** |
| **Étapes de destruction** | `docker compose down --volumes --remove-orphans`, suppression des images de l'app, suppression du réseau Docker, suppression de `runs/<slug>/`. **Chaque étape tolérante à l'absence** : détruire une app à moitié créée doit fonctionner |
| **Provisioning par cible** | `step_prepare_server` devient idempotent au niveau cible et non plus au niveau app |

### Infra & Sécurité — 25 %

| Lot | Livrables concrets |
|---|---|
| **Vérification terrain de l'IP source** | confirmer sur la machine que l'IP vue par l'hôte cible est bien celle de BunkerWeb. Si BunkerWeb sort derrière un NAT ou un bridge Docker, la règle ufw ne matchera pas. **Documenter la procédure de vérification** — c'est le genre de détail qui coûte une heure de débogage à chaque nouvelle personne |
| **Politique de ports** | plages par cible, conventions de nommage des règles ufw, interaction entre les règles Docker et ufw (la chaîne `DOCKER-USER` est un piège classique) |
| **Réconciliation** | commande qui compare la base à l'état réel de l'hôte (`ss -ltn` via SSH) : la base **peut** diverger de la réalité, et le jour où ça arrive il faut un outil, pas une intuition |

### Dépendances

- L'allocateur (Panel) **bloque** les étapes ufw (Engine) : sans ports alloués, rien à
  ouvrir. Mais les étapes ufw se testent sur un `env.json` écrit à la main — l'Engine n'a
  donc pas à attendre que l'allocateur soit fini, seulement que **C5** soit décidé.
- `destroy` (Panel) **dépend** des étapes de destruction (Engine). Même remarque : chaque
  étape est testable seule.
- La vérification de l'IP source (Infra) **conditionne** le jalon 4 : si l'IP vue n'est pas
  la bonne, l'exposition ne fonctionnera pas et il vaut mieux le découvrir maintenant.

### Ce qui se parallélise

✅ Les trois rôles avancent en parallèle après une seule réunion de trente minutes fixant
**C5** : plage de ports, qui alloue, qui libère, et ce qui arrive exactement dans
`env.json .ports`.

❌ Le critère d'acceptation n°5 (« deux déploiements concurrents sur la même cible
n'entrelacent pas leurs modifications ufw ») est une recette **à trois** : verrou Panel,
étape Engine, observation Infra.

---

## 7. Jalon 4 — BunkerWeb

**Objectif** : chaque application est exposée automatiquement derrière BunkerWeb, avec
TLS, et son service est supprimé avec elle.

**Prérequis** : jalon 3 (les ports alloués sont l'entrée du mapping).

### Infra & Sécurité — 55 % (le pilote de ce jalon)

| Lot | Livrables concrets |
|---|---|
| **Client** | `panel/bunkerweb.py` : `POST /auth` en Basic → token Biscuit réutilisé en `Bearer`, **cache du token et renouvellement avant expiration** (`API_BISCUIT_TTL_SECONDS`, 3600 s par défaut) ; timeouts ; retry avec backoff sur 5xx, **pas** de retry sur 4xx ; erreurs remontées avec le message de l'API ; mode `dry_run` qui journalise sans émettre |
| **Mapping** | `spec.json` → `SERVER_NAME`, `USE_REVERSE_PROXY`, `REVERSE_PROXY_URL_n` / `REVERSE_PROXY_HOST_n`, `AUTO_LETS_ENCRYPT`. Ordonner par **longueur de chemin décroissante** (`spec_exposed_ids_by_path_length` existe déjà côté engine, la même règle s'applique ici) |
| **Deux vérifications sur une app de test, avant de généraliser** | (a) le `/` final sur `REVERSE_PROXY_HOST_1` retire-t-il réellement le préfixe `/api` ? **Confirmer, pas supposer.** (b) la précédence des chemins numérotés : le plus spécifique gagne-t-il ? |
| **Sécurité du compte** | le compte utilisé porte des permissions **admin-équivalentes** (cf. [`SECURITY.md`](SECURITY.md) §7) : chiffré en base, jamais journalisé, jamais renvoyé par l'API. Vérifier `API_WHITELIST_IPS` |
| **TLS** | `AUTO_LETS_ENCRYPT`, `BW_DEFAULT_DOMAIN`, ordre de création des vhosts |

### Panel / Python — 30 %

| Lot | Livrables concrets |
|---|---|
| **Câblage des étapes** | `register_bunkerweb` (idempotente : `GET /services/{slug}` → `POST` si absent, `PATCH` si présent, puis `POST /instances/reload`), `unregister_bunkerweb` branchée dans `destroy`, `validate_public` |
| **`validate_public`** | `curl` sur l'URL publique, avec **fallback** `curl -H "Host: <server_name>" http://<ip bunkerweb>/` si le DNS ne résout pas encore. C'est le correctif du bug historique où la validation par IP prenait un 404 dès qu'un hostname était configuré |
| **Configuration** | `BW_API_URL` (défaut `http://10.13.3.211:7070`), `BW_API_USERNAME`, `BW_API_PASSWORD`, `BW_DEFAULT_DOMAIN`, `BW_AUTO_TLS` ; bouton « tester la connexion BunkerWeb » (`GET /ping` puis `POST /auth`) |
| **Robustesse** | API injoignable → message d'erreur clair, **pas de trace Python brute**, et l'app **reste déployée** : l'exposition est une étape, pas le déploiement (critère d'acceptation n°6) |

### Engine / Bash — 15 % (sous-chargé, voir §9)

Le hostname public et l'URL à valider transitent par `env.json` ; l'engine n'a besoin
d'aucune connaissance de BunkerWeb. Contribution : exposer proprement ce dont le mapping a
besoin (`spec_exposed_ids_by_path_length` est déjà là) et vérifier que les ports publiés
correspondent bien à ce que le mapping annonce.

### ⚠️ Une décision à prendre **avant** de commencer ce jalon

Les sources ne tranchent pas un point : **les étapes `register_bunkerweb`,
`unregister_bunkerweb` et `validate_public` sont-elles des étapes de l'engine (bash +
`curl`) ou des étapes exécutées en Python par le worker ?**

- La feuille de route les appelle « étapes ajoutées », ce qui suggère des étapes de
  l'engine ;
- mais elle place le client dans `panel/bunkerweb.py` et précise que « le panneau parle à
  l'API BunkerWeb depuis le worker ».

Les deux lectures sont défendables. **Recommandation** : en faire des étapes **Python**,
parce que le contrat de l'engine interdit explicitement à une étape de connaître
l'existence du panel, et qu'un client HTTP avec cache de token et backoff est pénible à
écrire correctement en bash. La contrepartie est que le pipeline gagne un **second type
d'étape**, et que le modèle `Step` et le worker doivent le supporter (une étape « interne »
sans `subprocess`). C'est un travail supplémentaire côté Panel qu'il faut décider en début
de jalon 4, pas au milieu.

### Ce qui se parallélise

✅ Le client BunkerWeb (Infra) s'écrit et se teste **seul**, contre l'API réelle, sans rien
attendre du reste. C'est le premier lot à démarrer.

❌ Le câblage des étapes (Panel) attend l'interface du client. D'où l'intérêt de figer
**C8** — la signature des méthodes du client — dès le premier jour, avant l'implémentation.

---

## 8. Jalons 5 et 6

### Jalon 5 — Génération par IA

**Prérequis** : jalon 4.

| Rôle | Charge | Lots |
|---|---|---|
| **Panel** | 65 % | `panel/generator.py` (API Anthropic, **deux appels séparés** — d'abord le spec, petit et validable, puis le code guidé par le spec déjà validé ; sortie JSON stricte nettoyée défensivement ; prompt et réponse journalisés dans `Run` ; timeout, rate limit, coût estimé). `panel/validator.py` (les trois niveaux : schéma Pydantic, analyse statique des Dockerfiles, cohérence — **tous bloquants**, deux tentatives de régénération maximum). Étapes `ai_generate_spec`, `ai_generate_code`, `validate_generated`, `await_approval` (statut `pending_approval`, expiration 24 h). UI d'approbation : spec rendu lisible, arborescence, contenu des Dockerfiles, deux boutons |
| **Infra** | 20 % | **Réseau par app sans egress libre** pour les conteneurs générés ; maintenance de l'allowlist d'images de base ; stockage chiffré de la clé API et vérification qu'elle n'apparaît ni dans les logs, ni dans les réponses HTTP, ni en clair en base ; revue du validateur statique (c'est un contrôle de sécurité, il mérite un deuxième regard) |
| **Engine** | 15 % | Vérifier qu'une app générée respecte ce que `gen_compose` sait produire ; ajuster le squelette de durcissement si le contrat d'application évolue ; **écrire le test qui prouve qu'aucun appel de build n'est émis avant l'approbation** (critère d'acceptation n°5) |

**Dépendance forte** : le validateur doit exister **avant** que le générateur ne serve à
quoi que ce soit. Écrire le validateur en premier, avec des specs forgés comme cas de test
(montage de `/var/run/docker.sock`, Dockerfile finissant par `USER root`) — ce sont
exactement les critères d'acceptation n°2 et 3.

**Parallélisation** : ✅ le validateur (Panel) et le durcissement réseau (Infra) sont
indépendants. ❌ l'UI d'approbation dépend du format de sortie du générateur.

### Jalon 6 — Scanners

**Prérequis** : jalon 5.

| Rôle | Charge | Lots |
|---|---|---|
| **Infra** | 40 % | Intégration Trivy + Grype + Syft en conteneurs éphémères **sur l'hôte cible**, après le build et **avant** le premier `compose up` ; **cache de base de vulnérabilités sur un volume nommé par cible** (sinon chaque scan retélécharge des centaines de mégaoctets — c'est le critère d'acceptation n°5) ; politique par défaut `fail_on: HIGH,CRITICAL`, `ignore_unfixed: true`, `grace_period_days: 0` ; SBOM CycloneDX conservé |
| **Panel** | 35 % | Table `ScanResult (run_id, image, scanner, severity, count, findings, sbom_path)` ; **dérogation explicite, horodatée, avec justification obligatoire**, enregistrée dans `Run` ; onglet Sécurité par app : dernier scan, comparaison des deux scanners, tendance sur les derniers runs, téléchargement du SBOM. **Afficher ce que l'un trouve et pas l'autre** — c'est tout l'intérêt d'en avoir deux |
| **Engine** | 25 % | Étapes `scan_images`, `generate_sbom`, `scan_dockerfiles` (hadolint), `scan_compose` (`trivy config`), toutes placées après `build_images` et avant `deploy_stack` ; `gen_workflow.sh` aligné sur la même politique, avec une variable `SCANNERS="trivy grype"` pilotant une **matrice** — ajouter un scanner doit rester une seule ligne à changer ; upload des SBOM en artefacts du run GitHub |

**Point de synchronisation** : la politique de scan est écrite **deux fois** (panneau et
workflow CI généré) et le critère d'acceptation n°6 exige qu'elles soient identiques.
Infra définit la politique, Engine et Panel l'appliquent chacun de son côté — c'est
exactement le genre de duplication qui diverge silencieusement. Un test comparant les deux
vaut mieux qu'une promesse.

---

## 9. Les déséquilibres, dits franchement

**Le jalon 2 est massivement Python.** Deux tiers du travail sont dans `panel/`, et
l'Engine n'a rien de structurel à faire. **Le jalon 4 est massivement Infra** : le client
BunkerWeb, le mapping et les vérifications terrain concentrent la difficulté. Ce n'est pas
un défaut du découpage, c'est la forme du produit.

Trois façons de lisser, par ordre de préférence :

| Jalon | Qui est en sous-charge | Ce qu'il prend en renfort |
|---|---|---|
| **1** | Panel | Relecteur désigné de `docs/ENGINE.md` (il est le consommateur du contrat). Démarrage des lots non bloqués du jalon 2 : modèles, auth, validation Pydantic |
| **2** | Engine | (a) La dette de test reportée du jalon 1 — **pureté stdout des `ui_*` et de `check_prereqs`**, l'invariant le plus sensible sans garde en régression. (b) **Avance sur le jalon 3** : étapes ufw et étapes de `destroy`, testables sur un `env.json` écrit à la main. (c) Binôme sur le worker : c'est lui qui connaît les codes de sortie et le comportement du `trap` |
| **4** | Engine | (a) L'app de test qui sert aux deux vérifications BunkerWeb (préfixe `/api` et précédence des chemins) — la préparer et l'automatiser. (b) **Prendre de l'avance sur les étapes de scan du jalon 6**, qui ne dépendent d'aucun contrat nouveau |
| **5** | Engine | La conformité `gen_compose` ↔ contrat d'application, et le test « aucun build avant approbation » |

Deux principes qui valent mieux qu'un tableau :

- **Personne ne reste sans travail sur son propre domaine.** Prêter une personne à un autre
  domaine pendant un jalon détruit le bénéfice du découpage (deux personnes dans `panel/`
  = conflits) et lui fait perdre le contexte du sien.
- **Prendre de l'avance sur son propre domaine au jalon N+1 est presque toujours le
  meilleur usage d'une sous-charge**, parce que les étapes de l'engine se testent contre
  des fixtures JSON écrites à la main, sans dépendre du panneau.

---

## 10. Par quoi commencer demain matin

### Engine / Bash

1. **Terminer la tâche 7** (le round de correction en cours sur `spec_get`).
2. **Attaquer la tâche 8**, `lib/gen_compose.sh` — c'est le chemin critique du jalon 1 :
   T9 et T11 l'attendent. Écrire `test_gen_compose.sh` d'abord.
3. Avant d'écrire une ligne de la tâche 11, **relire le pointeur `ssh_remote.sh` / `OVH_*`**
   de [`CURRENT-STATE.md`](CURRENT-STATE.md) §4 : c'est une panne silencieuse qui attend.

### Infra & Sécurité

1. **La tâche 10**, `prepare_server.sh` — indépendante, immédiatement démarrable, et elle
   débloque la tâche 11.
2. En parallèle, **la CI de ce dépôt** : `bash -n` + `shellcheck` + `engine/tests/run.sh`
   sur chaque push. Personne ne l'a prise, c'est le point n°16 de la dette technique, et
   c'est une demi-journée.
3. Ouvrir un fichier de notes pour **C7** (image, volume `runs/`, UID, secrets) : ce sera
   la première conversation du jalon 2.

### Panel / Python

1. **Lire, dans cet ordre** : `engine/lib/runtime.sh` (le contrat), `engine/lib/config.sh`
   (les entrées), `engine/bootstrap.sh` (le dispatcher), puis
   [`ARCHITECTURE.md`](ARCHITECTURE.md) §4.
2. **Écrire `panel/models.py` et `panel/spec.py`** — les cinq modèles SQLModel et le schéma
   Pydantic `AppSpec`. Aucun contrat ne les bloque, et `AppSpec` doit refléter
   `engine/templates/spec.demo.json` (contrat **C3**).
3. **Écrire l'authentification et ses tests `pytest`** : argon2, cookie signé, CSRF,
   `Origin`, rate limiting. C'est du travail sans dépendance, et c'est ce qui rend le
   panneau déployable.
4. Se déclarer **relecteur de `docs/ENGINE.md`** dès qu'il sort : c'est le document dont il
   sera le premier consommateur, et une ambiguïté relevée maintenant coûte dix fois moins
   cher qu'un worker à réécrire.

### La seule réunion utile de la semaine

Trente minutes, à trois, pour figer **C7** (image et stack du panneau) et confirmer que
**C1 à C4** sont bien lus et acceptés par tout le monde. Le reste se fait en écrivant du
code.

---

## 11. Documents liés

- [`ROADMAP.md`](ROADMAP.md) — le périmètre et les critères d'acceptation des six jalons.
- [`CURRENT-STATE.md`](CURRENT-STATE.md) — l'état réel, les points reportés, les pièges.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — les contrats référencés ici sous C1 à C8.
- [`CONVENTIONS.md`](CONVENTIONS.md) — à lire avant la première contribution.
- [`SECURITY.md`](SECURITY.md) — ce qui est protégé et ce qui reste à faire.
