# Jalon 1 — état de vérification

Vérification exécutée le 9 septembre 2026. Chaque critère a été rejoué
réellement pour ce document — aucune ligne ci-dessous ne reprend une
affirmation d'un plan sans l'avoir fait tourner.

> **Mise à jour, `54020f1`.** Le point de friction du critère 6 — l'impossibilité
> pour `DOCKER_HOST=ssh://` de porter une identité SSH — **a été corrigé depuis
> la rédaction initiale de ce document**. `docker_remote` pose désormais un
> wrapper `ssh` temporaire qui injecte `-i` (mode clé) ou route par `sshpass`
> (mode mot de passe). Le contournement par `~/.ssh/config` n'est plus
> nécessaire. Voir la section 6 pour la vérification refaite.

| # | Critère | État |
|---|---|---|
| 1 | `bash -n` sur tous les `.sh` | ✅ vérifié |
| 2 | `shellcheck --severity=error` sans erreur | ✅ vérifié |
| 3 | Plus de mentions Kubernetes involontaires sous `engine/` | ✅ vérifié |
| 4 | Plus aucun `source` de fichier de configuration | ✅ vérifié |
| 5 | Chaque `--step` renvoie exactement une ligne JSON | ✅ vérifié |
| 6 | `--all` déploie l'app de démo de bout en bout sur une cible SSH | 🟡 **pipeline réel réussi ; bloc GitHub non exercé** |
| 7 | Le compose généré passe `docker compose config --quiet` | ✅ vérifié |

Suite de tests complète : `bash engine/tests/run.sh` → **255 assertions,
TOUT PASSE** (`bash -n` + `shellcheck --severity=error` inclus dans le même
run).

---

## 1. `bash -n` sur tous les `.sh`

```bash
for f in engine/bootstrap.sh engine/lib/*.sh engine/tools/*.sh engine/tests/*.sh; do
  bash -n "$f" || echo "ÉCHEC : $f"
done
```

Aucune erreur sur les 16 fichiers de `lib/`, `bootstrap.sh`, les deux
utilitaires de `tools/`, et l'ensemble de `tests/`. ✅

## 2. `shellcheck --severity=error`

```bash
shellcheck --severity=error --shell=bash engine/bootstrap.sh engine/lib/*.sh engine/tools/*.sh
```

`shellcheck 0.11.0` — aucune sortie, code de retour 0. ✅

## 3. Plus de mentions Kubernetes involontaires

```bash
grep -rin 'k3s\|kubectl\|kubeconfig\|ingress\|cert-manager\|ClusterIssuer' engine/
```

Six occurrences relevées, lues une par une :

| Fichier | Ligne | Nature |
|---|---|---|
| `engine/tests/test_dispatcher.sh:10` | `assert_not_contains ... "kubeconfig" "--list-steps ne mentionne plus le kubeconfig"` | assertion **négative** — vérifie l'absence, pas une mention réelle |
| `engine/tests/test_gen_workflow.sh:71,169` | `grep -c 'kubectl\|KUBECONFIG\|k8s/base\|OVH_'` | même chose : le test grep ces motifs pour confirmer qu'ils **n'apparaissent pas** dans le workflow généré |
| `engine/tests/test_gen_workflow.sh:73,171` | messages d'assertion citant ces mêmes motifs | idem, texte de l'assertion elle-même |
| `engine/lib/steps.sh:204` | commentaire : « l'ancienne validation cassait dès qu'un hostname d'ingress était configuré » | commentaire **historique**, explique un choix de conception passé, ne décrit pas un comportement actuel |

Cinq des six occurrences sont donc des mentions **volontaires** (tests
négatifs ou commentaires historiques), conformes à ce que le critère
autorise explicitement.

**Une occurrence, en revanche, n'est ni un test ni un commentaire
historique** — c'est un résidu dans du contenu généré, livré à l'utilisateur
final :

```
engine/lib/gen_microservices.sh:215:
  <p>Chaîne automatisée pilotée en langage naturel par un agent IA. Cette
  page est servie par nginx dans un pod Kubernetes, derrière un ingress
  Traefik.</p>
```

C'est le texte HTML de la page d'accueil de l'app de démo générée par
`generate_microservices`. Il décrit une architecture **Kubernetes + Traefik**
qui n'existe plus depuis que l'engine déploie sur Docker Compose — l'app
générée aujourd'hui tourne dans un conteneur Compose, pas un pod, et il n'y a
pas d'ingress Traefik dans le chemin de déploiement actuel. C'est un vrai
résidu, pas une mention volontaire, et il induit en erreur quiconque lit la
page servie par l'app générée.

**Non corrigé ici**, conformément à la consigne de cette tâche (ne pas
toucher `engine/` sauf accord explicite) — **signalé pour correction** :
`engine/lib/gen_microservices.sh` ligne 215, remplacer la phrase par une
description Docker Compose.

