# État des lieux — 2026-09-08

Ce document dit ce qui marche, ce qui ne marche pas, et ce qui est cassé exprès. Il est
écrit pour que quelqu'un qui arrive comprenne la situation en cinq minutes sans lire le
plan d'exécution de 3 000 lignes.

> **Instantané mouvant.** Le jalon 1 est en cours d'exécution automatisée au moment où ces
> lignes sont écrites. Les faits ci-dessous proviennent du journal d'exécution
> `.superpowers/sdd/2026-09-08-jalon-1-engine-docker/progress.md`, des rapports de tâche du
> même répertoire, de l'historique git et de la lecture du code. La suite de tests n'a
> **pas** été relancée pour l'occasion, afin de ne pas interférer avec l'exécution en
> cours : les chiffres viennent des rapports de tâche.
>
> Dernier commit observé : `e456139 fix(engine): spec_get distingue présence/absence et
> champs falsy`.

---

## 1. En une phrase

Le jalon 1 (engine bash : K3s → Docker, pipeline → dispatcher JSON) est à **7 tâches sur
15**. Les fondations sont posées et testées — contrat de sortie, configuration JSON,
dispatcher, lecture du spec — mais **aucune étape de déploiement Docker n'est encore
écrite** : `engine/lib/steps.sh` contient toujours les étapes Kubernetes de l'ancien
système. Rien n'est déployable en l'état.

---

## 2. Le jalon 1 tâche par tâche

| # | Tâche | Statut | Trace |
|---|---|---|---|
| 1 | Réorganisation `engine/` + harnais de test | ✅ terminée | `73391fd..4776d04`, revue propre |
| 2 | `lib/units.sh` — unités k8s → Docker | ✅ terminée | `4776d04..71536ab`, revue propre |
| 3 | `lib/runtime.sh` — contrat de sortie, logs stderr | ✅ terminée | `71536ab..0bd9f95`, revue propre |
| 4 | `lib/config.sh` — lecture JSON + `tools/migrate-env.sh` | ✅ terminée | `0bd9f95..04256a4`, revue propre |
| 5 | `lib/ui.sh` — stderr, suppression des prompts | ✅ terminée | `04256a4..266f6f1`, propre après 2 rounds de correction |
| 6 | Dispatcher `engine/bootstrap.sh` | ✅ terminée | `266f6f1..1009061`, propre après 3 rounds |
| 7 | `spec.json` + helpers `spec_*` | 🟡 **en boucle de correction** | `db915ab` puis `e456139` ; 1 finding Important en cours |
| 8 | `lib/gen_compose.sh` — génération du Compose | ⬜ non commencée | — |
| 9 | `lib/gen_microservices.sh` — nginx non privilégié | ⬜ non commencée | — |
| 10 | `lib/prepare_server.sh` — provisioning Docker | ⬜ non commencée | — |
| 11 | `lib/steps.sh` — étapes réécrites | ⬜ non commencée | — |
| 12 | Bloc GitHub optionnel + workflow Compose | ⬜ non commencée | — |
| 13 | `lib/diag.sh` — diagnostic Docker | ⬜ non commencée | — |
| 14 | `lib/gen_skills.sh` — Skills Docker | ⬜ non commencée | — |
| 15 | Documentation + vérification des critères | ⬜ non commencée | produira `docs/ENGINE.md` et `docs/JALON-1-VERIFICATION.md` |

