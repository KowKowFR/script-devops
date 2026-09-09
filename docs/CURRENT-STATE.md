# État des lieux — 9 septembre 2026

Instantané factuel. Il est daté parce qu'il périme vite.

Pour le périmètre et la cible, voir [ROADMAP.md](ROADMAP.md). Pour qui fait quoi,
voir [TEAM-SPLIT.md](TEAM-SPLIT.md).

**Jalon 1 : TERMINÉ.** 15 tâches sur 15, 255 assertions vertes.
**Dépôt public :** https://github.com/KowKowFR/script-devops

---

## En une phrase

L'engine bash a quitté Kubernetes pour Docker Compose et **déploie réellement** :
il a installé Docker sur une Ubuntu vierge, construit les images sur la cible,
démarré la stack et validé sa santé. Le plan du jalon 2 est écrit ; le panneau
Python reste à construire.

## La preuve qui compte

```
$ bash engine/bootstrap.sh --workspace testvm --step validate_deployment
{"ok":true,"data":{"services_ok":2}}

$ ssh <cible> 'docker ps'
tp-app-api-1    Up (healthy)
tp-app-web-1    Up (healthy)
```

Contre une VM Lima Ubuntu 24.04, en SSH sur le port 60122, **sans aucune entrée
dans le `~/.ssh/config` de la machine hôte**.

---

## La suite de tests

```
test_gen_compose     68 ok
test_gen_workflow    54 ok
test_config          42 ok
test_ssh_remote      24 ok
test_runtime         18 ok
test_units           15 ok
test_dispatcher      13 ok
test_gen_micro        9 ok
test_smoke            4 ok
────────────────────────────
                    255 assertions — TOUT PASSE
```

Plus, à chaque exécution : `bash -n` sur tous les scripts et
`shellcheck --severity=error`.

Lancer : `bash engine/tests/run.sh`, ou `bash engine/tests/run.sh test_config`
pour une seule suite. Voir [CONVENTIONS.md](CONVENTIONS.md).

---

## Les critères d'acceptation

| # | Critère | État |
|---|---|---|
| 1 | `bash -n` sur tous les `.sh` | ✅ |
| 2 | `shellcheck --severity=error` sans erreur | ✅ |
| 3 | Plus de mentions Kubernetes involontaires sous `engine/` | ✅ |
| 4 | Plus aucun `source` de fichier de configuration | ✅ |
| 5 | Chaque `--step` renvoie exactement une ligne JSON | ✅ |
| 6 | `--all` déploie l'app de démo de bout en bout | 🟡 pipeline réel réussi, bloc GitHub non exercé |
| 7 | Le compose généré passe `docker compose config --quiet` | ✅ |

Le détail de chaque vérification est dans
[JALON-1-VERIFICATION.md](JALON-1-VERIFICATION.md).

**Pourquoi le 6 reste en nuance.** Le pipeline complet a réellement tourné —
`prepare_server` a installé Docker CE, Compose, ufw et fail2ban sur une Ubuntu
vierge en une minute, `build_images` a construit les images sur la cible en
transférant le contexte par SSH, `deploy_stack` a démarré la stack et
`validate_deployment` l'a validée. Mais le bloc GitHub n'a été exercé que sur son
chemin désactivé, faute de compte de test, et le mode d'authentification par mot
de passe n'est couvert que par des tests unitaires — la VM n'accepte que la clé.
Un « ✅ » ici serait plus flatteur qu'exact.

---

## La cible SSH de test

Ajout hors plan initial, et l'un des plus utiles. Une VM Lima Ubuntu 24.04 avec
systemd, pilotable en une commande :

```bash
engine/tools/test-target.sh up      # ~90 s au premier lancement, 11 s ensuite
engine/tools/test-target.sh status
engine/tools/test-target.sh env     # produit un env.json prêt à l'emploi
engine/tools/test-target.sh down
```

Utilisateur `devops`, clé SSH dédiée, `sudo NOPASSWD` sans TTY, et **Docker
volontairement absent au départ** — sans ça, `prepare_server.sh` n'aurait aucun
travail à faire et on ne testerait rien. Voir [TEST-TARGET.md](TEST-TARGET.md).

**Attention : la VM n'est plus vierge.** Docker, ufw, fail2ban et la stack
`tp-app` y tournent depuis la validation. Pour retrouver un état de départ propre :
`engine/tools/test-target.sh down` puis `up`.

---

## Ce qui marche

| Capacité | État |
|---|---|
| Exécuter une étape nommée (`--step`) | ✅ 16 étapes |
| Configuration et spécification en JSON | ✅ plus aucun `source` |
| Générer `deploy/compose.yml` depuis un spec | ✅ durci, échappement délégué à `jq` |
| Générer les sources de l'app de démo | ✅ nginx non privilégié, `services/` |
| Générer les 5 Skills Claude Code | ✅ `docker-deploy`, rollback par interrogation de la cible |
| Générer le workflow CI/CD | ✅ `IMAGE_TAG`, `DOCKER_HOST=ssh://`, rollback |
| Provisionner une cible en Docker | ✅ **exécuté pour de vrai** |
| Construire les images sur la cible | ✅ **exécuté pour de vrai** |
| Déployer et valider une stack | ✅ **exécuté pour de vrai** |
| Piloter Docker à distance | ✅ wrapper `ssh`, socket jamais monté |
| Diagnostiquer une stack | ✅ `cmd_doctor`, `cmd_logs`, `cmd_stack_info` |
| Cible SSH de test reproductible | ✅ Lima, une commande |

## Ce qui ne marche pas encore