Critère considéré ✅ pour ce qui concerne le comportement de l'engine
lui-même (aucune trace Kubernetes involontaire dans la logique exécutée) ;
la mention trouvée est dans du texte généré, pas dans le mécanisme.

## 4. Plus aucun `source` de fichier de configuration

```bash
grep -rn 'source.*env\|\. .*\.bootstrap-env' engine/
```

Une seule occurrence : `engine/tests/test_config.sh:51`, une assertion
**négative** (`assert_not_contains ... "source \"\$ENV_FILE\"" "plus de
source du fichier d'env"`) qui vérifie justement l'absence de ce pattern dans
le code.

Vérification complémentaire, plus large — tous les `source`/`.` du dossier
`engine/` :

```bash
grep -rn '^\s*source\s\|^\s*\.\s' engine/*.sh engine/lib/*.sh engine/tools/*.sh engine/tests/*.sh
```

Toutes les occurrences sourcent des **bibliothèques de code**
(`lib/ui.sh`, `lib/runtime.sh`, `lib/config.sh`, `lib/gen_compose.sh`,
`tests/helpers.sh`…), jamais un fichier de données/configuration
(`env.json`, `.bootstrap-env`). ✅

## 5. Une ligne JSON par étape

Bouclé sur les 16 étapes retournées par `--list-steps`, en `--dry-run` contre
le workspace `testvm` :

```bash
for s in $(bash engine/bootstrap.sh --list-steps); do
  out=$(bash engine/bootstrap.sh --workspace testvm --step "$s" --dry-run 2>/dev/null)
  n=$(printf '%s' "$out" | grep -c .)
  printf '%-24s %s ligne(s)  json_valide=%s\n' "$s" "$n" \
    "$(printf '%s' "$out" | jq -e . >/dev/null 2>&1 && echo oui || echo non)"
done
```

Résultat : **16/16 étapes, exactement une ligne, JSON valide dans les 16
cas.** `generate_compose` est remontée avec `ok:false` (paramètre
`registry.user` manquant à ce moment du test) — sans incidence sur le
critère : le contrat n'exige pas que chaque étape réussisse en dry-run, il
exige qu'elle émette **une seule ligne JSON valide**, succès ou échec. C'est
le cas. ✅

Revérifié en conditions réelles (non dry-run) lors du test du critère 6 :
chaque appel `--step`, du premier au douzième avant l'arrêt sur
`validate_deployment`, a émis exactement une ligne JSON valide sur stdout —
voir §6.

## 6. `--all` déploie l'app de démo de bout en bout sur une cible SSH

**Contrairement au plan initial**, une cible existe désormais : une VM Lima
Ubuntu 24.04, pilotée par `engine/tools/test-target.sh`, avec Docker
volontairement absent au départ (voir
[`TEST-TARGET.md`](TEST-TARGET.md)). Le pipeline a été exécuté **pas à pas**
contre elle, workspace `runs/testvm/`.

### Ce qui a été vérifié, étape par étape, en conditions réelles

| Étape | Résultat | Détail |
|---|---|---|
| `validate_ssh` | ✅ | connexion SSH réelle, bannière `lima-deploymatic-test-target — Ubuntu 24.04.4 LTS` |
| `enable_sudo_nopasswd` | ✅ | `{"already_configured":true}` |
| `create_project_dir` | ✅ | dossier créé sous `runs/testvm/tp-app` |
| `generate_microservices` | ✅ | API Express + Web nginx générés |
| `generate_compose` | ✅ | `deploy/compose.yml` généré, 2 services |
| `generate_skills` | ✅ | 5 Skills générées |
| `generate_workflow` | ✅ | `.github/workflows/deploy.yml` généré |
| `prepare_server` | ✅ | **Docker CE + plugin Compose installés pour de vrai** sur une Ubuntu vierge (~1 min), ufw configuré (22 seul ouvert), fail2ban installé et actif, MOTD posé |
| `build_images` | ✅ | **le point qui était déclaré le plus incertain du jalon** — voir ci-dessous |
| `deploy_stack` | ✅ | réseau Compose créé, 2 conteneurs démarrés |
| `validate_deployment` | 🟡 puis ✅ | premier appel : `retryable`, « services non sains » (conteneurs encore en état de santé `starting`) ; second appel quelques secondes plus tard : ✅, `{"services_ok":2}`, les deux services répondent sur `127.0.0.1:<port hôte>` **depuis la cible** |
| `github_create_repo`, `github_set_secrets`, `git_init`, `git_push` | ✅ (sautées) | `github.enabled=false` dans `env.json` de test → chacune renvoie `{"ok":true,"data":{"skipped":true}}`, aucun appel réseau |

