# État des lieux — 8 septembre 2026

Instantané factuel du projet. Il est daté parce qu'il périme vite : le jalon 1 est
en cours d'exécution au moment où ces lignes sont écrites.

Pour le périmètre et la cible, voir [ROADMAP.md](ROADMAP.md). Pour qui fait quoi,
voir [TEAM-SPLIT.md](TEAM-SPLIT.md).

**Dernier commit relevé :** `aa9ec1f` — 20 commits depuis le début du jalon 1.

---

## En une phrase

L'engine bash a quitté Kubernetes pour Docker Compose et sait maintenant exécuter
une étape nommée à partir de paramètres JSON. Il reste huit tâches pour recâbler
les étapes elles-mêmes. Rien du panneau Python n'existe encore.

---

## Ce qui marche aujourd'hui

| Capacité | État |
|---|---|
| Exécuter une étape nommée (`--step`) | ✅ opérationnel |
| Lister les étapes (`--list-steps`) | ✅ 16 étapes déclarées |
| Lire la configuration en JSON (`env.json`) | ✅ plus aucun `source` |
| Lire une spécification d'application (`spec.json`) | ✅ helpers `spec_*` |
| Générer `deploy/compose.yml` depuis un spec | ✅ y compris volumes, services internes |
| Convertir les unités Kubernetes → Docker | ✅ `200m`→`0.2`, `128Mi`→`128m` |
| Contrat de sortie JSON + codes 0/1/2 | ✅ avec filet de sécurité |
| Migrer un ancien `.bootstrap-env` | ✅ `engine/tools/migrate-env.sh` |
| Harnais de test | ✅ 140 assertions |

## Ce qui ne marche pas encore

| Capacité | Bloqué par |
|---|---|
| Exécuter réellement un déploiement | tâche 11 (les `step_*` sont encore en version Kubernetes) |
| Provisionner un serveur en Docker | tâche 10 |
| Interface web | jalon 2 — `web/` est cassé et sera supprimé |
| Multi-application, allocation de ports | jalon 3 |
| Exposition derrière BunkerWeb | jalon 4 |

---

## Jalon 1, tâche par tâche

| # | Tâche | État | Commits |
|---|---|---|---|
| 1 | Réorganisation `engine/` + harnais de test | ✅ terminée | `73391fd..4776d04` |
| 2 | `lib/units.sh` — conversion des unités | ✅ terminée | `71536ab` |
| 3 | `lib/runtime.sh` — contrat de sortie | ✅ terminée | `0bd9f95` |
| 4 | `lib/config.sh` — configuration JSON | ✅ terminée | `04256a4` |
| 5 | `lib/ui.sh` — stderr, suppression des prompts | ✅ terminée, 2 rounds | `47f70a5..266f6f1` |
| 6 | Dispatcher `--step` | ✅ terminée, 3 rounds | `ae84d64..1009061` |
| 7 | `spec.json` + helpers | ✅ terminée, 2 rounds | `db915ab..f3c233b` |
| 8 | `lib/gen_compose.sh` | 🟡 correctif livré, re-revue en cours | `d355bac..aa9ec1f` |
| 9 | `gen_microservices.sh` — nginx non privilégié | ⬜ à faire | |
| 10 | `prepare_server.sh` — provisioning Docker | ⬜ à faire | |
| 11 | `lib/steps.sh` — étapes réécrites | ⬜ à faire | |
| 12 | Bloc GitHub optionnel + workflow | ⬜ à faire | |
| 13 | `lib/diag.sh` — diagnostic Docker | ⬜ à faire | |
| 14 | `gen_skills.sh` — Skills Docker | ⬜ à faire | |
| 15 | Documentation + critères d'acceptation | ⬜ à faire | |

**7 tâches terminées sur 15.** Sept des huit restantes touchent des fichiers encore
en version Kubernetes.

---

## Tests

```
test_config          38 ok
test_gen_compose     53 ok
test_runtime         18 ok
test_units           15 ok
test_dispatcher      12 ok, 1 échec  ← volontaire, voir plus bas
test_smoke            4 ok
────────────────────────────
                    140 assertions, 139 vertes
```

Plus, à chaque exécution : `bash -n` sur tous les scripts et `shellcheck --severity=error`.

Lancer : `bash engine/tests/run.sh` (ou `bash engine/tests/run.sh test_config` pour
une seule suite). Voir [CONVENTIONS.md](CONVENTIONS.md) pour le harnais.

---

## Ce qui est cassé volontairement

Trois choses sont dans un état intermédiaire assumé. Ne les « réparez » pas.

**`web/`** — l'interface Flask ne fonctionne plus depuis que `bootstrap.sh` a
déménagé sous `engine/`. Elle est supprimée au jalon 2 et remplacée par le panneau
FastAPI. Rien à faire d'ici là.

**`engine/lib/steps.sh`** — encore en version Kubernetes. Il référence
`gen_manifests.sh` (supprimé), appelle `gum_box` (supprimé) et contient trois
`ui_confirm` interactifs qui bloqueraient un worker sans TTY. La tâche 11 le
réécrit intégralement.

**La 13e assertion de `test_dispatcher`** — « `--dry-run` réussit sans rien faire »
échoue parce qu'elle exécute réellement une étape, et que `steps.sh` est encore
l'ancienne version (variable `OVH_USER` non liée). Elle passera au vert à la
tâche 11. C'est le seul échec attendu de la suite ; tout autre échec est un vrai
problème.