| Capacité | Bloqué par |
|---|---|
| Interface web | jalon 2 — `web/` est cassé et sera supprimé |
| Multi-application, allocation de ports | jalon 3 |
| Exposition derrière BunkerWeb | jalon 4 |
| Génération par IA | jalon 5 |
| Scanners de vulnérabilités | jalon 6 |

**`web/`** est la seule chose volontairement cassée. L'interface Flask ne
fonctionne plus depuis que `bootstrap.sh` a déménagé sous `engine/`. Elle est
supprimée au jalon 2 et remplacée par le panneau FastAPI. Ne la réparez pas.

---

## Ce que les revues ont trouvé

Chaque tâche a été relue par un agent distinct, chargé d'**attaquer** le code
plutôt que de le lire. Ce qu'ils ont trouvé et qui n'était pas dans le plan :

**`DOCKER_HOST=ssh://` ne peut pas porter d'identité SSH.** Le plus important, et
seule l'exécution réelle pouvait le révéler. Docker invoque le binaire `ssh` sans
lui passer `-i` et n'offre aucune option pour le faire. Le scénario était le pire
possible : `validate_ssh` réussissait, puis `build_images` échouait en
`Permission denied (publickey)` — l'échec arrivait après qu'une validation ait
donné une fausse assurance. Corrigé par un wrapper `ssh` temporaire posé en tête
de `PATH`, qui injecte l'identité ou route par `sshpass`.

**Une injection YAML dans le générateur de Compose.** `jq --arg` empêche
l'exécution de commandes shell, mais pas la corruption de structure YAML. Un
volume valant `normal:/data\n    privileged: true` faisait apparaître
`privileged: true` comme clé de service, et Compose l'acceptait. Les trois
« interdits absolus » du projet étaient contournables par le contenu d'un
`spec.json` — grave, parce qu'au jalon 5 ces specs seront produits par un LLM.
Corrigé, puis revérifié contre **19 vecteurs** : tags YAML, ancres, alias,
séparateurs de document, caractères de contrôle, UTF-8 multi-octets.

**Un `die()` avalé, avec un appel réseau à la clé.** En bash, `VAR="$(cmd)" autre`
ne propage pas l'échec de `cmd` sous `set -e`. Le JSON d'erreur devenait la valeur
du jeton GitHub, provoquant un vrai appel à l'API avec un message d'erreur en
guise de bearer token.

**L'engine pouvait sortir sans aucune ligne JSON.** Une variable non liée sous
`set -u` ne déclenche pas le trap `ERR`, seulement `EXIT`.

**La ligne JSON d'échec partait dans le fichier généré.** La redirection
`{ … } > compose.yml` détournait la sortie standard.

**Un rollback qui ne pouvait pas rollback.** `deploy/.image-history` ne pouvait
jamais être peuplé : le clone du runner CI est jeté après chaque exécution, celui
du développeur ne déploie jamais. Le fichier a été supprimé au profit d'une
interrogation du démon de la cible et de `git log`.

**Une assertion qui ne testait rien.** Un motif contenant un retour à la ligne
passé à `grep -F` est traité comme une **liste d'alternatives**, pas comme une
sous-chaîne. `assert_contains` refuse désormais bruyamment ce cas.

**La locale française cassait la conversion des unités.** `awk` produisait
`0,200` au lieu de `0.200`.

---

## Points reportés

Aucun n'est bloquant.

| Point | Où |
|---|---|
| Le HTML de l'app de démo parle encore de « pod Kubernetes » et « ingress Traefik » | `lib/gen_microservices.sh` |
| `validate_ssh` mélange stdout et stderr dans `data.banner` | `lib/steps.sh` |
| Le nettoyage du wrapper `ssh` n'est pas sous `trap` : un SIGINT laisserait un répertoire | `lib/ssh_remote.sh` |
| `_require_app_name` couple `rollback.sh` au format du workflow généré | `lib/gen_skills.sh` |
| `die` accepte un code non numérique et sort alors en 255 | `lib/runtime.sh` |
| `cfg` et `spec_get` renvoient un blob JSON si la valeur est un objet | `lib/config.sh` |
| Aucun test ne couvre la pureté stdout des `ui_*` | `lib/ui.sh` |
| Le contenu des volumes n'est pas contrôlé (`docker.sock` explicite passerait) | → jalon 5 |

---

## Et maintenant

Le **plan du jalon 2** est écrit : `docs/superpowers/plans/2026-09-08-jalon-2-panel-fastapi.md`,
24 tâches, avec cinq décisions d'architecture tranchées et argumentées. Il est
prêt à exécuter.

Deux choses qu'il faut savoir avant de l'attaquer :

- Le contrat de l'engine est **figé et documenté** dans [ENGINE.md](ENGINE.md).
  Le worker du jalon 2 s'y branche sans rien deviner.
- Le correctif `DOCKER_HOST` compte directement pour lui : le worker tournera
  dans un conteneur, avec une clé montée par un secret Docker et aucun
  `~/.ssh/config`. Sans le wrapper, il aurait échoué exactement comme le pipeline
  a échoué ici.

---

## Documents liés

- [ROADMAP.md](ROADMAP.md) — les 6 jalons
- [ENGINE.md](ENGINE.md) — le contrat de l'engine, référence pour le jalon 2
- [TEAM-SPLIT.md](TEAM-SPLIT.md) — répartition entre les trois rôles
- [ARCHITECTURE.md](ARCHITECTURE.md) — topologie, formats
- [SECURITY.md](SECURITY.md) — modèle de sécurité
- [CONVENTIONS.md](CONVENTIONS.md) — bash 3.2, tests, invariants
- [TEST-TARGET.md](TEST-TARGET.md) — la cible SSH de test
- [JALON-1-VERIFICATION.md](JALON-1-VERIFICATION.md) — les sept critères, en détail