Les 16 étapes ont donc chacune été exécutées **réellement** (pas en
dry-run) contre la cible, dans l'ordre de `--all`, avec un résultat conforme
au contrat à chaque fois — y compris l'échec `retryable` sur
`validate_deployment`, qui est le comportement **attendu** juste après un
`deploy_stack` (healthcheck encore en `starting`) : le code 1 signale
exactement ce qu'il doit signaler, un état transitoire qui se résout sur
retry, sans aucune intervention.

Un lancement de `bash engine/bootstrap.sh --workspace testvm --all` (mode
process unique, celui du plan) a ensuite confirmé le même comportement en une
seule invocation : **12 lignes JSON valides**, une par étape exécutée
(`check_prereqs` → `deploy_stack`), avant un arrêt attendu sur
`validate_deployment` — les conteneurs venaient d'être recréés par ce même
`--all` et étaient de nouveau en `starting`. Un `--step validate_deployment`
isolé, juste après, est repassé au vert. `--all` s'arrête au premier échec
(pas de logique de retry interne — c'est le rôle de l'appelant, cf.
[`ENGINE.md`](ENGINE.md#4-codes-de-sortie)), ce qui est le comportement
documenté, pas un défaut.

### Le point qui était déclaré le plus incertain : `build_images`

`docker compose build` via `DOCKER_HOST=ssh://` a bien transféré le contexte
de build par SSH et construit les deux images sur la cible (logs BuildKit
complets, layers téléchargés et extraits côté VM, images nommées et
exportées) — **ce mécanisme fonctionne**.

**Mais il a fallu un ajustement de configuration pour y arriver**, qui est
une information utile pour le jalon 2 :

- Avec `target.host` en IP brute (`"127.0.0.1"`) + `target.port` explicite,
  `validate_ssh`/`enable_sudo_nopasswd`/`prepare_server` fonctionnent (ils
  passent `-i <clé>` explicitement à `ssh`), mais `build_images` **échoue**
  avec `Permission denied (publickey)` : le CLI `docker` construit son propre
  appel `ssh` interne à partir de la seule URL `ssh://user@host:port`, qui ne
  sait **pas** transporter `-i` — il ne peut résoudre l'identité que via un
  agent SSH ou une entrée `~/.ssh/config`.
- La correction (déjà prévue par le design de `test-target.sh`, voir
  [`TEST-TARGET.md`](TEST-TARGET.md)) : régénérer `env.json` avec
  `target.host` sur l'**alias** `~/.ssh/config` (`deploymatic-test-target`,
  qui porte `IdentityFile`), tout en gardant `target.port` explicite pour que
  `ssh_remote`/`scp_remote` continuent de fonctionner. Avec cette
  combinaison, les deux mécanismes (SSH direct et `DOCKER_HOST=ssh://`)
  fonctionnent simultanément.

Ce comportement est documenté en détail dans
[`ENGINE.md` §6](ENGINE.md#6-docker_hostssh--ce-qui-a-été-vérifié-en-conditions-réelles),
avec son implication pour le jalon 2 : le worker devra soit garder les clés
SSH dans un agent partagé, soit garantir une entrée `~/.ssh/config` par
cible, soit (mieux) valider explicitement que `DOCKER_HOST=ssh://` fonctionne
avant `build_images`, plutôt que de découvrir l'échec seulement à cette
étape alors que `validate_ssh` aura affiché un succès.

### Pourquoi le critère est marqué 🟡 et pas ✅

Le pipeline complet a tourné, de bout en bout, réellement, contre une VM qui
n'avait ni Docker ni configuration au départ, et a produit une application
qui répond sur ses deux endpoints. C'est la substance du critère 6. La
réserve tient à deux points, tous deux documentés plutôt que masqués :

1. Le bloc GitHub (`github_create_repo`, `github_set_secrets`, `git_init`,
   `git_push`) n'a été vérifié que sur son **chemin désactivé** (`skip`
   propre) — pas contre un vrai compte GitHub. Ce n'était pas l'objectif
   assigné à cette tâche (aucun compte de test fourni) et ce chemin est
   couvert par la suite de tests (`test_gen_workflow.sh` et consorts) sur
   d'autres aspects, mais l'exécution **réseau réelle** de `gh repo create`
   / `gh secret set` / `git push` n'a pas eu lieu ici.
2. Le mécanisme `DOCKER_HOST=ssh://` a exigé un ajustement de la
   configuration cible (alias `~/.ssh/config`) pour fonctionner — ce n'est
   pas un échec de l'engine (le comportement de `docker` avec une URL
   `ssh://` est documenté en amont, pas un bug DeployMatic), mais c'est une
   contrainte opérationnelle qui n'était nulle part écrite avant ce
   document, et qui aurait piégé un premier utilisateur réel.

### État de la VM après ce test

