# État des lieux — 9 septembre 2026

Instantané factuel. Il est daté parce qu'il périme vite.

Pour le périmètre et la cible, voir [ROADMAP.md](ROADMAP.md). Pour qui fait quoi,
voir [TEAM-SPLIT.md](TEAM-SPLIT.md).

**Jalon 1 : TERMINÉ.** 15 tâches sur 15, 255 assertions vertes.
Le pipeline complet a été exécuté contre une vraie machine Ubuntu.
**Dépôt public :** https://github.com/KowKowFR/script-devops

---

## En une phrase

L'engine bash a quitté Kubernetes pour Docker Compose et **déploie réellement** :
il a installé Docker sur une Ubuntu vierge, construit les images sur la cible,
démarré la stack et validé sa santé. Le jalon 1 est terminé ; le plan du jalon 2
est écrit et le panneau Python reste à construire.

## La preuve qui compte

```
$ bash engine/bootstrap.sh --workspace testvm --step validate_deployment
{"ok":true,"data":{"services_ok":2}}

$ ssh <cible> 'docker ps'
tp-app-api-1    Up (healthy)
tp-app-web-1    Up (healthy)
```

Contre une VM Lima Ubuntu 24.04, en SSH sur le port 60122, sans aucune entrée
dans le `~/.ssh/config` de la machine hôte.

---

## La suite de tests

```
test_config          42 ok
test_gen_compose     68 ok
test_runtime         18 ok
test_units           15 ok
test_dispatcher      13 ok
test_ssh_remote      12 ok
test_gen_micro        9 ok
test_smoke            4 ok
────────────────────────────
                    181 assertions — TOUT PASSE
```

Plus, à chaque exécution : `bash -n` sur tous les scripts et
`shellcheck --severity=error`.

**Aucune assertion rouge.** C'est nouveau : la 13ᵉ assertion de `test_dispatcher`
a passé tout le jalon au rouge, par construction — elle exécutait réellement une
étape, or les étapes étaient encore en version Kubernetes. Elle est verte depuis
la tâche 11.

Lancer : `bash engine/tests/run.sh`, ou `bash engine/tests/run.sh test_config`
pour une seule suite. Voir [CONVENTIONS.md](CONVENTIONS.md).

---

## Jalon 1, tâche par tâche

| # | Tâche | État | Rounds de correction |
|---|---|---|---|
| 1 | Réorganisation `engine/` + harnais de test | ✅ fusionnée | — |
| 2 | `lib/units.sh` — conversion des unités | ✅ fusionnée | — |
| 3 | `lib/runtime.sh` — contrat de sortie | ✅ fusionnée | — |
| 4 | `lib/config.sh` — configuration JSON | ✅ fusionnée | — |
| 5 | `lib/ui.sh` — stderr, suppression des prompts | ✅ fusionnée | 2 |
| 6 | Dispatcher `--step` | ✅ fusionnée | 3 |
| 7 | `spec.json` + helpers | ✅ fusionnée | 2 |
| 8 | `lib/gen_compose.sh` | ✅ fusionnée | 2 |
| 9 | `gen_microservices.sh` — nginx non privilégié | ✅ fusionnée | — |
| 10 | `prepare_server.sh` — provisioning Docker | ✅ fusionnée | — |
| 11 | `lib/steps.sh` — étapes réécrites | 🟡 livrée, complément en cours | — |
| 12 | Bloc GitHub optionnel + workflow | ⬜ bloquée par la 11 | |
| 13 | `lib/diag.sh` — diagnostic Docker | ✅ fusionnée | — |
| 14 | `gen_skills.sh` — Skills Docker | ✅ fusionnée | — |
| 15 | Documentation + critères d'acceptation | ⬜ à faire en dernier | |
| — | **Cible SSH de test** (hors plan initial) | ✅ fusionnée | — |

**13 tâches sur 15 terminées.** La 11 est livrée et fonctionnelle ; on lui a
ajouté en cours de route le support d'un port SSH non standard.

---

## Une cible SSH de test existe maintenant

C'est l'ajout le plus important hors plan. Une VM Lima Ubuntu 24.04 avec systemd,
pilotable en une commande :

```bash
engine/tools/test-target.sh up      # ~90 s au premier lancement, 11 s ensuite
engine/tools/test-target.sh status
engine/tools/test-target.sh env     # produit un env.json prêt à l'emploi
engine/tools/test-target.sh down
```

