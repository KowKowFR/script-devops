# État des lieux — 9 septembre 2026 (soir)

Instantané factuel. Il est daté parce qu'il périme vite.

Pour le périmètre et la cible, voir [ROADMAP.md](ROADMAP.md). Pour qui fait quoi,
voir [TEAM-SPLIT.md](TEAM-SPLIT.md).

**Dépôt public :** https://github.com/KowKowFR/script-devops

---

## En une phrase

Le **jalon 1 est terminé et figé** : l'engine bash déploie réellement, vérifié
contre une VM Ubuntu. Le **jalon 2 est en cours** : le squelette du panneau
Python est sur `main`, sept tâches sont livrées et en cours de relecture dans des
branches séparées.

---

## Jalon 1 — terminé

255 assertions, `TOUT PASSE`. Le pipeline complet a tourné contre une VM Lima
Ubuntu 24.04 : Docker installé sur une machine vierge, images construites sur la
cible, stack démarrée, santé validée.

```
$ bash engine/bootstrap.sh --workspace testvm --step validate_deployment
{"ok":true,"data":{"services_ok":2}}
```

Le détail est dans [JALON-1-VERIFICATION.md](JALON-1-VERIFICATION.md), le contrat
dans [ENGINE.md](ENGINE.md). **L'engine ne bouge plus** : le jalon 2 s'y branche
sans le modifier.

---

## Jalon 2 — en cours

**Sur `main` :** la tâche 1 seulement (squelette `panel/`, configuration typée,
harnais pytest, suppression de l'ancienne interface Flask).

**En attente de fusion :** sept tâches livrées, dans des branches séparées.

| # | Tâche | Revue | État |
|---|---|---|---|
| 2 | `crypto.py` — chiffrement Fernet | ✅ spec, **Critical** | corrigée, à re-relire |
| 3 | `models.py` + `db.py` | ✅ spec, intégrité non protégée | corrigée, en re-revue |
| 4 | `spec.py` — validation | ❌ messages en anglais | correction en cours |
| 5 | `pipeline.py` | ✅ approuvée | **prête à fusionner** |
| 13 | `worker/logbus.py` | ✅ spec, 2 mutations survivaient | correction en cours |
| 14 | `worker/engine.py` | en revue | |
| 20 | `Dockerfile` | ✅ approuvée | correction mineure en cours |

Restent à écrire : les tâches 6 à 12, 15 à 19, et 21 à 24.

---

## Ce que la vérification par mutation a révélé

C'est le fait marquant de cette vague, et il vaut d'être retenu.

**Quatre tâches sur sept avaient des tests qui ne testaient pas ce qu'ils
annonçaient.** Toutes auraient été jugées bien couvertes à la lecture.

| Tâche | Mutation qui survivait |
|---|---|
| 2 | Supprimer **toute** la gestion d'erreur de clé — 6/6 verts |
| 13 | Retirer le vidage ligne à ligne, cœur du commit — 6/6 verts |
| 3 | Retirer une clé étrangère, rendre une colonne nullable — 6/6 verts |
| 4 | Retirer la limite de longueur des identifiants — 56/56 verts |

Dans le cas de la tâche 2, ce trou n'est pas anodin : c'est exactement la branche
qui portait la fuite Critical décrite plus bas.

---

## Les trois défauts sérieux trouvés

**Une fuite de la clé de chiffrement (Critical).** Dans `panel/crypto.py`, la
lecture de la configuration était hors du bloc protégé. Une clé trop courte —
typo, copier-coller tronqué — faisait lever pydantic, avec un message contenant
**la valeur reçue en clair** :

```
ValidationError: String should have at least 32 characters
  [input_value='short-prod-key-123', ...]
```

Tout gestionnaire d'erreurs qui journalise cette exception écrivait la clé de
chiffrement du panneau dans les logs. Corrigé, et `Settings.secret_key` est
désormais masquée dans toutes ses représentations.

**Un timeout neutralisé.** Le code que le plan proposait pour lire la sortie de
l'engine bloquait indéfiniment sur une étape partie en boucle : la lecture ne
rendait jamais la main, donc le timeout ne se déclenchait jamais. Un run bloqué
le serait resté pour toujours. Remplacé par une lecture dans un thread séparé.

**Une regex qui laissait passer un retour à la ligne.** En Python, `$` matche
juste avant un `\n` final : `re.match(r"^[a-z][a-z0-9-]{1,30}$", "mon-app\n")`
réussit. Ce nom devient nom de répertoire, de projet Compose et de réseau Docker.
Corrigé en `re.fullmatch`.

**Les trois avaient leur origine dans le plan, pas dans l'implémentation.**

---

## Deux choses trouvées en exécutant plutôt qu'en lisant

**Un bug de chemin, révélé par une preuve « bonus ».** La tâche 14 devait
invoquer une doublure de l'engine. On lui a demandé, si c'était faisable,
d'invoquer aussi le **vrai** binaire. Ça a révélé une erreur de répertoire de
travail que la doublure masquait.

**Une panne Redis qui ralentit au lieu d'échouer.** Testé avec un vrai client sur
un port fermé : chaque publication bloque 3 à 4 secondes malgré le timeout
configuré, `redis-py` appliquant sa propre politique de retry. Lors d'une panne,
le flux de logs ne s'arrêterait pas — il défilerait au ralenti, et un run de mille
lignes prendrait une heure. À traiter par la tâche qui construira le client.

---

## Décisions d'architecture prises en chemin

**Politique de suppression en base**, tranchée et justifiée dans le code :

| Relation | Politique | Pourquoi |
|---|---|---|
| Application → Cible | RESTRICT | une cible utilisée ne disparaît pas en silence |
| Run → Application | CASCADE | un historique sans son application n'a pas de sens |
| Étape → Run | CASCADE | une étape n'existe pas hors de son run |

Les tests activent désormais les clés étrangères sous SQLite : sans ça, ils
voyaient un comportement opposé à celui de PostgreSQL et ne prouvaient rien.

**Deux natures d'étape dès maintenant.** Le modèle distingue les étapes qui
appellent l'engine de celles qui exécutent du Python. Au jalon 4, les opérations
BunkerWeb devront tourner côté Python — le contrat interdit à une étape de
l'engine de connaître le panneau. L'ajouter après coup imposerait de réécrire le
worker.

**Parité vérifiée, pas déclarée.** Le test du pipeline interroge réellement
`bash engine/bootstrap.sh --list-steps` par sous-processus. Une étape déclarée
d'un seul côté est détectée dans les deux sens.

---

## Points d'intendance

**Le démon Docker est éteint.** Sans conséquence pour ce qui tourne, mais l'image
du panneau n'a pas pu être construite, et ça bloquera la tâche 21 (`compose.yml`)
et surtout la tâche 22 (test d'intégration réel).

**La VM de test n'est plus vierge** — Docker et la stack `tp-app` y tournent
depuis la validation du jalon 1. Avant la tâche 22 :
`engine/tools/test-target.sh down` puis `up`.

**L'environnement Python n'est pas installé sur `main`.** Chaque worktree a créé
le sien. À la première fusion, il faudra un `pip install -e '.[dev]'` à la racine
pour que `pytest` tourne sans détour.

**Les worktrees isolés ne partent pas du `main` du moment.** Les sept agents de
la vague l'ont rencontré et ont dû se rebaser. C'est consigné pour être annoncé
dès le prompt aux vagues suivantes.

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
