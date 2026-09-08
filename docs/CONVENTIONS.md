# Conventions de développement

Ce qu'il faut respecter pour que le code entre dans ce dépôt sans casser les contrats
décrits dans [`ARCHITECTURE.md`](ARCHITECTURE.md). Ces règles ne sont pas des préférences
de style : chacune répond à un problème rencontré, et plusieurs d'entre elles sont
vérifiées automatiquement par `engine/tests/run.sh`.

---

## 1. Compatibilité bash 3.2 — obligatoire

Le `/bin/bash` de macOS est en version **3.2** (Apple ne le met pas à jour pour des
raisons de licence). Le développement se fait sur macOS, l'exécution en production sur
Linux avec un bash 5. Le plus petit dénominateur commun est donc 3.2, et il faut s'y
tenir : un script qui n'utilise du bash 4 qu'à une seule ligne échoue à cette ligne, en
production comme en local, avec un message rarement explicite.

### Constructions interdites

| Interdit | Version requise | À utiliser à la place |
|---|---|---|
| `declare -A tab` (tableau associatif) | bash 4.0 | tableau indexé + boucle, ou une requête `jq` |
| `${var,,}` (minuscules) | bash 4.0 | `tr '[:upper:]' '[:lower:]'` |
| `${var^^}` (majuscules) | bash 4.0 | `tr '[:lower:]' '[:upper:]'` |
| `mapfile` / `readarray` | bash 4.0 | `while IFS= read -r line; do … done < <(…)` |
| `**` en glob récursif | bash 4.0 (+ `globstar`) | `find` |

### Autorisé et utilisé

Tableaux indexés (`STEPS=( … )`), indirection `${!var}`, `printf -v`, `[[ … =~ … ]]` avec
`BASH_REMATCH`, substitution de processus `< <(…)`.

**Comment le vérifier** : `bash -n` ne détecte pas tout — `declare -A` passe la vérification
syntaxique en 3.2 et échoue à l'exécution. Le plus sûr reste de tester sur le bash du
système : `/bin/bash --version` doit afficher 3.2 sur macOS, et c'est bien ce bash-là que
`engine/tests/run.sh` invoque.

---

## 2. L'invariant stdout / stderr

> **stdout est sacré.** Une étape écrit **exactement une** ligne JSON sur stdout, en fin
> d'exécution. Tout le reste — logs, avertissements, sortie des commandes tierces — part
> sur **stderr**.

C'est l'invariant le plus facile à casser et le plus coûteux à déboguer : le worker du
jalon 2 parse stdout, et un `echo "Terminé"` égaré transforme un run réussi en erreur de
parsing JSON.

### Ce que ça implique quand on écrit une étape

1. **Tous les helpers `ui_*` écrivent déjà sur stderr** (`ui_step`, `ui_info`, `ui_ok`,
   `ui_warn`, `ui_err`, `ui_skip`). Les utiliser plutôt que `echo`. Un `echo` nu dans une
   étape est un bug, sans exception.
2. **Rediriger la sortie des commandes tierces.** Un `docker compose up -d` bavarde sur
   stdout ; il faut écrire `compose_remote up -d >&2`. La règle vaut pour `ssh`, `git`,
   `curl`, `docker`, `gh` — tout.
3. **Terminer par exactement un `emit_ok` / `emit_fail`.** `emit_ok` prend un objet JSON
   optionnel ; s'il n'est pas du JSON valide, il est remplacé par `null` plutôt que de
   corrompre la ligne.
4. **Ne jamais appeler `exit 0` après un `emit_ok`** sans réfléchir : `emit_ok` n'appelle
   volontairement pas `exit`, c'est l'étape qui décide.
5. **Capturer la sortie d'un helper qui imprime** se fait par `$(…)` — donc un helper de
   calcul (`k8s_cpu_to_docker`, `cfg`, `spec_get`) imprime bien sur **stdout**, mais son
   appelant capture toujours cette sortie. Ces helpers ne sont pas des étapes.

Les deux filets posés par `install_error_trap` (`trap ERR` + `trap EXIT`) garantissent
qu'une ligne JSON sort **même** en cas de panne inattendue. Ils ne dispensent pas d'écrire
le `emit_ok` : ils rattrapent, ils ne remplacent pas.

---

## 3. La convention « step pure »

Une fonction `step_<nom>` est *pure* au sens de ce projet quand elle satisfait toutes ces
conditions :

- elle **lit** ses paramètres dans `env.json` / `spec.json` via `cfg*` et `spec_*`, et
  nulle part ailleurs ;
- elle **ne demande rien** à un humain : aucun prompt, aucun TTY supposé — le worker n'en
  a pas ;
- elle **n'installe rien** et ne répare rien à chaud : un outil manquant est une erreur de
  build d'image, pas quelque chose à corriger en cours de run ;