Utilisateur `devops`, clé SSH dédiée, `sudo NOPASSWD` fonctionnel sans TTY, et
**Docker volontairement absent** — sans ça, `prepare_server.sh` n'aurait aucun
travail à faire et on ne testerait rien. Voir [TEST-TARGET.md](TEST-TARGET.md).

Elle a déjà servi : en visant la VM, on a confirmé en conditions réelles deux
lacunes de l'engine et découvert une troisième (l'absence de support d'un port
SSH non standard — Lima expose la VM sur `127.0.0.1:60122`, le port 22 exigeant
root).

---

## Ce qui marche aujourd'hui

| Capacité | État |
|---|---|
| Exécuter une étape nommée (`--step`) | ✅ 16 étapes |
| Configuration et spécification en JSON | ✅ plus aucun `source` |
| Générer `deploy/compose.yml` depuis un spec | ✅ durci, échappement délégué à `jq` |
| Générer les sources de l'app de démo | ✅ nginx non privilégié, `services/` |
| Générer les 5 Skills Claude Code | ✅ `docker-deploy`, rollback par `IMAGE_TAG` |
| Provisionner une cible en Docker | ✅ écrit, jamais exécuté sur une vraie cible |
| Piloter Docker à distance | ✅ `DOCKER_HOST=ssh://`, socket jamais monté |
| Diagnostiquer une stack | ✅ `cmd_doctor`, `cmd_logs`, `cmd_stack_info` |
| Cible SSH de test reproductible | ✅ Lima, une commande |

## Ce qui ne marche pas encore

| Capacité | Bloqué par |
|---|---|
| Workflow CI/CD cohérent | tâche 12 — voir l'incohérence ci-dessous |
| Interface web | jalon 2 — `web/` est cassé et sera supprimé |
| Multi-application, allocation de ports | jalon 3 |
| Exposition derrière BunkerWeb | jalon 4 |

---

## Une incohérence à corriger avant de générer quoi que ce soit

`engine/lib/gen_workflow.sh` **n'a pas encore été migré** : il produit un CI
100 % Kubernetes — `kubectl set image`, `KUBECONFIG`, secrets `OVH_*`, et une
copie de `k8s/base/` qui n'existe plus.

Conséquence concrète : un projet généré aujourd'hui aurait des **Skills qui
décrivent un mécanisme de déploiement différent de ce que son CI exécute
réellement**. Les Skills parlent de réécrire `IMAGE_TAG` dans `deploy/.env` avec
des secrets `TARGET_*` ; le workflow, lui, ferait un `kubectl set image` vers un
cluster qui n'existe pas.

C'est la tâche 12. Deux Skills (`microservice-editor`, `github-flow`) pointent
aussi encore vers `microservices/api/server.js`, chemin disparu depuis la
tâche 9 — une Skill qui envoie l'agent vers un fichier inexistant ne sert à rien.

---

## Ce qui est cassé volontairement

**`web/`** — l'interface Flask ne fonctionne plus depuis que `bootstrap.sh` a
déménagé sous `engine/`. Elle est supprimée au jalon 2 et remplacée par le
panneau FastAPI. Ne la réparez pas.

C'est désormais la seule chose volontairement cassée. `engine/lib/steps.sh` et la
13ᵉ assertion de `test_dispatcher`, qui l'étaient pendant tout le jalon, ont été
réglées par la tâche 11.

---

## Ce que les revues ont trouvé

Chaque tâche a été relue par un agent distinct, chargé d'attaquer le code plutôt
que de le lire. Ce qu'ils ont trouvé et qui n'était pas dans le plan :

**Une injection YAML dans le générateur de Compose.** `jq --arg` empêche
l'exécution de commandes shell, mais pas la corruption de structure YAML. Un
volume valant `normal:/data\n    privileged: true` faisait apparaître
`privileged: true` comme clé de service — et Compose l'acceptait. Les trois
« interdits absolus » du projet étaient contournables par le contenu d'un
`spec.json`. Grave parce qu'au jalon 5 ces specs seront produits par un LLM.
Corrigé, puis revérifié contre **19 vecteurs d'attaque** : tags YAML, ancres,
alias, séparateurs de document, caractères de contrôle, UTF-8 multi-octets.

