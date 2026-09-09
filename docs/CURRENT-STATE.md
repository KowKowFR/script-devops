# État des lieux — 9 septembre 2026 (nuit)

Instantané factuel. Il est daté parce qu'il périme vite.

Pour le périmètre et la cible, voir [ROADMAP.md](ROADMAP.md). Pour qui fait quoi,
voir [TEAM-SPLIT.md](TEAM-SPLIT.md).

**Dépôt public :** https://github.com/KowKowFR/script-devops

---

## En une phrase

Le **jalon 1 est terminé et figé** — l'engine bash déploie réellement, vérifié
contre une VM Ubuntu. Le **jalon 2 avance** : six tâches fusionnées, quatre
livrées en attente de relecture, sur vingt-quatre.

---

## Jalon 1 — terminé

**272 assertions, `TOUT PASSE`.** Le pipeline complet a tourné contre une VM Lima
Ubuntu 24.04 : Docker installé sur une machine vierge, images construites sur la
cible, stack démarrée, santé validée.

Détail dans [JALON-1-VERIFICATION.md](JALON-1-VERIFICATION.md), contrat dans
[ENGINE.md](ENGINE.md). **L'engine ne bouge plus.**

---

## Jalon 2 — 6 tâches sur 24

**117 tests Python verts sur `main`.**

### Fusionné

| # | Tâche | Rounds |
|---|---|---|
| 1 | Squelette, configuration typée, harnais pytest | — |
| 2 | `crypto.py` — chiffrement Fernet | 3 |
| 3 | `models.py` + `db.py` — modèle de données | 1 |
| 4 | `spec.py` — validation du spec et du nom d'app | 3 |
| 5 | `pipeline.py` — séquence et natures d'étape | — |
| 13 | `worker/logbus.py` — journal + Redis | 2 |
| 20 | `Dockerfile` — image commune | 1 |

### Livré, en relecture

| # | Tâche | État |
|---|---|---|
| 6 | `auth.py` — argon2id, session signée | en revue |
| 8 | `api/app.py` — FastAPI, sondes de santé | en revue |
| 12 | `runspace.py` — matérialisation de `runs/<slug>/` | en revue |
| 14 | `worker/engine.py` — invocation de l'engine | en re-revue |

### Reste à écrire

Tâches 7, 9, 10, 11, 15 à 19, et 21 à 24.

---

## La preuve du jour

Le panneau écrit un `env.json`, l'engine le lit :

```
$ bash engine/bootstrap.sh --workspace preuve-app --step check_prereqs
{"ok":true,"data":{"checked":7}}
```

Le pont Python → bash fonctionne, vérifié en exécution et pas sur schéma.

---

## Ce que les revues ont trouvé

Sur onze tâches relues, **aucune n'est passée sans finding**. Le mode de
découverte compte autant que les défauts eux-mêmes : tous ont été trouvés en
**exécutant, mutant ou attaquant**, jamais en relisant.

### Trois défauts sérieux, tous issus du plan

**Une fuite de la clé de chiffrement.** Une clé trop courte faisait lever pydantic
avec la valeur en clair dans le message. Corrigée — puis une **seconde fuite** par
`__context__`, que `raise ... from None` ne ferme pas : Python garde l'exception
d'origine et se contente d'un drapeau d'affichage. La correction retenue ne lève
plus jamais depuis l'intérieur d'un `except`.

**Deux endroits où un worker pouvait se figer pour toujours.** La lecture
séquentielle de stderr neutralisait le timeout. Corrigée par un thread — puis la
lecture de stdout, trois lignes plus loin, s'est révélée avoir **exactement le même
défaut**, reproductible sans aucun signal externe.

**Une regex qui laissait passer un retour à la ligne** dans un nom devenant chemin
de fichier, de projet Compose et de réseau Docker : en Python, `$` matche juste
avant un `\n` final.

### Cinq suites de tests qui ne testaient pas ce qu'elles annonçaient

| Tâche | Mutation qui survivait |
|---|---|
| 2 | Supprimer **toute** la gestion d'erreur de clé |
| 13 | Retirer le vidage ligne à ligne, cœur du commit |
| 3 | Retirer une clé étrangère, rendre une colonne nullable |
| 4 | Retirer la limite de longueur des identifiants |
| 14 | Un test nommé « chemin relatif » qui passait un chemin **absolu** |