---

## Ce qui a été trouvé en route

Les revues ont attrapé des choses qui n'étaient pas dans le plan. Elles valent
d'être connues.

**Une injection YAML dans le générateur de Compose.** `jq --arg` empêche
l'exécution de commandes shell, mais pas la corruption de la structure YAML. Un
volume valant `normal:/data\n    privileged: true` faisait apparaître
`privileged: true` comme clé de service — et Compose l'acceptait. Les trois
« interdits absolus » du projet (`privileged`, `network_mode`, socket Docker)
étaient contournables par le contenu d'un `spec.json`. C'est grave parce qu'au
jalon 5 ces specs seront produits par un LLM à partir d'un prompt utilisateur.
Corrigé : l'échappement est délégué à `jq`, et `spec_init` valide les identifiants
de service.

**L'engine pouvait sortir sans aucune ligne JSON.** Une variable non liée sous
`set -u` ne déclenche pas le trap `ERR`, seulement `EXIT` — l'engine mourait en
silence et le worker n'aurait rien eu à parser. Corrigé par un filet sur `EXIT` qui
n'émet que si rien n'a été émis, en préservant le code de sortie.

**La ligne JSON d'échec partait dans le fichier généré.** La redirection
`{ … } > compose.yml` détournait la sortie standard pendant toute la génération :
un échec en cours de route écrivait son JSON **dans le compose.yml** au lieu de
stdout. Corrigé par un descripteur dédié.

**Un `compose.yml` tronqué restait sur disque** quand la génération échouait à
mi-parcours. Corrigé par écriture atomique.

**La locale française cassait la conversion des unités.** `awk` produisait `0,200`
au lieu de `0.200`. Corrigé par `LC_ALL=C`.

---

## Points reportés

Aucun n'est bloquant. Ils seront triés à la revue finale du jalon.

| Point | Où |
|---|---|
| `die` accepte un code non numérique et sort alors en 255 | `lib/runtime.sh` |
| `cfg` et `spec_get` renvoient un blob JSON si la valeur est un objet ou un tableau | `lib/config.sh` |
| Aucun test ne couvre la pureté stdout des `ui_*` — seule la revue manuelle l'a vérifiée | `lib/ui.sh` |
| Le critère des deux squelettes Compose est « pas de `build` », pas « `internal` » | `lib/gen_compose.sh` |
| `install_error_trap` est posé après `config_init` : une erreur avant n'a pas de filet | `bootstrap.sh` |
| Une assertion de `test_runtime` survit à la mutation, elle est décorative | `tests/test_runtime.sh` |

---

## Deux pièges qui attendent les tâches suivantes

**`engine/lib/ssh_remote.sh` lit encore `OVH_AUTH_METHOD`, `OVH_SSH_KEY_PATH` et
`OVH_PASSWORD`.** Ces variables n'existent plus depuis le passage à `env.json`. Le
plan de la tâche 11 n'avait pas prévu de les convertir vers `cfg target.*`. La
panne serait **silencieuse** : repli sur le mode clé avec un chemin vide. À traiter
à la tâche 11.

**Le token de registre transitait par la ligne de commande SSH.** Visible dans `ps`
sur la machine cible pendant tout le provisioning, et cassé par un token contenant
une apostrophe. Le plan a été corrigé : utilisateur et token passent par stdin, en
deux lignes avant le corps du script. Les tâches 10 et 11 doivent implémenter cette
version-là.

---

## Ce qui n'a pas pu être vérifié

**Aucune cible SSH de test n'est disponible.** Le critère d'acceptation n°6 du
jalon 1 — `--all` déploie l'application de démonstration de bout en bout — ne sera
pas validé dans ce jalon. Ce qui sera vérifié à la place : `--all --dry-run`
traverse les seize étapes, et les générateurs produisent un `compose.yml` que
`docker compose config --quiet` accepte.

Cinq choses restent à exercer dès qu'une cible existe, dans cet ordre :
`validate_ssh`, `prepare_server` sur une Ubuntu vierge, `build_images` via
`DOCKER_HOST=ssh://`, `deploy_stack`, `validate_deployment`. Le point le plus
incertain est le troisième : `docker compose build` à travers `DOCKER_HOST=ssh://`
transfère le contexte de build par SSH, et ça n'a jamais été exercé ici.

**Docker Desktop doit tourner** pour que `test_gen_compose` exécute ses assertions
`docker compose config`. Le démon est actif au moment de cet instantané (serveur
29.5.3, Compose v5.1.4). S'il est éteint, la suite saute ces assertions et le dit —
elle ne bloque plus, mais le critère d'acceptation n°7 n'est alors pas exercé.

---

## Documents liés

- [ROADMAP.md](ROADMAP.md) — les 6 jalons
- [TEAM-SPLIT.md](TEAM-SPLIT.md) — répartition entre les trois rôles
- [ARCHITECTURE.md](ARCHITECTURE.md) — contrat engine, topologie, formats
- [SECURITY.md](SECURITY.md) — modèle de sécurité
- [CONVENTIONS.md](CONVENTIONS.md) — bash 3.2, tests, invariants
- `docs/superpowers/plans/2026-09-08-jalon-1-engine-docker.md` — le plan détaillé
