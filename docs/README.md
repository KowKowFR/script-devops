# Documentation de DeployMatic

DeployMatic est un **panneau de déploiement web** : on s'y connecte, on décrit une
application, elle est générée, buildée, déployée sur un hôte cible joint en SSH, exposée
derrière un reverse proxy BunkerWeb, et scannée pour les vulnérabilités.

Le projet est en pleine transformation. Il vient d'un script bash local qui déployait une
application unique sur Kubernetes (k3s) ; il devient une stack conteneurisée
multi-applications où **Python orchestre et bash exécute**. La transformation est découpée
en six jalons, décrits dans [`ROADMAP.md`](ROADMAP.md).

---

## Par où commencer

| Ce que vous cherchez | Document |
|---|---|
| **Le périmètre** : ce que font les six jalons, et leurs critères d'acceptation | [`ROADMAP.md`](ROADMAP.md) |
| **Comment ça marche** : le contrat de l'engine, la topologie réseau, `spec.json`, `env.json`, le rollback par `IMAGE_TAG` | [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| **Où en est le projet** : le jalon 1 tâche par tâche, ce qui est cassé exprès, ce qui n'a pas pu être vérifié | [`CURRENT-STATE.md`](CURRENT-STATE.md) |
| **Comment contribuer** : bash 3.2, l'invariant stdout/stderr, ajouter une étape, lancer les tests | [`CONVENTIONS.md`](CONVENTIONS.md) |
| **Ce qui est protégé, et ce qui ne l'est pas encore** : injection, durcissement, secrets, auth, IA, scanners | [`SECURITY.md`](SECURITY.md) |
| **Qui fait quoi** : la répartition entre trois rôles, les dépendances, ce qui se parallélise | [`TEAM-SPLIT.md`](TEAM-SPLIT.md) |
| **Le plan d'exécution détaillé du jalon 1** (15 tâches) | [`superpowers/plans/2026-09-08-jalon-1-engine-docker.md`](superpowers/plans/2026-09-08-jalon-1-engine-docker.md) |
| **Le journal d'exécution du jalon 1** : arbitrages, points reportés, revues | `.superpowers/sdd/2026-09-08-jalon-1-engine-docker/progress.md` |

Deux documents sont **à venir** : `ENGINE.md` (référence du contrat de l'engine, étape par
étape) et `JALON-1-VERIFICATION.md` (l'état de vérification des sept critères
d'acceptation). Les deux sont produits par la tâche 15 du jalon 1.

### Trois parcours de lecture

- **Vous arrivez sur le projet** : ce fichier, puis [`CURRENT-STATE.md`](CURRENT-STATE.md),
  puis [`ARCHITECTURE.md`](ARCHITECTURE.md).
- **Vous allez écrire du code** : [`CONVENTIONS.md`](CONVENTIONS.md) puis la section de
  [`TEAM-SPLIT.md`](TEAM-SPLIT.md) qui correspond à votre rôle.
- **Vous devez arbitrer ou planifier** : [`ROADMAP.md`](ROADMAP.md) puis
  [`TEAM-SPLIT.md`](TEAM-SPLIT.md).

---

## Où en est le projet — 2026-09-08

**Le jalon 1 est en cours : 7 tâches terminées sur 15.**

Ce qui est fait et testé : la réorganisation sous `engine/`, le harnais de test maison, la
conversion des unités Kubernetes → Docker, le contrat de sortie (`emit_ok`/`emit_fail`,
logs sur stderr, codes 0/1/2), la configuration en JSON lue par `jq` — qui ferme la faille
d'injection de l'ancien `.bootstrap-env` —, le dispatcher `--step` / `--all` /
`--list-steps` / `--dry-run`, et les helpers de lecture de `spec.json`.

Ce qui n'existe pas encore : le générateur de `compose.yml`, la réécriture des étapes de
déploiement, le provisioning Docker du serveur, et **la totalité des jalons 2 à 6** — il
n'y a aucune ligne de Python dans le dépôt à ce jour.

**Rien n'est déployable en l'état** : `engine/lib/steps.sh` contient toujours les étapes
Kubernetes de l'ancien système, en attendant sa réécriture complète à la tâche 11.

Le détail, tâche par tâche, avec les points reportés et leur justification, est dans
[`CURRENT-STATE.md`](CURRENT-STATE.md).

---

## ⚠️ Le `README.md` à la racine est périmé

Le [`README.md`](../README.md) de la racine décrit **l'ancien système** : les dix-huit
étapes du pipeline k3s, `.bootstrap-env`, les manifests Kubernetes, l'ingress avec
cert-manager, l'interface Flask de `web/`. Il est détaillé et convaincant, et il ne décrit
plus ce que le dépôt contient.

- Ne l'utilisez pas comme référence. Il est utile pour **comprendre d'où vient le projet**,
  et pour rien d'autre.
- L'interface `web/` qu'il documente est **volontairement cassée** depuis le déplacement
  des scripts sous `engine/` ; elle sera supprimée au jalon 2.
- Il sera **réécrit à la tâche 15 du jalon 1**.

En attendant, [`ARCHITECTURE.md`](ARCHITECTURE.md) fait référence.

---

## Repères rapides

```bash
bash engine/tests/run.sh                                  # toute la suite de tests
bash engine/bootstrap.sh --list-steps                     # les étapes connues
bash engine/bootstrap.sh --workspace demo --step check_prereqs
bash engine/tools/migrate-env.sh .bootstrap-env runs/demo/env.json
```

Le shell interactif de la machine de développement est `zsh` : toujours invoquer les
scripts par `bash`, jamais en collant un fragment dans le terminal
(voir [`CONVENTIONS.md`](CONVENTIONS.md) §5).