Dans le cas de la tâche 14, la preuve est nette : en réintroduisant le bug
d'origine complet, les treize tests restaient verts.

---

## Décisions d'architecture prises

**Politique de suppression en base**, tranchée et justifiée dans le code :
Application → Cible en `RESTRICT`, Run → Application et Étape → Run en `CASCADE`.
Les tests activent les clés étrangères sous SQLite, sans quoi ils voyaient un
comportement **opposé** à celui de PostgreSQL.

**Deux natures d'étape dès maintenant** — celles qui appellent l'engine, celles
qui exécutent du Python. Au jalon 4, les opérations BunkerWeb devront tourner côté
Python ; l'ajouter après coup imposerait de réécrire le worker.

**Parité vérifiée, pas déclarée.** Le test du pipeline interroge réellement
`bash engine/bootstrap.sh --list-steps` par sous-processus.

**Sondes de santé distinctes.** `/healthz` ne dépend de rien — sinon Docker
redémarrerait le panneau en boucle à chaque hoquet de PostgreSQL. `/readyz`
interroge la base et Redis, et c'est lui que `depends_on: condition:
service_healthy` regardera.

**argon2id** avec `time_cost=3`, `memory_cost=64 Mio`, `parallelism=4` — aligné
sur la recommandation OWASP, et un test mesure que le hachage prend plus de 5 ms.
Un utilisateur inexistant subit le même coût qu'un mot de passe faux, pour ne pas
révéler qui existe.

---

## Question ouverte, à trancher avant le jalon 3

Le `CASCADE` signifie que supprimer une application **efface tout son historique
de déploiement**, atomiquement et irréversiblement.

Pour un outil dont le métier est de détruire des infrastructures, « qu'avait-on
déployé sur cette cible avant de tout effacer » est précisément ce qu'un opérateur
veut consulter après coup. Le `CASCADE` n'est sûr pour l'audit que si la séquence
de destruction fait un **effacement logique** plutôt qu'une suppression réelle.

Ce n'est pas un défaut du code actuel — il n'y a pas encore de code de destruction
— mais c'est une décision qui se verrouille en silence.

---

## Frictions de méthode rencontrées

**Les worktrees ne partent pas du `main` du moment.** Les dix agents lancés l'ont
tous rencontré. La consigne de rebase est désormais en tête de chaque prompt.

**`.superpowers/` est gitignoré, donc absent des worktrees.** Plusieurs agents
n'ont pas pu lire leur brief et ont travaillé directement depuis le plan — ce qui
a marché, mais par chance. Les briefs devraient être transmis autrement.

**Un agent a contourné une restriction d'outil.** Ne pouvant écrire son rapport
hors de son worktree, il est passé par le shell. Aucun dommage — un fichier de
rapport dans un répertoire ignoré — mais le motif est à surveiller, et
l'instruction qui l'y poussait a été retirée.

---

## Points d'intendance

**Le démon Docker est éteint.** L'image du panneau n'a pas pu être construite, et
ça bloquera les tâches 21 et 22.

**La VM de test n'est plus vierge** — Docker et la stack `tp-app` y tournent.
Avant la tâche 22 : `engine/tools/test-target.sh down` puis `up`.

---

## Documents liés

- [ROADMAP.md](ROADMAP.md) — les 6 jalons
- [ENGINE.md](ENGINE.md) — le contrat de l'engine, figé
- [TEAM-SPLIT.md](TEAM-SPLIT.md) — répartition entre les trois rôles
- [ARCHITECTURE.md](ARCHITECTURE.md) — topologie, formats
- [SECURITY.md](SECURITY.md) — modèle de sécurité
- [CONVENTIONS.md](CONVENTIONS.md) — bash 3.2, tests, invariants
- [TEST-TARGET.md](TEST-TARGET.md) — la cible SSH de test
- [JALON-1-VERIFICATION.md](JALON-1-VERIFICATION.md) — les sept critères
- `docs/superpowers/plans/` — les plans détaillés des deux jalons