**Sur la tâche 7** : l'implémentation est écrite, commitée et revue. La revue a validé la
spécification et la sécurité (aucune tentative d'injection sur les identifiants de
service, les noms de champs ou le contenu du spec n'aboutit), mais a levé un point
Important — `spec_get` confondait un champ absent avec un champ valant explicitement
`false` ou `""`. Le correctif est commité (`e456139`) ; le tour de revue suivant n'est pas
encore consigné au journal.

---

## 3. Ce qui existe et fonctionne

### Le contrat de l'engine est en place et gardé par des tests

`engine/bootstrap.sh` est un dispatcher : `--step`, `--all`, `--list-steps`, `--dry-run`.
Le tableau `PIPELINE`, `run_pipeline`, `lib/state.sh`, `lib/collect.sh` et
`lib/workspace.sh` ont disparu.

`engine/lib/runtime.sh` fournit `emit_ok`, `emit_fail`, `die`, `retryable`,
`install_error_trap` et `_runtime_begin_step`. Trois bugs réels du contrat ont été trouvés
et corrigés pendant l'implémentation, chacun par un round de revue :

1. Une variable non liée sous `set -u` sortait **sans aucune ligne JSON** — le `trap ERR`
   ne voit pas ce cas. D'où le filet `trap EXIT` (`_exit_guard`), qui force un code 1
   plutôt que le `0` trompeur que bash présente au trap dans cette situation.
2. Le `trap ERR` pouvait produire une **deuxième** ligne JSON après un `emit_ok`.
3. La garde anti-doublon était à l'échelle du **processus** au lieu de l'**étape** : en
   mode `--all`, l'échec de toute étape suivant une étape ayant émis disparaissait de
   stdout.

### La configuration est du JSON, l'injection est fermée

`cfg`, `cfg_req`, `cfg_bool`, `cfg_port` lisent `runs/<ws>/env.json` par `jq --arg`.
`engine/tools/migrate-env.sh` convertit un ancien `.bootstrap-env` **sans le `source`**.
Détail : `cfg_port` refuse tout port hors de `[1024, 65535]`, ce qui est vérifié par la
fixture `env.min.json` qui contient volontairement un `ports.trop_bas: 80`.

### Le spec d'application est lisible

`spec_init`, `spec_service_ids`, `spec_get`, `spec_is_internal`, `spec_is_exposed`,
`spec_exposed_ids_by_path_length`. `engine/templates/spec.demo.json` décrit l'app de démo
(api Express + web nginx) ; `engine/tests/fixtures/spec.multi.json` ajoute un service `db`
sur image tierce en `internal: true`.

### Les conversions d'unités sont couvertes

`k8s_cpu_to_docker` et `k8s_mem_to_docker` dans `engine/lib/units.sh`, avec le plancher de
6 MiB imposé par Docker et le `LC_ALL=C` qui évite les virgules décimales en locale
française.

### Le provisioning n'installe plus rien à chaud

`check_prereqs` est non interactif : il constate et échoue, il n'installe plus `gum`. Les
vérifications conditionnelles sont correctes (`gh` seulement si `github.enabled`,
`sshpass` seulement en authentification par mot de passe, `ssh-keygen` seulement si les
deux conditions GitHub + clé sont réunies).

### Suite de tests

Au dernier point consigné (rapport de la tâche 7) :

| Fichier | Assertions |
|---|---|
| `test_config.sh` | 27 ok |
| `test_runtime.sh` | 18 ok |
| `test_units.sh` | 15 ok |
| `test_smoke.sh` | 4 ok |
| **Total vert** | **64** |
| `test_dispatcher.sh` | **12 sur 13** — la 13ᵉ est rouge exprès |

Plus, à chaque exécution de `engine/tests/run.sh` : `bash -n` sur tous les scripts de
`engine/`, et `shellcheck --severity=error` **si shellcheck est installé** (sinon la
vérification est sautée avec un message, sans faire échouer la suite).

---

## 4. Ce qui est cassé volontairement, et jusqu'à quand

| Quoi | Depuis | Jusqu'à | Pourquoi |
|---|---|---|---|
| **`web/`** (Flask) — `web/app.py:40` et `web/start.sh:33-35` pointent vers un `bootstrap.sh` à la racine qui n'y est plus | tâche 1 du jalon 1 | **jalon 2**, qui supprime `web/` entièrement | le déplacement sous `engine/` casse mécaniquement les chemins ; réparer une UI qui va disparaître serait du travail perdu |
| **`engine/lib/steps.sh`** — contient encore les étapes Kubernetes (`step_fetch_kubeconfig`, `step_apply_initial_manifests`, `step_generate_manifests`, `kubectl`, `INGRESS_HOST`) et appelle `gum_box`, `C_GREEN_HEX`, `C_NAVY_HEX`, supprimés à la tâche 5 | tâche 5 | **tâche 11**, réécriture complète | réécrire un fichier deux fois n'a pas de valeur ; la tâche 11 le remplace intégralement |
| **13ᵉ assertion de `test_dispatcher.sh`** (`--dry-run` sur `validate_ssh`) | tâche 6 | **tâche 11** | les étapes `step_*` n'existent pas encore ; c'est écrit dans le plan, ce n'est pas une régression |
| **`engine/lib/gen_manifests.sh`** — le générateur Kubernetes est toujours sur disque | — | **tâche 8**, qui le supprime | il disparaît en même temps que son remplaçant `gen_compose.sh` apparaît |
| **`engine/lib/ssh_remote.sh`** — lit encore `OVH_AUTH_METHOD`, `OVH_SSH_KEY_PATH`, `OVH_PASSWORD`, variables qui n'existent plus depuis la tâche 4 | tâche 4 | **tâche 11** | voir le point suivant : c'est une lacune du plan, pas un report délibéré |

### Le piège à ne pas rater à la tâche 11

Le contrôleur a repéré, avant la tâche 6, que le plan de la tâche 11 se contente
d'**ajouter** `docker_host_url` / `docker_remote` / `compose_remote` à `ssh_remote.sh`,
et **oublie de convertir** les trois lectures `OVH_*` existantes vers
`cfg target.auth_method`, `cfg target.ssh_key_path` et `cfg target.password`.

Sans cette conversion, `ssh_remote` retombe **silencieusement** sur le mode clé avec un
chemin de clé vide. C'est le type de panne qui produit un message SSH générique et coûte
une demi-journée. À corriger explicitement dans la tâche 11.

Deux autres pointeurs consignés pour la même tâche :

- vérifier que le branchement `step_check_prereqs() { check_prereqs; }` existe bien (le
  dispatcher cherche `step_check_prereqs`, `prereqs.sh` définit `check_prereqs`) ;
- renforcer l'assertion n°11 de `test_dispatcher.sh`, qui ne compte que les lignes de
  stdout et masquait ce bug : elle doit aussi vérifier `ok=true` ;
- vérifier qu'aucun appel à `gum_box` ne survit à la réécriture de `steps.sh`.

---

## 5. Points reportés, avec leur justification

Tous ces points sont consignés au journal d'exécution comme *deferred*. Aucun n'est un
oubli : chacun a été vu, arbitré, et laissé de côté sciemment.

| Point | Où | Pourquoi c'est reporté |
|---|---|---|
| `cfg` renvoie un blob JSON multi-lignes si la valeur pointée est un objet ou un tableau | `lib/config.sh` (tâche 4) | aucun appelant actuel n'est concerné ; **pointeur explicite vers la tâche 8**, où `gen_compose` consomme `cfg` intensivement |
| Idem pour `spec_get` sur un champ non scalaire | `lib/config.sh` (tâche 7) | même trappe, même raisonnement |
| Aucun test automatisé ne couvre la **pureté stdout** des `ui_*` ni de `check_prereqs` | tâche 5 | l'invariant le plus sensible du projet n'a **aucune garde en régression** : seule la revue manuelle l'a vérifié. À trancher en revue finale du jalon — c'est le report le plus discutable de la liste |
| `install_error_trap` est appelé **après** `config_init` : une erreur non-`die` survenant avant n'a ni `trap ERR` ni filet EXIT | `bootstrap.sh` (tâche 6) | défaut pré-existant, fenêtre étroite (validation du workspace et lecture d'`env.json`, qui échouent par `die`) |
| `die` accepte un code de sortie non numérique (`die 'x' abc` → 255) | `lib/runtime.sh` (tâche 3) | aucun appelant prévu ne le fait ; ajouter une garde coûterait plus que le risque |
| `LC_ALL=C` appliqué aussi à `printf` et `sed` alors que seul `awk` en a besoin | `lib/units.sh` (tâche 2) | bruit défensif, aucun comportement incorrect |
| L'assertion « trois étapes qui réussissent → 3 lignes » de `test_runtime.sh` survit à la mutation qu'elle est censée détecter | tâche 6 | elle est décorative **pour ce bug précis** ; les trois autres assertions font le travail. À reformuler ou à nuancer en commentaire |
| `assert_not_contains` n'a pas de commentaire de signature | `tests/helpers.sh` (tâche 1) | cosmétique |