- elle **fait exactement ce que son nom dit**, et rien d'autre ;
- elle **se termine** par un `emit_ok`, ou meurt par `die` (code 2) / `retryable` (code 1) ;
- elle **ignore l'existence** du panel, de la base de données et de l'étape suivante.

Deux étapes de l'ancien système violaient cette convention et c'est ce qui a motivé la
règle : `check_prereqs` installait `gum` quand il manquait, et `collect_credentials`
était un formulaire interactif. La première est devenue non interactive (elle constate et
échoue) ; la seconde a disparu, remplacée par `env.json`.

> Le terme « step pure » vient de la feuille de route, qui l'emploie sans le définir. La
> définition ci-dessus est la lecture opératoire retenue, dérivée des contraintes globales
> du plan du jalon 1 ; si elle doit être arbitrée, `docs/ENGINE.md` (à venir, tâche 15)
> est l'endroit où le faire.

### Choisir entre `die` et `retryable`

| Situation | Fonction | Code |
|---|---|---|
| `spec.json` invalide, port hors plage, workspace au nom refusé, outil absent | `die` | 2 |
| SSH injoignable, `docker compose up` en échec, service pas encore sain | `retryable` | 1 |
| Commande qui échoue sans qu'on l'ait prévu (via `trap ERR`) | automatique | 1 |

La question à se poser : *est-ce que refaire exactement la même chose dans trente secondes
a une chance de marcher ?* Si oui, `retryable`.

---

## 4. Ajouter une étape

1. Écrire `step_<nom>()` dans `engine/lib/steps.sh`, en respectant le §3.
2. Ajouter `<nom>` au tableau `STEPS` de `engine/bootstrap.sh`, **à sa place dans
   l'ordre** — c'est l'ordre de `--all`.
3. Ajouter le même nom à la séquence côté panel (`panel/pipeline.py`, à partir du jalon 2).
   La séquence de référence est celle du panel ; `STEPS` sert au test de l'engine seul.
   **Les deux doivent rester alignées** — c'est le point de contact le plus fragile entre
   les rôles Engine et Panel.
4. Ajouter les assertions correspondantes dans `engine/tests/`.

Le dispatcher refuse une étape absente de `STEPS` (« étape inconnue », code 2) **et** une
étape listée dans `STEPS` mais dont la fonction n'existe pas (« étape déclarée mais non
implémentée », code 2). Les deux cas produisent quand même une ligne JSON.

---

## 5. Lancer les tests

```bash
bash engine/tests/run.sh              # toute la suite
bash engine/tests/run.sh test_config  # un fichier, filtré par motif
```

**Le shell interactif de la machine de développement est `zsh`.** Les scripts de test sont
du bash et utilisent des constructions que zsh interprète différemment (`[[ =~ ]]`,
`BASH_REMATCH`, la substitution de processus). Il faut donc toujours passer par bash
explicitement : `bash engine/tests/run.sh`, ou `bash -c '…'` quand la commande est plus
longue. Un `./engine/tests/run.sh` fonctionne aussi grâce au shebang, mais un copier-coller
de fragment dans le terminal, non.

`run.sh` fait trois choses, dans cet ordre :

1. exécute chaque `engine/tests/test_*.sh` ;
2. passe `bash -n` sur `bootstrap.sh`, `lib/*.sh` et `tools/*.sh` ;
3. passe `shellcheck --severity=error` sur les mêmes fichiers, **s'il est installé** —
   sinon la vérification est sautée avec un message, et la suite passe quand même. Ne pas
   confondre « aucune erreur shellcheck » et « shellcheck absent ».

Le code de sortie est 0 seulement si tout passe.

---

## 6. Le harnais de test

`engine/tests/helpers.sh` est un micro-harnais maison, **sans aucune dépendance externe** :
pas de bats, pas de shunit2. Un fichier de test le source, appelle des assertions, et
termine par `finish`.

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

out=$(bash "$ENGINE_DIR/bootstrap.sh" --list-steps 2>/dev/null)
assert_contains "$out" "deploy_stack" "--list-steps mentionne deploy_stack"