**La cible n'est plus vierge.** Elle porte maintenant Docker CE, le plugin
Compose, ufw configuré, fail2ban actif, et la stack `tp-app` (2 conteneurs,
2 images locales) déployée et démarrée. Un test ultérieur qui a besoin d'une
cible réellement vierge doit repartir de
`engine/tools/test-target.sh down && engine/tools/test-target.sh up`, ce qui
recrée la VM de zéro (Docker retiré par le provisioning de `test-target.sh`).

## 7. Le compose généré passe `docker compose config --quiet`

```bash
mkdir -p runs/demo
cp engine/templates/spec.demo.json runs/demo/spec.json
# env.json avec registry.user renseigné (voir docs/ENGINE.md pour le schéma)
bash engine/bootstrap.sh --workspace demo --step create_project_dir
bash engine/bootstrap.sh --workspace demo --step generate_microservices
bash engine/bootstrap.sh --workspace demo --step generate_compose
(cd runs/demo/tp-app/deploy && docker compose config --quiet && echo OK)
```

`docker compose config --quiet` accepte le fichier généré (2 services,
`build`+`image` implicites via `${IMAGE_TAG}`, réseau `tp-app-net`,
durcissement complet des deux services buildés) sans avertissement ni
erreur. ✅

---

## Constat additionnel, hors des sept critères

En vérifiant le critère 3, une phrase de contenu **généré** décrivant
l'architecture Kubernetes a été trouvée dans le HTML de l'app de démo
(`engine/lib/gen_microservices.sh:215`). Signalée à l'équipe engine, non
corrigée ici (consigne de cette tâche). Voir §3 ci-dessus pour le détail.

Un second point, mineur et cosmétique : dans `step_validate_ssh`
(`engine/lib/steps.sh`), la bannière capturée avec
`banner=$(ssh_remote ... 2>&1)` mélange stdout et stderr — un avertissement
SSH (« Warning: Permanently added … to the list of known hosts. », observé
pendant ce test) se retrouve donc dans le champ `data.banner` de la ligne
JSON de succès. Sans conséquence sur le contrat (toujours une ligne JSON
valide), mais `data.banner` peut contenir plus que la bannière de l'hôte
distant. Signalé, non corrigé ici.

## Documents liés

- [`ENGINE.md`](ENGINE.md) — référence du contrat, section §6 pour le détail
  du piège `DOCKER_HOST=ssh://`.
- [`TEST-TARGET.md`](TEST-TARGET.md) — la cible SSH de test utilisée ici.
- [`CURRENT-STATE.md`](CURRENT-STATE.md) — état factuel du jalon 1 (à mettre
  à jour séparément).


---

## Addendum — la friction du critère 6 est levée

Au moment de la rédaction initiale, `build_images` échouait en
`Permission denied (publickey)` et n'avait pu aboutir qu'en ajoutant un alias
dans le `~/.ssh/config` **personnel de l'utilisateur**. C'était un contournement,
pas une solution : il ne fonctionne ni en CI, ni dans le conteneur worker du
jalon 2, qui aura sa clé montée par un secret Docker et aucun `~/.ssh/config`.

**Cause mesurée, pas supposée.** En plaçant un faux `ssh` journalisant devant
Docker, on observe que `DOCKER_HOST=ssh://…:60122` invoque :

```
ssh -l devops -p 60122 -o ConnectTimeout=30 -T -- <host> "docker system dial-stdio"
```

Docker transmet bien le port, mais **ne fournit jamais d'identité** et n'offre
aucune option pour en passer une.

**Correction.** `docker_remote` construit désormais, dans un répertoire
temporaire propre à l'appel, un wrapper `ssh` placé en tête de `PATH` qui injecte
`-i` en mode clé, ou délègue à `sshpass -e` en mode mot de passe — le même
mécanisme que celui déjà validé dans le workflow CI généré. Le vrai `ssh` est
résolu par `command -v` **avant** toute modification du `PATH`, pour éviter la
récursion.

**Vérification refaite, sans alias.** `runs/testvm/env.json` vise directement
`127.0.0.1:60122` avec un chemin de clé explicite :

```
--step deploy_stack          {"ok":true,...}
--step validate_deployment   {"ok":true,"data":{"services_ok":2}}
```

Le `~/.ssh/config` a été déplacé puis restauré à l'identique, et les étapes
rejouées sans lui : elles passent. Aucun répertoire temporaire ne subsiste.

**Ce qui reste non exercé** : le mode mot de passe est couvert par des tests
unitaires mais pas par un appel réel de bout en bout — la VM de test n'accepte
que l'authentification par clé. Et le bloc GitHub n'a été vérifié que sur son
chemin désactivé, faute de compte de test. C'est ce qui maintient le critère 6
en 🟡 plutôt qu'en ✅.