### Arbitrages rendus en cours de route

Trois décisions ont modifié la lecture du plan et méritent d'être connues :

1. **Le `trap ERR` produit un code 1, pas un code 2.** Le texte du plan disait
   « `install_error_trap` → `trap ERR` qui appelle `die` » ; le code fait `emit_fail` puis
   `exit 1`. **Le code a raison** : une commande qui échoue de façon inattendue doit être
   réessayable. Les échecs fatals passent par un appel explicite à `die`, que le `trap ERR`
   n'intercepte pas (`exit` ne déclenche pas `ERR`). Aucune tâche suivante ne doit se fier
   à la formulation du plan.
2. **La regex de workspace l'emporte sur les fixtures.** Le workspace de test
   `_test_dispatch` était refusé par la règle du premier caractère alphanumérique. La
   fixture a été renommée en `test-dispatch` : c'est le contrôle de sécurité qui ferme la
   traversée de chemin, et les slugs du panel (jalon 2) commenceront eux aussi par une
   lettre.
3. **`ssh-keygen` a été ajouté aux prérequis conditionnels.** Le plan l'avait omis alors
   que le bloc GitHub l'utilise — lacune du brief, pas déviation de l'implémenteur.

### Bugs du plan corrigés par l'implémentation

- `engine/tests/run.sh` plantait sur un glob non résolu (`engine/tools/*.sh` tant que le
  répertoire était vide) ; une garde `[[ -f ]]` a été ajoutée.