finish
```

### Assertions disponibles

| Assertion | Signature | Note |
|---|---|---|
| `assert_eq` | `ATTENDU OBTENU MESSAGE` | comparaison de chaînes exacte |
| `assert_contains` | `TEXTE MOTIF MESSAGE` | sous-chaîne littérale (`grep -qF`) |
| `assert_not_contains` | `TEXTE MOTIF MESSAGE` | l'inverse |
| `assert_exit_code` | `ATTENDU MESSAGE -- cmd args…` | le `--` est optionnel mais lisible |
| `assert_valid_json` | `TEXTE MESSAGE` | passe le texte à `jq -e .` |
| `finish` | — | imprime le récapitulatif, renvoie 0 si aucun échec |

Trois variables sont exportées par le harnais et utilisables dans les tests :
`TESTS_DIR`, `ENGINE_DIR`, `REPO_ROOT`.

### Fixtures

- `engine/tests/fixtures/env.min.json` — un `env.json` complet et **volontairement
  piégeux** : un token contenant des guillemets, et une entrée `ports.trop_bas` à 80 pour
  vérifier que `cfg_port` la refuse.
- `engine/tests/fixtures/spec.multi.json` — trois services : `api` (buildé, exposé sur
  `/api/`), `web` (buildé, exposé sur `/`), `db` (image tierce, `internal: true`, avec un
  volume nommé).

Écrire les tests **avant** l'implémentation, et les observer échouer pour la bonne raison
avant de les rendre verts : c'est le mode de travail suivi tout au long du jalon 1, et les
rapports de tâche en gardent la trace.

---

## 7. shellcheck

Le seuil est `--severity=error`. Les diagnostics `warning` et `info` ne bloquent pas, mais
ils se regardent : la plupart des vrais bugs shell qu'ils signalent (mot non quoté,
`$?` lu trop tard, `read` sans `-r`) ont déjà mordu ce projet.

```bash
shellcheck --severity=error --shell=bash engine/bootstrap.sh engine/lib/*.sh
```

Quand un module en source un autre, ajouter la directive au-dessus du `source` pour que
shellcheck suive :

```bash
# shellcheck source=lib/runtime.sh
source "$SCRIPT_DIR/lib/runtime.sh"
```

---

## 8. Le piège de la locale — `LC_ALL=C`

Rencontré pour de vrai pendant le jalon 1, tâche 2, et corrigé après reproduction :

```bash
# Sous une locale fr_FR :
awk -v m=200 'BEGIN { printf "%.3f", m / 1000 }'   # → 0,200   ← virgule décimale
```

`0,200` est un nombre parfaitement valide en français et parfaitement invalide dans un
`cpus:` de Docker Compose. Le bug ne se manifeste que sur les machines dont la locale est
française — donc jamais en CI, et toujours sur le poste de la personne qui développe.

**Règle : toute commande qui produit ou parse un nombre, une date ou un tri doit être
préfixée de `LC_ALL=C`.** En pratique, cela vise `awk`, `sort`, `printf` sur des flottants,
`date`. C'est ce que fait `engine/lib/units.sh`.

```bash
out=$(LC_ALL=C awk -v m="$milli" 'BEGIN { printf "%.3f", m / 1000 }')
```

Le coût d'un `LC_ALL=C` défensif est nul ; le coût de son absence est une heure de
débogage sur une machine et zéro sur les autres.

---

## 9. `jq` : toujours `--arg`, jamais l'interpolation

Toute valeur dynamique injectée dans un programme `jq` passe par `--arg` (chaîne) ou
`--argjson` (JSON) :

```bash
# Correct
jq -r --arg s "$sid" '.ports[$s] // empty' "$ENV_JSON"

# Interdit — le contenu de $sid devient du programme jq
jq -r ".ports[\"$sid\"] // empty" "$ENV_JSON"
```

C'est la même classe de problème que l'injection SQL, et c'est ce qui rend la lecture de
configuration sûre. Voir [`SECURITY.md`](SECURITY.md) §1.

Corollaire de génération : dans un heredoc **non** quoté, `${IMAGE_TAG}` serait mangé par
bash. Il faut l'échapper (`\${IMAGE_TAG}`) pour qu'il arrive littéral dans le YAML et soit
interpolé par Compose. Quand aucune interpolation bash n'est souhaitée, quoter le
délimiteur (`<<'EOF'`) est plus sûr que d'échapper au cas par cas.

---

## 10. Français dans le code, anglais dans les commits

- **Commentaires, messages `ui_*`, messages d'erreur `die`/`retryable` : en français.**
  C'est la langue du code existant et de l'équipe ; mélanger les deux rend les messages
  d'erreur illisibles.
- **Messages de commit : conventionnels**, avec un scope :
  `feat(engine):`, `fix(engine):`, `refactor(engine):`, `docs(plan):`, `chore:`, `style:`.
  L'historique du jalon 1 les écrit en anglais après le préfixe ; rester cohérent avec
  `git log`.
- **Commits atomiques.** Un commit = un changement cohérent, idéalement un fichier ou un
  petit groupe de fichiers liés. Les quinze tâches du jalon 1 produisent chacune un à
  quatre commits, jamais un gros.

---

## 11. Deux règles absolues, en rappel

1. **Plus jamais de `source` sur un fichier de configuration.** La vérification tient en
   une commande, et elle doit ne rien renvoyer :
   ```bash
   grep -rn 'source.*env\|\. .*\.bootstrap-env' engine/
   ```
2. **Aucun prompt interactif dans `engine/`.** Toute décision qui était un `ui_confirm`
   devient une clé d'`env.json` ou un échec code 2.

---

## 12. Documents liés

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — les contrats que ces conventions protègent.
- [`SECURITY.md`](SECURITY.md) — pourquoi le JSON et pourquoi le non-interactif.
- [`CURRENT-STATE.md`](CURRENT-STATE.md) — l'état de la suite de tests.