**L'engine pouvait sortir sans aucune ligne JSON.** Une variable non liée sous
`set -u` ne déclenche pas le trap `ERR`, seulement `EXIT` : l'engine mourait en
silence et le worker n'aurait rien eu à parser.

**La ligne JSON d'échec partait dans le fichier généré.** La redirection
`{ … } > compose.yml` détournait la sortie standard : un échec en cours de route
écrivait son JSON dans le `compose.yml`.

**Une garde anti-doublon à la mauvaise échelle.** Posée par process au lieu de
par étape, elle avalait la ligne JSON de toute étape échouant après une étape
réussie, en mode `--all`.

**Un défaut qui ne s'appliquait pas quand un service est absent du spec.**
`spec_get web port 8080` renvoyait vide au lieu de 8080.

**Un diagnostic qui aurait menti.** Sous `DRY_RUN=1`, `cmd_doctor` aurait annoncé
« démon Docker joignable » et « compose.yml valide » sans rien vérifier. Le
court-circuit dry-run a été rendu sélectif : seules les commandes qui modifient
l'état sont neutralisées, pas celles qui lisent.

**La locale française cassait la conversion des unités.** `awk` produisait
`0,200` au lieu de `0.200`.

---

## Points reportés

Aucun n'est bloquant. Ils seront triés à la revue finale du jalon.

| Point | Où |
|---|---|
| `die` accepte un code non numérique et sort alors en 255 | `lib/runtime.sh` |
| `cfg` et `spec_get` renvoient un blob JSON si la valeur est un objet | `lib/config.sh` |
| `id: null` ou `id` absent contourne la validation d'identifiant | `lib/config.sh` |
| Aucun test ne couvre la pureté stdout des `ui_*` | `lib/ui.sh` |
| Pas de test sur l'échec du renommage de `.env.example` | `lib/gen_compose.sh` |
| Trois assertions survivent à la mutation qu'elles prétendent couvrir | `tests/` |
| Le critère des deux squelettes Compose est « pas de `build` », pas « `internal` » | `lib/gen_compose.sh` |
| Le contenu des volumes n'est pas contrôlé (`docker.sock` explicite passerait) | `lib/gen_compose.sh` → jalon 5 |

---

## Ce qui n'a pas encore été exercé

La cible SSH existe, mais **le pipeline complet n'a pas encore tourné contre
elle**. Ce qui reste à exercer, dans cet ordre :

1. `validate_ssh` — en cours de vérification
2. `prepare_server` sur une Ubuntu vierge — installe réellement Docker
3. `build_images` via `DOCKER_HOST=ssh://` — **le point le plus incertain** : le
   contexte de build transite par SSH, ça n'a jamais été exercé
4. `deploy_stack`
5. `validate_deployment`

Le critère d'acceptation n°6 du jalon 1 (déploiement de bout en bout) devient
atteignable maintenant qu'une cible existe, alors qu'il était déclaré non
vérifiable au début.

---

## Méthode, et ce qu'elle a coûté

Chaque tâche suit le même cycle : un implémenteur, puis un relecteur indépendant
chargé d'attaquer plutôt que de lire, puis des rounds de correction jusqu'à ce
que les findings soient traités ou explicitement arbitrés.

Quatre tâches ont demandé des corrections (2, 3, 2 et 3 rounds). Les autres sont
passées du premier coup. **Les tests écrits sont vérifiés par mutation** : on
sabote le correctif et on confirme que les assertions passent au rouge. Trois
assertions ont été démasquées ainsi — elles passaient aussi bien sur le code
correct que sur le code bugué.

Une leçon méthodologique payée en conflit de fusion : les worktrees parallèles
doivent être créés depuis le `main` du moment, pas depuis une base figée. La
tâche 14 avait une copie périmée de `gen_microservices.sh`, ce qui a produit un
conflit à résoudre à la main.

---

## Documents liés

- [ROADMAP.md](ROADMAP.md) — les 6 jalons
- [TEAM-SPLIT.md](TEAM-SPLIT.md) — répartition entre les trois rôles
- [ARCHITECTURE.md](ARCHITECTURE.md) — contrat engine, topologie, formats
- [SECURITY.md](SECURITY.md) — modèle de sécurité
- [CONVENTIONS.md](CONVENTIONS.md) — bash 3.2, tests, invariants
- [TEST-TARGET.md](TEST-TARGET.md) — la cible SSH de test
- `docs/superpowers/plans/` — les plans d'exécution détaillés