- La locale `fr_FR` faisait produire `0,200` à `awk` au lieu de `0.200`. Reproduit par le
  relecteur, corrigé par `LC_ALL=C`.
- Deux coquilles de comptage dans le plan (« 13 assertions » pour 15, « 4 Skills » pour 5).

---

## 6. Ce qui n'a pas pu être vérifié

**Aucune cible SSH de test n'est disponible.** C'est une contrainte connue et actée avant
même la rédaction du plan, pas une découverte tardive.

Conséquence directe : le **critère d'acceptation n°6 du jalon 1** — « `--all` avec
`spec.demo.json` déploie l'app de démo de bout en bout sur une cible SSH de test » — **ne
sera pas validé dans ce jalon**. Il est remplacé par un `--dry-run` qui imprime les
commandes distantes sans les exécuter, et la tâche 15 doit le déclarer explicitement dans
`docs/JALON-1-VERIFICATION.md`.

Ce qui sera vérifié à la place :

- `--all --dry-run` traverse les seize étapes sans erreur, chacune imprimant une ligne
  `ok:true` ;
- les étapes de génération tournent réellement et produisent un `compose.yml` accepté par
  `docker compose config --quiet`.

Ce qui restera à vérifier dès qu'une cible existera, dans cet ordre :

1. `validate_ssh` — la connexion effective ;
2. `prepare_server` — l'installation de Docker sur une Ubuntu vierge ;
3. **`build_images` — `DOCKER_HOST=ssh://` et le transfert du contexte de build.
   C'est le point le plus incertain de tout le jalon** : ce mécanisme n'a jamais été
   exercé ici ;
4. `deploy_stack` — le démarrage réel des conteneurs ;
5. `validate_deployment` — les healthchecks et les `curl` locaux sur la cible.

Deux autres inconnues, plus loin dans la feuille de route, sont signalées comme « à
confirmer sur une app de test plutôt qu'à supposer » :

- **Jalon 4** : le `/` final sur `REVERSE_PROXY_HOST_1` est censé retirer le préfixe
  `/api`, comme un `proxy_pass` NGINX classique. Le comportement réel doit être confirmé.
- **Jalon 3** : l'IP source vue par l'hôte cible est-elle bien celle de BunkerWeb ? Si
  BunkerWeb sort derrière un NAT ou un bridge Docker, la règle ufw ne matchera pas.

---

## 7. Ce qui n'a même pas commencé

Les jalons 2 à 6 sont intégralement devant nous : il n'existe **aucune ligne de Python**
dans le répertoire `panel/` — le répertoire lui-même n'existe pas — ni de `compose.yml` à
la racine, ni de client BunkerWeb, ni d'allocateur de ports, ni d'intégration LLM, ni de
scanners dans le chemin du panneau.

Le `README.md` de la racine décrit encore, en détail et avec assurance, le système
Kubernetes d'avant. **Il est périmé** ; sa réécriture est la tâche 15 du jalon 1.

---

## 8. Documents liés

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — ce qu'on construit et pourquoi.
- [`CONVENTIONS.md`](CONVENTIONS.md) — comment contribuer sans casser les contrats.
- [`SECURITY.md`](SECURITY.md) — ce qui est protégé et ce qui ne l'est pas encore.
- [`TEAM-SPLIT.md`](TEAM-SPLIT.md) — qui prend quoi à partir de maintenant.
- [`ROADMAP.md`](ROADMAP.md) — le périmètre des six jalons.
