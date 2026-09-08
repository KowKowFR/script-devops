# Jalon 2 — Panel minimal : FastAPI, worker RQ, stack Docker

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `docker compose up -d` sur une machine vierge donne une URL authentifiée depuis laquelle on déclare une cible, une application, et on la déploie en voyant les logs défiler en direct.

**Architecture:** Un service `panel` (FastAPI, Jinja2, gunicorn) sert l'UI et l'API, écrit en base (PostgreSQL, SQLModel) et met un run en file dans Redis ; un service `worker` (RQ) dépile le run, matérialise `runs/<slug>/spec.json` et `env.json` en 600, puis appelle `engine/bootstrap.sh --workspace <slug> --step <nom>` une étape à la fois, en streamant stderr vers un fichier de log **et** vers Redis pub/sub — c'est ce que le SSE de l'UI consomme. Le panneau n'exécute jamais de subprocess et le worker ne sert jamais de HTTP : les deux tournent depuis la même image, avec deux commandes différentes.

**Tech Stack:** Python 3.11+, FastAPI, SQLModel (SQLAlchemy 2), Pydantic v2, RQ, Redis 8, PostgreSQL 16, argon2-cffi, cryptography (Fernet), Jinja2, gunicorn + `uvicorn.workers.UvicornWorker`, pytest. **Aucun framework JavaScript.**

## Global Constraints

- **Rien ne dépasse du contrat de l'engine.** Le panneau invoque `engine/bootstrap.sh --workspace <ws> --step <nom>`, lit **une** ligne JSON sur stdout, traite stderr comme du log, et interprète les codes `0` / `1` / `2`. Il ne source jamais un fichier de l'engine, n'importe jamais une fonction bash, ne lit jamais un fichier produit par une étape autrement que par le `data` de sa ligne JSON.
- **`--all` n'est jamais appelé par le panneau.** C'est un mode de test de l'engine seul, qui viole volontairement « une ligne JSON par process ».
- **Le worker ne monte jamais `/var/run/docker.sock`.** Docker se pilote par `DOCKER_HOST=ssh://`, y compris pour l'hôte local, qui est une cible comme une autre.
- **Le nom d'application est contraint par `^[a-z][a-z0-9-]{1,30}$`**, validé côté API avant toute écriture. Il devient nom de workspace, nom de répertoire, nom de projet Compose et nom de réseau Docker. Aucun chemin n'est jamais construit par concaténation d'une chaîne non validée.
- **Aucun secret en clair dans Postgres.** Chiffrement Fernet, clé lue depuis `PANEL_SECRET_KEY`. Les secrets ne sont déchiffrés que dans le processus **worker**, au moment d'écrire `runs/<slug>/env.json`.
- **Toute mutation exige un token CSRF et un en-tête `Origin` reconnu.** Cookie de session `HttpOnly` / `SameSite=Strict` / `Secure`. Rate limiting sur `/login` : 5 tentatives par 5 minutes et par IP.
- **`panel` et `worker` tournent en UID non-root**, avec `no-new-privileges`, et le port du panneau est publié sur `127.0.0.1` **uniquement**.
- **Tests `pytest`, et vérification par mutation obligatoire** sur les tests de sécurité (authentification, CSRF, validation de nom) et sur la réconciliation : on sabote le correctif, on confirme que l'assertion passe au rouge, on restaure. Un test qui survit à la mutation qu'il prétend couvrir ne prouve rien — le jalon 1 en a démasqué trois.
- **Commentaires et docstrings en français**, messages d'erreur en français, commits conventionnels et atomiques.
- **Hors périmètre :** allocation de ports (jalon 3), destruction d'application (jalon 3), BunkerWeb (jalon 4), IA (jalon 5), scanners (jalon 6), multi-utilisateur avec rôles (hors périmètre définitif). Les ports hôtes viennent de la main de l'humain, comme au jalon 1.

---

## Les cinq décisions tranchées

### D1 — `Step` porte une **nature** : `engine` ou `python`

`StepKind = Literal["engine", "python"]`. Une étape `engine` est un appel à `bootstrap.sh` ; une étape `python` est un appelable enregistré dans `panel/worker/steps_py.py`, qui reçoit le même contexte et rend le même `StepResult`.

**Pourquoi maintenant.** Au jalon 4, `register_bunkerweb` / `unregister_bunkerweb` / `validate_public` doivent parler à l'API BunkerWeb via `panel/bunkerweb.py`. Le contrat interdit à une étape de l'engine de connaître le panneau ; le client BunkerWeb, lui, vit côté panneau et n'a rien à faire en bash. Ces étapes seront donc du Python. Si le worker ne sait faire qu'un `subprocess.run`, l'ajout au jalon 4 impose de réécrire la boucle d'exécution, la table `Step`, le SSE et les tests — c'est-à-dire tout le jalon 2. Le coût de l'anticiper est d'un champ en base et d'une branche `if kind ==` dans le runner.

**Preuve que ce n'est pas du code mort :** la première étape du pipeline, `prepare_workspace`, **est** une étape Python dès ce jalon. Elle matérialise `runs/<slug>/` (D3) et apparaît dans l'UI comme les autres. Le mécanisme est donc exercé par tous les runs, pas seulement par un test.

### D2 — L'idempotence est dans la table `Step`, jamais dans un fichier

Au lancement d'un run, pour chaque étape du pipeline, le runner cherche la **dernière** ligne `Step` de statut `ok` pour cette **application** (tous runs confondus). Si elle existe et que l'étape n'est pas marquée `always_rerun`, l'étape est écrite en `skipped` sans être exécutée.

**Toujours rejouées** (`always_rerun=True`) — les générateurs et les vérifications, dont le coût est nul et dont le résultat dépend du spec courant :

`prepare_workspace`, `check_prereqs`, `validate_ssh`, `generate_microservices`, `generate_compose`, `generate_skills`, `generate_workflow`, `build_images`, `deploy_stack`, `validate_deployment`.

**Sautées si déjà `ok`** — ce qui modifie durablement l'état de la cible ou du dépôt :

`create_project_dir`, `enable_sudo_nopasswd`, `prepare_server`, `github_create_repo`, `github_set_secrets`, `git_init`, `git_push`.

La liste est déclarée **à un seul endroit** : la constante `PIPELINE` de `panel/pipeline.py`, sur le champ `always_rerun` de chaque `StepDef`. Il n'existe pas de seconde liste ailleurs, et un test vérifie que la somme des deux ensembles est exactement le pipeline. `state_has` / `state_mark` sur fichier ont disparu au jalon 1 et ne reviennent pas.

### D3 — Secrets : Fernet, clé `PANEL_SECRET_KEY`, déchiffrés dans le worker seulement

**Chiffré** (colonne `*_enc`, texte Fernet) : le mot de passe SSH d'une cible, le token Docker Hub, le token GitHub — et au jalon 4 le mot de passe de l'API BunkerWeb, au jalon 5 la clé API du LLM. Ils entrent par l'API, sont chiffrés avant le premier `INSERT`, et ne ressortent **jamais** d'un endpoint : les schémas de sortie ne les portent pas.

**Non chiffré** : les identifiants d'hôte, l'utilisateur SSH, le port, le chemin de la clé SSH (un chemin n'est pas un secret ; la clé elle-même est un secret Docker monté dans le worker), le `spec.json`, les variables d'environnement applicatives non sensibles, les statuts et les logs.

**Moment du déchiffrement** : uniquement dans l'étape Python `prepare_workspace`, qui tourne dans le processus **worker**, au moment de sérialiser `runs/<slug>/env.json` (mode 600, répertoire 700). Le processus `panel` ne déchiffre jamais rien — il n'a même pas besoin de la clé pour servir l'UI, mais il la reçoit quand même pour chiffrer les entrées. `env.json` est **supprimé en fin de run** (`finally`), de sorte que le volume partagé ne conserve pas de secret entre deux runs.

Critère d'acceptation n°7 (« aucun secret en clair dans `SELECT * FROM app` ») : vérifié par un test qui lit la ligne brute via SQLAlchemy Core et cherche la valeur en clair.

### D4 — Réconciliation au démarrage, dans `panel/worker/reconcile.py`

`reconcile_stale_runs(session, connection) -> list[int]` : tout `Run` en statut `running` dont le `rq_job_id` n'existe plus dans Redis (`rq.job.Job.exists`) est passé en `failed`, avec `error = "run interrompu : le job RQ <id> n'existe plus (redémarrage du worker ?)"`, ainsi que ses `Step` en `running`. Un `Run` en `queued` dont le job n'existe plus est traité pareil.

**Où ça tourne, deux fois :**
1. au démarrage du processus `panel`, dans le `lifespan` de FastAPI (`panel/api/app.py`) ;
2. au démarrage du processus `worker`, dans `panel/worker/main.py`, **avant** `Worker.work()`.

Les deux appels sont volontaires : redémarrer seulement le worker ne redémarre pas le panneau, et inversement. La fonction est idempotente et sûre en concurrence (`UPDATE … WHERE status = 'running'`, la seconde exécution ne trouve plus rien). C'est ce qui remplace le couple `Popen` détaché + fichier PID de l'ancien `web/`, dont le défaut était qu'un redémarrage laissait des runs bloqués pour toujours.

### D5 — Le nom d'application est l'unique source du chemin

`AppName = Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9-]{1,30}$")]`, dans `panel/spec.py`. Il est validé par Pydantic **avant** toute écriture en base, contraint unique en base, et **revalidé** dans `panel/runspace.py` juste avant de construire un chemin (défense en profondeur : le jour où un chemin est construit depuis une ligne de base plutôt que depuis une requête, la garde tient encore).

`app.name == app.slug == nom de workspace == nom de répertoire == nom de projet Compose == nom de réseau Docker`. Un seul identifiant, aucune traduction, aucune table de correspondance à désynchroniser. C'est le correctif définitif du point n°4 de la dette technique (`--workspace ../../foo`).

La regex du panneau est un **sous-ensemble strict** de celle que `engine/bootstrap.sh` applique déjà (`^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$`) : aucun nom accepté par le panneau ne peut être refusé par l'engine, et l'engine reste une seconde barrière indépendante. Un test le vérifie par génération d'exemples.

---

## Structure de fichiers cible

```
bootstrap-tp/
├── compose.yml                  [NOUVEAU] stack du panneau : panel, worker, postgres, redis
├── Dockerfile                   [NOUVEAU] image commune panel/worker (UID 10001)
├── pyproject.toml               [NOUVEAU] dépendances + configuration pytest
├── .env.example                 [NOUVEAU] variables attendues, sans valeur secrète
├── engine/                      INCHANGÉ — lu, jamais modifié par ce jalon
├── panel/
│   ├── __init__.py
│   ├── settings.py              [NOUVEAU] configuration typée, lue de l'environnement
│   ├── db.py                    [NOUVEAU] moteur SQLModel, session, create_all
│   ├── crypto.py                [NOUVEAU] Fernet : encrypt / decrypt / clé
│   ├── models.py                [NOUVEAU] User, Target, App, Run, Step + enums
│   ├── spec.py                  [NOUVEAU] AppName, ServiceSpec, AppSpec (Pydantic)
│   ├── pipeline.py              [NOUVEAU] StepDef, PIPELINE — la séquence, en constante
│   ├── auth.py                  [NOUVEAU] argon2, session signée HMAC, compte admin
│   ├── security.py              [NOUVEAU] dépendances FastAPI : session, CSRF, Origin, rate limit
│   ├── runspace.py              [NOUVEAU] runs/<slug>/ : env.json + spec.json en 600
│   ├── api/
│   │   ├── __init__.py
│   │   ├── app.py               [NOUVEAU] création de l'app FastAPI, lifespan, /healthz, /readyz
│   │   ├── schemas.py           [NOUVEAU] entrées/sorties Pydantic de l'API
│   │   ├── routes_auth.py       [NOUVEAU] POST /login, POST /logout
│   │   ├── routes_targets.py    [NOUVEAU] GET/POST/DELETE /targets
│   │   ├── routes_apps.py       [NOUVEAU] GET/POST /apps, POST /apps/{id}/deploy
│   │   ├── routes_runs.py       [NOUVEAU] GET /runs/{id}, GET /runs/{id}/events (SSE)
│   │   └── routes_ui.py         [NOUVEAU] les trois écrans rendus par Jinja2
│   ├── templates/               [NOUVEAU] base.html, login.html, targets.html, apps.html, run.html
│   ├── static/                  [NOUVEAU] app.css, run.js (JS vanilla, pas de framework)
│   └── worker/
│       ├── __init__.py
│       ├── main.py              [NOUVEAU] entrée `rq worker` + réconciliation au démarrage
│       ├── queue.py             [NOUVEAU] connexion Redis et file RQ
│       ├── logbus.py            [NOUVEAU] fichier de log + publication Redis, nettoyage ANSI
│       ├── engine.py            [NOUVEAU] invocation d'UNE étape de l'engine
│       ├── steps_py.py          [NOUVEAU] registre des étapes de nature `python`
│       ├── runner.py            [NOUVEAU] le job RQ : un job = un run
│       └── reconcile.py         [NOUVEAU] runs orphelins → failed
├── tests/
│   ├── conftest.py              [NOUVEAU] base SQLite éphémère, client HTTP, faux Redis
│   ├── test_crypto.py           test_models.py       test_spec.py
│   ├── test_pipeline.py         test_auth.py         test_security.py
│   ├── test_api_targets.py      test_api_apps.py     test_api_runs.py
│   ├── test_runspace.py         test_engine_call.py  test_logbus.py
│   ├── test_runner.py           test_reconcile.py
│   └── fixtures/fake_engine.sh  [NOUVEAU] faux engine scriptable : codes 0/1/2, stdout/stderr
├── runs/                        volume partagé panel ↔ worker (gitignoré, 700)
├── docs/
│   ├── PANEL.md                 [NOUVEAU] exploitation : variables, secrets, mise derrière BunkerWeb
│   └── JALON-2-VERIFICATION.md  [NOUVEAU] état de vérification des 8 critères
└── web/                         [SUPPRIMÉ] Flask, templates, static, start.sh, venv
```

## Pipeline (constante `PIPELINE`, `panel/pipeline.py`)

| # | Étape | Nature | Rejouée ? | Note |
|---|---|---|---|---|
| 0 | `prepare_workspace` | python | toujours | écrit `spec.json` + `env.json` en 600 |
| 1 | `check_prereqs` | engine | toujours | |
| 2 | `validate_ssh` | engine | toujours | |
| 3 | `create_project_dir` | engine | si `ok` → `skipped` | |
| 4 | `generate_microservices` | engine | toujours | générateur |
| 5 | `generate_compose` | engine | toujours | générateur |
| 6 | `generate_skills` | engine | toujours | générateur |
| 7 | `generate_workflow` | engine | toujours | générateur |
| 8 | `enable_sudo_nopasswd` | engine | si `ok` → `skipped` | état de la cible |
| 9 | `prepare_server` | engine | si `ok` → `skipped` | état de la cible |
| 10 | `build_images` | engine | toujours | |
| 11 | `deploy_stack` | engine | toujours | |
| 12 | `validate_deployment` | engine | toujours | |
| 13 | `github_create_repo` | engine | si `ok` → `skipped` | `requires_flag="github.enabled"` |
| 14 | `github_set_secrets` | engine | si `ok` → `skipped` | `requires_flag="github.enabled"` |
| 15 | `git_init` | engine | si `ok` → `skipped` | `requires_flag="github.enabled"` |
| 16 | `git_push` | engine | si `ok` → `skipped` | `requires_flag="github.enabled"` |

**Pourquoi `requires_flag` existe.** `bash engine/bootstrap.sh --list-steps` liste bien les quatre étapes `github_*`, mais `engine/lib/steps.sh` **ne définit aucune fonction `step_github_*` à ce jour** (tâche 12 du jalon 1, non terminée). Les appeler renverrait `{"ok":false,"error":"étape déclarée mais non implémentée : step_github_create_repo"}` avec un code 2 — un run cassé pour une fonctionnalité optionnelle. Le champ `requires_flag` fait sauter ces étapes tant que `github.enabled` est faux (le défaut du jalon 2), et le jour où la tâche 12 atterrit, il suffit de passer le drapeau à vrai dans `env.json` : aucune ligne de Python à changer.

---

## Task 1: Squelette `panel/`, configuration typée, harnais pytest, suppression de `web/`

**Files:**
- Create: `pyproject.toml`, `.env.example`, `panel/__init__.py`, `panel/settings.py`, `tests/conftest.py`, `tests/test_settings.py`
- Delete: `web/` (Flask, templates, static, `start.sh`, `venv`)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: rien.
- Produces : `panel.settings.Settings` (Pydantic `BaseSettings`), `panel.settings.get_settings() -> Settings` (mis en cache par `lru_cache`), et les fixtures pytest `settings`, `tmp_runs`.

- [ ] **Step 1: Écrire `pyproject.toml`**

```toml
[project]
name = "deploymatic-panel"
version = "0.2.0"
requires-python = ">=3.11"
dependencies = [
  "fastapi>=0.115",
  "uvicorn[standard]>=0.32",
  "gunicorn>=23.0",
  "sqlmodel>=0.0.22",
  "psycopg[binary]>=3.2",
  "pydantic>=2.9",
  "pydantic-settings>=2.6",
  "rq>=2.0",
  "redis>=5.2",
  "argon2-cffi>=23.1",
  "cryptography>=43.0",
  "jinja2>=3.1",
  "python-multipart>=0.0.12",
]

[project.optional-dependencies]
dev = ["pytest>=8.3", "pytest-asyncio>=0.24", "httpx>=0.27", "fakeredis>=2.26"]

[tool.pytest.ini_options]
testpaths = ["tests"]
asyncio_mode = "auto"
filterwarnings = ["error::DeprecationWarning:panel.*"]
```

`python-multipart` est nécessaire au formulaire de login (`Form(...)`). `fakeredis` évite d'exiger un Redis pour la suite unitaire ; les tests d'intégration du worker utilisent le vrai Redis de la stack.

- [ ] **Step 2: Écrire le test de configuration d'abord (il doit échouer)**

Créer `tests/test_settings.py` :

```python
"""La configuration se lit dans l'environnement et refuse de démarrer sans clé."""
import pytest
from pydantic import ValidationError

from panel.settings import Settings


def test_settings_lit_lenvironnement(monkeypatch):
    monkeypatch.setenv("PANEL_SECRET_KEY", "x" * 44)
    monkeypatch.setenv("PANEL_DATABASE_URL", "sqlite:///tmp.db")
    s = Settings()
    assert s.database_url == "sqlite:///tmp.db"
    assert s.session_max_age_seconds == 43200
    assert s.step_timeout_seconds == 600
    assert s.run_timeout_seconds == 1800
    assert s.login_rate_limit == (5, 300)


def test_settings_exige_une_cle_secrete(monkeypatch):
    monkeypatch.delenv("PANEL_SECRET_KEY", raising=False)
    with pytest.raises(ValidationError):
        Settings()


def test_runs_dir_et_engine_sont_absolus(monkeypatch):
    monkeypatch.setenv("PANEL_SECRET_KEY", "x" * 44)
    s = Settings()
    assert s.runs_dir.is_absolute()
    assert s.engine_path.is_absolute()
    assert s.engine_path.name == "bootstrap.sh"
```

```bash
python -m pytest tests/test_settings.py -q   # attendu : ModuleNotFoundError: panel
```

- [ ] **Step 3: Écrire `panel/settings.py`**

```python
"""Configuration du panneau — lue une seule fois, dans l'environnement.

Tout ce qui est réglable vit ici. Aucun module ne lit os.environ directement :
c'est ce qui rend la configuration testable (monkeypatch d'un seul objet) et
qui garantit qu'une variable oubliée casse au démarrage, pas au premier run.
"""
from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

REPO_ROOT = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="PANEL_", extra="ignore")

    # --- Secrets et base ---
    secret_key: str = Field(min_length=32)
    database_url: str = "postgresql+psycopg://panel:panel@postgres:5432/panel"
    redis_url: str = "redis://redis:6379/0"

    # --- Compte admin de premier démarrage ---
    admin_username: str = "admin"
    admin_password: str | None = None

    # --- Session et CSRF ---
    session_cookie_name: str = "deploymatic_session"
    session_max_age_seconds: int = 43200      # 12 h
    cookie_secure: bool = True                # cf. docs/PANEL.md : http://127.0.0.1
                                              # reste un contexte sûr pour les navigateurs
    allowed_origins: list[str] = ["http://127.0.0.1:8080", "https://localhost"]

    # --- Rate limiting de /login : (tentatives, fenêtre en secondes) ---
    login_rate_limit: tuple[int, int] = (5, 300)

    # --- Exécution ---
    runs_dir: Path = REPO_ROOT / "runs"
    engine_path: Path = REPO_ROOT / "engine" / "bootstrap.sh"
    step_timeout_seconds: int = 600           # 10 min par étape
    run_timeout_seconds: int = 1800           # 30 min par run
    retry_backoff_seconds: int = 5            # avant l'unique retry d'un code 1


@lru_cache
def get_settings() -> Settings:
    """Instance unique. lru_cache().cache_clear() dans les tests qui la changent."""
    return Settings()
```

- [ ] **Step 4: Écrire `tests/conftest.py`**

```python
"""Fixtures communes : environnement minimal, base éphémère, répertoire runs/."""
import os
from pathlib import Path

import pytest

os.environ.setdefault("PANEL_SECRET_KEY", "0" * 43 + "=")
os.environ.setdefault("PANEL_ADMIN_PASSWORD", "motdepasse-de-test-1234")


@pytest.fixture
def tmp_runs(tmp_path: Path, monkeypatch) -> Path:
    """Un runs/ jetable, en 700, avec la configuration qui pointe dessus."""
    from panel.settings import get_settings

    runs = tmp_path / "runs"
    runs.mkdir(mode=0o700)
    get_settings.cache_clear()
    monkeypatch.setenv("PANEL_RUNS_DIR", str(runs))
    yield runs
    get_settings.cache_clear()
```

- [ ] **Step 5: Lancer, voir vert**

```bash
python -m venv .venv && .venv/bin/pip install -e '.[dev]'
.venv/bin/python -m pytest tests/test_settings.py -q   # attendu : 3 passed
```

- [ ] **Step 6: Supprimer `web/`**

```bash
git rm -r --cached web >/dev/null && rm -rf web
```

`web/` est cassé depuis le jalon 1 (`bootstrap.sh` a déménagé sous `engine/`) et `docs/CURRENT-STATE.md` demande explicitement de ne pas le réparer. Le formulaire, la vue de progression et le SSE sont réimplémentés ici, avec un modèle de données derrière.

- [ ] **Step 7: `.gitignore` et `.env.example`**

Ajouter à `.gitignore` :

```
.venv/
__pycache__/
*.pyc
.pytest_cache/
.env
```

Créer `.env.example` (committable, aucune valeur réelle) :

```
# Généré par : python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
PANEL_SECRET_KEY=
PANEL_ADMIN_PASSWORD=
PANEL_ALLOWED_ORIGINS=["http://127.0.0.1:8080"]
POSTGRES_PASSWORD=
```

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(panel): squelette du paquet, configuration typée, harnais pytest; supprime web/"
```

---

## Task 2: `panel/crypto.py` — chiffrement Fernet des secrets

**Files:**
- Create: `panel/crypto.py`, `tests/test_crypto.py`

**Interfaces:**
- Consumes: `panel.settings.get_settings().secret_key`.
- Produces:
  - `encrypt(clair: str) -> str` — jeton Fernet en texte, stocké tel quel en base.
  - `decrypt(jeton: str) -> str` — lève `SecretError` si le jeton est corrompu ou chiffré avec une autre clé.
  - `encrypt_optional(str | None) -> str | None`, `decrypt_optional(str | None) -> str | None`.
  - `class SecretError(RuntimeError)`.

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_crypto.py` :

```python
"""Le chiffrement des secrets : aller-retour, détection de corruption, clé invalide."""
import pytest

from panel.crypto import SecretError, decrypt, decrypt_optional, encrypt, encrypt_optional


def test_aller_retour():
    assert decrypt(encrypt("dckr_pat_secret")) == "dckr_pat_secret"


def test_le_chiffre_ne_contient_pas_le_clair():
    jeton = encrypt("dckr_pat_secret")
    assert "dckr_pat_secret" not in jeton
    assert jeton.startswith("gAAAAA")          # en-tête Fernet v1


def test_deux_chiffrements_du_meme_clair_different():
    # Fernet embarque un IV aléatoire : sans ça, deux cibles au même mot de
    # passe seraient reconnaissables par simple comparaison de colonnes.
    assert encrypt("meme-secret") != encrypt("meme-secret")


def test_jeton_corrompu_est_refuse():
    jeton = encrypt("secret")
    with pytest.raises(SecretError):
        decrypt(jeton[:-4] + "AAAA")


def test_optionnels():
    assert encrypt_optional(None) is None
    assert decrypt_optional(None) is None
    assert decrypt_optional(encrypt_optional("x")) == "x"


def test_chaine_vide_reste_distincte_de_none():
    assert encrypt_optional("") is not None
    assert decrypt_optional(encrypt_optional("")) == ""
```

```bash
.venv/bin/python -m pytest tests/test_crypto.py -q   # attendu : ModuleNotFoundError
```

- [ ] **Step 2: Implémenter `panel/crypto.py`**

```python
"""Chiffrement symétrique des secrets stockés en base.

Ce qui est chiffré : mot de passe SSH d'une cible, token Docker Hub, token
GitHub — et, plus tard, mot de passe de l'API BunkerWeb (jalon 4) et clé API
du LLM (jalon 5).

Ce qui ne l'est pas : hôtes, utilisateurs, ports, CHEMINS de clés SSH (un
chemin n'est pas un secret ; la clé, elle, est un secret Docker monté en
lecture seule dans le worker), spec.json, statuts, logs.

Le déchiffrement n'a lieu que dans le processus WORKER, au moment d'écrire
runs/<slug>/env.json (cf. panel/runspace.py). Le processus panel chiffre à
l'entrée et ne déchiffre jamais : aucun endpoint ne renvoie un secret.
"""
from functools import lru_cache

from cryptography.fernet import Fernet, InvalidToken

from panel.settings import get_settings


class SecretError(RuntimeError):
    """Clé absente/invalide, ou jeton illisible avec la clé courante."""


@lru_cache
def _box() -> Fernet:
    key = get_settings().secret_key
    try:
        return Fernet(key.encode())
    except (ValueError, TypeError) as exc:
        raise SecretError(
            "PANEL_SECRET_KEY invalide : 32 octets encodés en base64 url-safe "
            "attendus (Fernet.generate_key())"
        ) from exc


def encrypt(clair: str) -> str:
    return _box().encrypt(clair.encode()).decode()


def decrypt(jeton: str) -> str:
    try:
        return _box().decrypt(jeton.encode()).decode()
    except InvalidToken as exc:
        raise SecretError(
            "secret illisible : jeton corrompu, ou chiffré avec une autre "
            "PANEL_SECRET_KEY"
        ) from exc


def encrypt_optional(clair: str | None) -> str | None:
    return None if clair is None else encrypt(clair)


def decrypt_optional(jeton: str | None) -> str | None:
    return None if jeton is None else decrypt(jeton)
```

- [ ] **Step 3: Voir vert, puis vérifier par mutation**

```bash
.venv/bin/python -m pytest tests/test_crypto.py -q          # attendu : 6 passed
```

Mutation : remplacer temporairement le corps de `encrypt` par `return clair`.
Attendu : `test_le_chiffre_ne_contient_pas_le_clair`, `test_deux_chiffrements_du_meme_clair_different` et `test_jeton_corrompu_est_refuse` passent au **rouge**. Restaurer.

- [ ] **Step 4: Commit**

```bash
git add panel/crypto.py tests/test_crypto.py
git commit -m "feat(panel): chiffrement Fernet des secrets, clé depuis PANEL_SECRET_KEY"
```

---

## Task 3: `panel/models.py` et `panel/db.py` — le modèle de données

**Files:**
- Create: `panel/models.py`, `panel/db.py`, `tests/test_models.py`

**Interfaces:**
- Consumes: `panel.settings`, `panel.crypto`.
- Produces:
  - Enums `AuthMethod`, `AppStatus`, `RunTrigger`, `RunStatus`, `StepStatus`, `StepKind`.
  - Tables `User`, `Target`, `App`, `Run`, `Step`.
  - `panel.db.engine`, `panel.db.create_all() -> None`, `panel.db.session_scope() -> Iterator[Session]` (contextmanager, commit/rollback), `panel.db.get_session()` (dépendance FastAPI).

**Écarts assumés par rapport au modèle de la feuille de route** (à relire en revue) :
- `Target.port: int = 22` — l'engine gère `target.port` depuis la tâche 11 du jalon 1 (`engine/lib/ssh_remote.sh`, `_target_port`). Sans ce champ, la cible de test locale (Lima, `127.0.0.1:60122`) est injoignable depuis le panneau.
- `Run.rq_job_id: str | None` — la réconciliation (D4) doit pouvoir demander à Redis si le job existe encore. Sans cette colonne, elle ne peut pas trancher.
- `Step.kind`, `Step.attempts`, `Step.error`, `Step.data` — respectivement D1, le retry sur code 1, le message d'erreur de la ligne JSON, et son `data`.
- `App.secrets_enc` séparé de `App.env` : `env` est du JSON lisible (affiché dans l'UI), `secrets_enc` est un blob Fernet. Mélanger les deux obligerait à chiffrer/déchiffrer une structure entière pour lire `NODE_ENV`.

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_models.py` :

```python
"""Contraintes du modèle : unicité du nom, cascade, secrets illisibles en base."""
import pytest
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlmodel import Session, SQLModel, create_engine, select

from panel.crypto import encrypt
from panel.models import App, AppStatus, AuthMethod, Run, RunStatus, Step, StepKind, StepStatus, Target, User


@pytest.fixture
def session():
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False})
    SQLModel.metadata.create_all(engine)
    with Session(engine) as s:
        yield s


def _cible(session) -> Target:
    t = Target(name="vm-test", host="127.0.0.1", port=60122, ssh_user="devops",
               auth_method=AuthMethod.KEY, ssh_key_path="/secrets/id_ed25519")
    session.add(t)
    session.commit()
    return t


def test_target_porte_un_port_avec_22_par_defaut(session):
    t = Target(name="prod", host="1.2.3.4", ssh_user="devops")
    session.add(t)
    session.commit()
    assert t.port == 22
    assert t.auth_method is AuthMethod.KEY


def test_nom_dapplication_unique(session):
    t = _cible(session)
    session.add(App(name="mon-app", target_id=t.id, spec={"name": "mon-app", "services": []}))
    session.commit()
    session.add(App(name="mon-app", target_id=t.id, spec={"name": "mon-app", "services": []}))
    with pytest.raises(IntegrityError):
        session.commit()


def test_les_secrets_ne_sont_pas_lisibles_dans_la_ligne_brute(session):
    t = _cible(session)
    app = App(name="mon-app", target_id=t.id, spec={"name": "mon-app", "services": []},
              secrets_enc=encrypt('{"registry_token": "dckr_pat_ultrasecret"}'))
    session.add(app)
    session.commit()
    # Critère d'acceptation n°7 du jalon 2, vérifié au niveau SQL.
    brut = session.exec(text("SELECT * FROM app")).all()
    assert "dckr_pat_ultrasecret" not in str(brut)


def test_chaine_run_step(session):
    t = _cible(session)
    app = App(name="mon-app", target_id=t.id, spec={"name": "mon-app", "services": []})
    session.add(app)
    session.commit()
    run = Run(app_id=app.id, status=RunStatus.QUEUED, rq_job_id="job-1")
    session.add(run)
    session.commit()
    session.add(Step(run_id=run.id, name="prepare_workspace", ordinal=0,
                     kind=StepKind.PYTHON, status=StepStatus.PENDING))
    session.commit()
    etapes = session.exec(select(Step).where(Step.run_id == run.id)).all()
    assert [e.name for e in etapes] == ["prepare_workspace"]
    assert etapes[0].attempts == 0
```

- [ ] **Step 2: Implémenter `panel/models.py`**

```python
"""Le modèle de données du panneau.

La SÉQUENCE d'étapes n'est pas une table : c'est panel/pipeline.py, versionné
avec le code. `Step` n'enregistre que des INSTANCES d'exécution — et c'est
cette table qui porte l'idempotence (cf. D2), à la place de l'ancien fichier
d'état .bootstrap-state.
"""
from datetime import datetime, timezone
from enum import Enum

from sqlalchemy import JSON, Column, UniqueConstraint
from sqlmodel import Field, SQLModel


def _now() -> datetime:
    return datetime.now(timezone.utc)


class AuthMethod(str, Enum):
    KEY = "key"
    PASSWORD = "password"


class AppStatus(str, Enum):
    NEW = "new"
    DEPLOYING = "deploying"
    DEPLOYED = "deployed"
    FAILED = "failed"


class RunTrigger(str, Enum):
    MANUAL = "manual"
    CI = "ci"            # réservé : aucun endpoint CI au jalon 2
    API = "api"


class RunStatus(str, Enum):
    QUEUED = "queued"
    RUNNING = "running"
    OK = "ok"
    FAILED = "failed"


class StepStatus(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    OK = "ok"
    FAILED = "failed"
    SKIPPED = "skipped"


class StepKind(str, Enum):
    """D1 : deux natures d'étape. `engine` appelle bootstrap.sh, `python`
    appelle un enregistré de panel/worker/steps_py.py."""
    ENGINE = "engine"
    PYTHON = "python"


class User(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    username: str = Field(unique=True, index=True, max_length=64)
    password_hash: str                       # argon2id, jamais renvoyé par l'API
    created_at: datetime = Field(default_factory=_now)
    last_login: datetime | None = None


class Target(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    name: str = Field(unique=True, index=True, max_length=64)
    host: str = Field(max_length=255)
    port: int = Field(default=22, ge=1, le=65535)   # cf. engine _target_port()
    ssh_user: str = Field(max_length=64)
    auth_method: AuthMethod = Field(default=AuthMethod.KEY)
    ssh_key_path: str | None = None                 # chemin, pas un secret
    password_enc: str | None = None                 # Fernet, jamais en clair
    bind_addr: str = Field(default="0.0.0.0", max_length=64)
    is_local: bool = False                          # jalon 3 ; le champ existe déjà
    created_at: datetime = Field(default_factory=_now)


class App(SQLModel, table=True):
    __table_args__ = (UniqueConstraint("name", name="uq_app_name"),)

    id: int | None = Field(default=None, primary_key=True)
    # name == slug == workspace == répertoire == projet Compose == réseau Docker
    # Validé par ^[a-z][a-z0-9-]{1,30}$ AVANT l'insertion (D5, panel/spec.py).
    name: str = Field(index=True, max_length=31)
    target_id: int = Field(foreign_key="target.id")
    spec: dict = Field(sa_column=Column(JSON), default_factory=dict)
    env: dict = Field(sa_column=Column(JSON), default_factory=dict)   # NON secret
    secrets_enc: str | None = None                                   # Fernet
    status: AppStatus = Field(default=AppStatus.NEW)
    created_at: datetime = Field(default_factory=_now)
    updated_at: datetime = Field(default_factory=_now)

    @property
    def slug(self) -> str:
        """Il n'y a rien à calculer : le nom EST le slug (D5)."""
        return self.name


class Run(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    app_id: int = Field(foreign_key="app.id", index=True)
    trigger: RunTrigger = Field(default=RunTrigger.MANUAL)
    status: RunStatus = Field(default=RunStatus.QUEUED, index=True)
    rq_job_id: str | None = Field(default=None, index=True)   # D4
    started_at: datetime | None = None
    finished_at: datetime | None = None
    error: str | None = None
    created_at: datetime = Field(default_factory=_now)


class Step(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    run_id: int = Field(foreign_key="run.id", index=True)
    name: str = Field(index=True, max_length=64)
    ordinal: int
    kind: StepKind = Field(default=StepKind.ENGINE)
    status: StepStatus = Field(default=StepStatus.PENDING, index=True)
    attempts: int = 0                       # 0, puis 1 après l'unique retry d'un code 1
    started_at: datetime | None = None
    finished_at: datetime | None = None
    exit_code: int | None = None
    error: str | None = None
    data: dict | None = Field(sa_column=Column(JSON), default=None)
    log_path: str | None = None
```

- [ ] **Step 3: Implémenter `panel/db.py`**

```python
"""Moteur, sessions, création du schéma.

Pas d'Alembic au jalon 2 : le schéma est créé par create_all() au démarrage.
La migration devient nécessaire au jalon 3 (PortAllocation) — c'est le bon
moment pour l'introduire, pas avant.
"""
from collections.abc import Iterator
from contextlib import contextmanager

from sqlmodel import Session, SQLModel, create_engine

from panel.settings import get_settings

engine = create_engine(get_settings().database_url, pool_pre_ping=True)


def create_all() -> None:
    import panel.models  # noqa: F401  (enregistre les tables sur la metadata)

    SQLModel.metadata.create_all(engine)


@contextmanager
def session_scope() -> Iterator[Session]:
    """Transaction explicite pour le worker : commit à la sortie, rollback sur
    exception. Le worker écrit depuis un processus SANS requête HTTP, il ne peut
    pas s'appuyer sur la dépendance FastAPI."""
    with Session(engine) as session:
        try:
            yield session
            session.commit()
        except Exception:
            session.rollback()
            raise


def get_session() -> Iterator[Session]:
    """Dépendance FastAPI : une session par requête."""
    with Session(engine) as session:
        yield session
```

- [ ] **Step 4: Voir vert**

```bash
.venv/bin/python -m pytest tests/test_models.py -q   # attendu : 5 passed
```

Note : les tests tournent sur SQLite (type `JSON` générique, portable), la production sur PostgreSQL 16. Aucune fonctionnalité spécifique à Postgres n'est utilisée au jalon 2 — le `SELECT … FOR UPDATE` de l'allocateur de ports arrive au jalon 3 et devra, lui, être testé sur Postgres.

- [ ] **Step 5: Commit**

```bash
git add panel/models.py panel/db.py tests/test_models.py
git commit -m "feat(panel): modèle de données SQLModel (User, Target, App, Run, Step)"
```

---

## Task 4: `panel/spec.py` — `AppSpec` Pydantic et le nom d'application

**Files:**
- Create: `panel/spec.py`, `tests/test_spec.py`

**Interfaces:**
- Consumes: rien (module pur, aucune I/O — c'est ce qui le rend testable en dur).
- Produces:
  - `AppName` — `Annotated[str, StringConstraints(pattern=APP_NAME_PATTERN)]`, `APP_NAME_PATTERN = r"^[a-z][a-z0-9-]{1,30}$"`.
  - `ServiceSpec` — `id`, `build | image`, `port`, `health`, `expose`, `internal`, `env`, `volumes`.
  - `AppSpec` — `name: AppName`, `services: list[ServiceSpec]` (au moins un), avec les validateurs de cohérence.
  - `AppSpec.to_engine_json() -> dict` — la forme exacte attendue par `engine/lib/config.sh` (contrat **C3**).

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_spec.py` :

```python
"""Validation du spec et du nom d'application (D5)."""
import pytest
from pydantic import ValidationError

from panel.spec import AppSpec


def _spec(**kw) -> dict:
    base = {"name": "mon-app",
            "services": [{"id": "api", "build": "./services/api", "port": 3000,
                          "health": "/health", "expose": "/api/"}]}
    base.update(kw)
    return base


@pytest.mark.parametrize("nom", ["a" * 31, "mon-app", "app1", "web-front-2"])
def test_noms_valides(nom):
    assert AppSpec.model_validate(_spec(name=nom)).name == nom


@pytest.mark.parametrize("nom", [
    "../foo",            # traversée de chemin — le bug historique
    "..",
    "/etc/passwd",
    "A_b",               # majuscule + underscore
    "MonApp",
    "1app",              # ne commence pas par une lettre
    "a",                 # trop court (2 caractères minimum)
    "a" * 32,            # 32 caractères : un de trop
    "mon app",
    "mon.app",
    "mon;app",
    "mon-app\n",         # une regex non ancrée sur \Z laisserait passer ceci
    "",
])
def test_noms_invalides(nom):
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(name=nom))


def test_un_service_exige_build_ou_image_mais_pas_les_deux():
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(services=[{"id": "api", "port": 3000}]))
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(services=[
            {"id": "api", "build": "./a", "image": "nginx:alpine", "port": 3000}]))


def test_ids_de_service_uniques_et_conformes():
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(services=[
            {"id": "api", "build": "./a", "port": 3000},
            {"id": "api", "build": "./b", "port": 3001}]))
    with pytest.raises(ValidationError):
        # spec_init (engine/lib/config.sh) refuse déjà ces ids ; le panneau ne
        # doit jamais produire un spec que l'engine rejettera en code 2.
        AppSpec.model_validate(_spec(services=[{"id": "a b", "build": "./a", "port": 3000}]))


def test_expose_et_internal_sont_exclusifs():
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(services=[
            {"id": "db", "image": "postgres:16-alpine", "internal": True, "expose": "/"}]))


def test_au_moins_un_service_expose():
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(services=[
            {"id": "db", "image": "postgres:16-alpine", "internal": True}]))


def test_to_engine_json_est_le_contrat_c3():
    spec = AppSpec.model_validate(_spec())
    brut = spec.to_engine_json()
    assert brut == {"name": "mon-app",
                    "services": [{"id": "api", "build": "./services/api", "port": 3000,
                                  "health": "/health", "expose": "/api/"}]}
    # Les champs absents ne doivent pas apparaître à null : spec_get distingue
    # « absent » de « null » mais gen_compose.sh lit des chaînes.
    assert "image" not in brut["services"][0]


def test_le_nom_du_panneau_est_accepte_par_lengine():
    """La regex du panneau est un sous-ensemble strict de celle de l'engine."""
    import re
    engine_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$")
    for nom in ["mon-app", "a1", "a" * 31, "z-9-z"]:
        assert engine_re.match(AppSpec.model_validate(_spec(name=nom)).name)
```

- [ ] **Step 2: Implémenter `panel/spec.py`**

```python
"""Schéma d'application — contrat C3, côté producteur.

L'engine (engine/lib/config.sh : spec_init, spec_get, spec_is_internal…) est le
CONSOMMATEUR de ce fichier. Tout ce qui est refusé ici en 422 aurait été refusé
là-bas en code 2, mais bien plus tard, après avoir écrit des fichiers sur la
cible. On valide donc au plus tôt, à l'entrée de l'API.
"""
import re
from typing import Annotated, Any, Self

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

# D5 : ce nom devient workspace, répertoire, projet Compose et réseau Docker.
APP_NAME_PATTERN = r"^[a-z][a-z0-9-]{1,30}$"
AppName = Annotated[str, StringConstraints(pattern=APP_NAME_PATTERN)]

# Aligné sur la validation d'id de service de spec_init (engine/lib/config.sh).
SERVICE_ID_PATTERN = r"^[A-Za-z0-9_-]{1,32}$"
ServiceId = Annotated[str, StringConstraints(pattern=SERVICE_ID_PATTERN)]


class ServiceSpec(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: ServiceId
    build: str | None = None          # service buildé → durcissement complet
    image: str | None = None          # image tierce → durcissement partiel
    port: int | None = Field(default=None, ge=1, le=65535)   # port CONTENEUR
    health: str | None = None
    expose: str | None = None         # chemin PUBLIC ; un port hôte sera publié
    internal: bool = False            # aucun port publié
    env: dict[str, str] = Field(default_factory=dict)
    volumes: list[str] = Field(default_factory=list)

    @model_validator(mode="after")
    def _coherence(self) -> Self:
        if bool(self.build) == bool(self.image):
            raise ValueError(
                f"service '{self.id}' : exactement un de 'build' ou 'image' est requis"
            )
        if self.internal and self.expose:
            raise ValueError(
                f"service '{self.id}' : 'internal' et 'expose' s'excluent"
            )
        if self.expose and not self.expose.startswith("/"):
            raise ValueError(
                f"service '{self.id}' : 'expose' doit être un chemin absolu (ex. '/api/')"
            )
        if self.build and self.port is None:
            raise ValueError(f"service '{self.id}' : un service buildé doit déclarer 'port'")
        return self


class AppSpec(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: AppName
    services: list[ServiceSpec] = Field(min_length=1)

    @model_validator(mode="after")
    def _coherence(self) -> Self:
        ids = [s.id for s in self.services]
        doublons = {i for i in ids if ids.count(i) > 1}
        if doublons:
            raise ValueError(f"ids de service dupliqués : {', '.join(sorted(doublons))}")
        if not any(s.expose for s in self.services):
            raise ValueError(
                "au moins un service doit porter 'expose' : sans chemin public, "
                "l'application n'est joignable par personne"
            )
        chemins = [s.expose for s in self.services if s.expose]
        if len(set(chemins)) != len(chemins):
            raise ValueError("deux services ne peuvent pas exposer le même chemin")
        return self

    def to_engine_json(self) -> dict[str, Any]:
        """La forme exacte écrite dans runs/<slug>/spec.json.

        exclude_none : gen_compose.sh teste la PRÉSENCE d'un champ (`spec_get`
        renvoie le défaut sur un champ absent OU null, mais `"image": null`
        dans le fichier est un piège pour un lecteur humain). exclude_defaults
        n'est PAS utilisé : `internal: false` explicite est plus lisible qu'un
        champ manquant — sauf qu'il gonfle le fichier, d'où le filtrage manuel
        des collections vides ci-dessous.
        """
        services = []
        for s in self.services:
            d = s.model_dump(exclude_none=True)
            if not d.get("env"):
                d.pop("env", None)
            if not d.get("volumes"):
                d.pop("volumes", None)
            if d.get("internal") is False:
                d.pop("internal", None)
            services.append(d)
        return {"name": self.name, "services": services}


def valider_nom_application(nom: str) -> str:
    """Garde de dernier recours, appelée par panel/runspace.py juste avant de
    construire un chemin. Le jour où un chemin se construit depuis une ligne de
    base plutôt que depuis une requête validée, cette garde tient encore."""
    if not re.match(APP_NAME_PATTERN, nom):
        raise ValueError(f"nom d'application invalide : {nom!r}")
    return nom
```

- [ ] **Step 3: Voir vert, puis vérifier par mutation**

```bash
.venv/bin/python -m pytest tests/test_spec.py -q   # attendu : 24 passed
```

Mutations à passer une par une, chacune doit faire **rougir** au moins une assertion :

| Mutation | Assertion qui doit rougir |
|---|---|
| `APP_NAME_PATTERN` → `r"^[a-z][a-z0-9-]{1,30}"` (ancre de fin retirée) | `test_noms_invalides["mon-app\n"]` |
| `APP_NAME_PATTERN` → `r"[a-z][a-z0-9-]{1,30}$"` (ancre de début retirée) | `test_noms_invalides["../foo"]`, `["1app"]` |
| `re.match` → `re.search` dans `valider_nom_application` | test de la Task 12 (`test_runspace`) |
| `{1,30}` → `{1,40}` | `test_noms_invalides["a" * 32]` |
| suppression du validateur `_coherence` de `AppSpec` | `test_ids_de_service_uniques_et_conformes` |

Si une mutation ne fait rougir aucune assertion, c'est le **test** qu'il faut corriger, pas la mutation.

- [ ] **Step 4: Commit**

```bash
git add panel/spec.py tests/test_spec.py
git commit -m "feat(panel): AppSpec Pydantic et nom d'application ^[a-z][a-z0-9-]{1,30}$"
```

---

## Task 5: `panel/pipeline.py` — les deux natures d'étape et la parité avec l'engine

**Files:**
- Create: `panel/pipeline.py`, `tests/test_pipeline.py`

**Interfaces:**
- Consumes: `panel.models.StepKind`, et — pour le **test** seulement — la sortie réelle de `bash engine/bootstrap.sh --list-steps`.
- Produces:
  - `@dataclass(frozen=True) StepDef(name: str, kind: StepKind, always_rerun: bool, requires_flag: str | None = None, python_handler: str | None = None)`
  - `PIPELINE: tuple[StepDef, ...]`
  - `step_def(name: str) -> StepDef` (lève `KeyError`)
  - `engine_step_names() -> tuple[str, ...]`

- [ ] **Step 1: Écrire le test d'abord — il consulte le VRAI engine**

Créer `tests/test_pipeline.py` :

```python
"""Contrat C2 : les noms et l'ordre des étapes, confrontés à l'engine réel."""
import subprocess
from pathlib import Path

from panel.models import StepKind
from panel.pipeline import PIPELINE, engine_step_names, step_def

REPO_ROOT = Path(__file__).resolve().parent.parent


def _list_steps_de_lengine() -> list[str]:
    out = subprocess.run(
        ["bash", str(REPO_ROOT / "engine" / "bootstrap.sh"), "--list-steps"],
        capture_output=True, text=True, check=True, cwd=REPO_ROOT,
    )
    return out.stdout.split()


def test_toutes_les_etapes_engine_existent_dans_lengine():
    connues = _list_steps_de_lengine()
    inconnues = [n for n in engine_step_names() if n not in connues]
    assert inconnues == [], f"étapes absentes de --list-steps : {inconnues}"


def test_lordre_relatif_est_celui_de_lengine():
    connues = _list_steps_de_lengine()
    positions = [connues.index(n) for n in engine_step_names()]
    assert positions == sorted(positions), "le pipeline réordonne les étapes de l'engine"


def test_aucune_etape_de_lengine_nest_oubliee():
    connues = set(_list_steps_de_lengine())
    oubliees = connues - set(engine_step_names())
    assert oubliees == set(), f"étapes de l'engine absentes du pipeline : {oubliees}"


def test_la_premiere_etape_est_python():
    """D1 : le mécanisme des étapes Python est exercé par TOUS les runs, il
    n'attend pas le jalon 4 pour exister."""
    assert PIPELINE[0].name == "prepare_workspace"
    assert PIPELINE[0].kind is StepKind.PYTHON
    assert PIPELINE[0].python_handler == "prepare_workspace"


def test_les_deux_ensembles_didempotence_couvrent_le_pipeline():
    """D2 : la liste est déclarée à UN seul endroit. Ce test échoue si
    quelqu'un ajoute une étape sans se prononcer."""
    rejouees = {s.name for s in PIPELINE if s.always_rerun}
    sautables = {s.name for s in PIPELINE if not s.always_rerun}
    assert rejouees | sautables == {s.name for s in PIPELINE}
    assert rejouees & sautables == set()
    assert "generate_compose" in rejouees
    assert "prepare_server" in sautables


def test_les_etapes_github_sont_derriere_un_drapeau():
    """engine/lib/steps.sh ne définit AUCUN step_github_* aujourd'hui : les
    appeler renverrait un code 2. Le drapeau les neutralise."""
    for nom in ("github_create_repo", "github_set_secrets", "git_init", "git_push"):
        assert step_def(nom).requires_flag == "github.enabled"


def test_les_noms_sont_uniques():
    noms = [s.name for s in PIPELINE]
    assert len(noms) == len(set(noms))
```

```bash
.venv/bin/python -m pytest tests/test_pipeline.py -q   # attendu : ModuleNotFoundError
```

- [ ] **Step 2: Implémenter `panel/pipeline.py`**

```python
"""La séquence d'étapes — une CONSTANTE Python, pas une table.

Pourquoi pas une table : la séquence est du code, elle change avec le code, et
une table qui la duplique se désynchronise silencieusement du jour où quelqu'un
déploie une nouvelle version sans migrer les lignes. `Step` enregistre les
INSTANCES d'exécution ; PIPELINE décrit la partition.

Contrat C2 : ce fichier et la constante STEPS de engine/bootstrap.sh sont
dupliqués À DESSEIN. tests/test_pipeline.py confronte les deux à chaque
exécution de la suite — c'est ce qui rend la duplication tenable.
"""
from dataclasses import dataclass

from panel.models import StepKind


@dataclass(frozen=True, slots=True)
class StepDef:
    """Définition d'une étape.

    name           nom de l'étape ; pour kind=ENGINE, le --step passé à bootstrap.sh
    kind           D1 : ENGINE (subprocess) ou PYTHON (appelable enregistré)
    always_rerun   D2 : True = rejouée à chaque run ; False = `skipped` si déjà `ok`
    requires_flag  chemin pointé d'env.json ; l'étape est `skipped` si le drapeau
                   n'est pas vrai (ex. "github.enabled")
    python_handler clé dans le registre de panel/worker/steps_py.py (kind=PYTHON)
    """

    name: str
    kind: StepKind
    always_rerun: bool
    requires_flag: str | None = None
    python_handler: str | None = None


def _engine(name: str, *, always_rerun: bool, requires_flag: str | None = None) -> StepDef:
    return StepDef(name=name, kind=StepKind.ENGINE, always_rerun=always_rerun,
                   requires_flag=requires_flag)


PIPELINE: tuple[StepDef, ...] = (
    # --- Nature python : matérialise runs/<slug>/ avant tout appel à l'engine.
    StepDef(name="prepare_workspace", kind=StepKind.PYTHON, always_rerun=True,
            python_handler="prepare_workspace"),

    # --- Vérifications : coût nul, résultat périssable → toujours rejouées.
    _engine("check_prereqs", always_rerun=True),
    _engine("validate_ssh", always_rerun=True),

    # --- Effet durable sur la cible → sauté si déjà ok pour cette application.
    _engine("create_project_dir", always_rerun=False),

    # --- Générateurs : leur sortie dépend du spec COURANT. Les rejouer est le
    #     seul moyen qu'un spec modifié se reflète dans les fichiers générés.
    _engine("generate_microservices", always_rerun=True),
    _engine("generate_compose", always_rerun=True),
    _engine("generate_skills", always_rerun=True),
    _engine("generate_workflow", always_rerun=True),

    # --- Provisionnement : coûteux, idempotent côté engine, mais lent. Sauté.
    _engine("enable_sudo_nopasswd", always_rerun=False),
    _engine("prepare_server", always_rerun=False),

    # --- Build et déploiement : c'est le cœur d'un run, jamais sauté.
    _engine("build_images", always_rerun=True),
    _engine("deploy_stack", always_rerun=True),
    _engine("validate_deployment", always_rerun=True),

    # --- Bloc GitHub, optionnel. Voir requires_flag et le commentaire du plan :
    #     engine/lib/steps.sh ne définit pas encore ces fonctions (jalon 1, T12).
    _engine("github_create_repo", always_rerun=False, requires_flag="github.enabled"),
    _engine("github_set_secrets", always_rerun=False, requires_flag="github.enabled"),
    _engine("git_init", always_rerun=False, requires_flag="github.enabled"),
    _engine("git_push", always_rerun=False, requires_flag="github.enabled"),
)

_INDEX = {s.name: s for s in PIPELINE}


def step_def(name: str) -> StepDef:
    return _INDEX[name]


def engine_step_names() -> tuple[str, ...]:
    return tuple(s.name for s in PIPELINE if s.kind is StepKind.ENGINE)
```

- [ ] **Step 3: Voir vert**

```bash
.venv/bin/python -m pytest tests/test_pipeline.py -q   # attendu : 7 passed
```

Si `test_aucune_etape_de_lengine_nest_oubliee` rougit, c'est que l'engine a gagné une étape depuis la rédaction : l'ajouter au pipeline **en se prononçant sur `always_rerun`**, jamais la retirer du test.

- [ ] **Step 4: Commit**

```bash
git add panel/pipeline.py tests/test_pipeline.py
git commit -m "feat(panel): pipeline en constante, deux natures d'étape, parité testée avec l'engine"
```

---

## Task 6: `panel/auth.py` — argon2, compte admin, session signée

**Files:**
- Create: `panel/auth.py`, `tests/test_auth.py`

**Interfaces:**
- Consumes: `panel.settings`, `panel.models.User`, `panel.db`.
- Produces:
  - `hash_password(clair: str) -> str` / `verify_password(hash: str, clair: str) -> bool`
  - `ensure_admin_user(session) -> User | None` — crée le compte au premier démarrage depuis `PANEL_ADMIN_PASSWORD` ; ne fait rien si un utilisateur existe déjà.
  - `sign_session(payload: dict) -> str` / `read_session(jeton: str) -> dict | None` — HMAC-SHA256 + horodatage d'expiration.
  - `new_csrf_token() -> str`

**Pourquoi un HMAC maison et pas une dépendance de plus** : `itsdangerous` ferait exactement ceci. La signature d'une session est 25 lignes de `hmac` + `base64` de la bibliothèque standard, entièrement testables, et une dépendance de moins dans une image qui exécute du code à distance. La cryptographie n'est pas artisanale : c'est `hmac.new(..., hashlib.sha256)` et `hmac.compare_digest`.

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_auth.py` :

```python
"""Hachage argon2, session signée, création du compte admin."""
import time

import pytest
from sqlmodel import Session, SQLModel, create_engine, select

from panel.auth import (ensure_admin_user, hash_password, new_csrf_token,
                        read_session, sign_session, verify_password)
from panel.models import User


@pytest.fixture
def session():
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False})
    SQLModel.metadata.create_all(engine)
    with Session(engine) as s:
        yield s


def test_argon2_et_verification():
    h = hash_password("un-mot-de-passe-correct")
    assert h.startswith("$argon2id$")
    assert verify_password(h, "un-mot-de-passe-correct")
    assert not verify_password(h, "un-mot-de-passe-correct ")
    assert not verify_password(h, "")


def test_deux_hachages_du_meme_mot_de_passe_different():
    assert hash_password("x" * 20) != hash_password("x" * 20)


def test_un_hachage_corrompu_ne_leve_pas_mais_renvoie_faux():
    assert verify_password("pas-un-hachage", "quoi que ce soit") is False


def test_session_signee_aller_retour():
    jeton = sign_session({"uid": 1, "csrf": "abc"})
    assert read_session(jeton) == {"uid": 1, "csrf": "abc"}


def test_session_alteree_est_refusee():
    jeton = sign_session({"uid": 1, "csrf": "abc"})
    corps, signature = jeton.rsplit(".", 1)
    assert read_session(corps + ".AAAA") is None
    # Élever ses privilèges en réécrivant le corps doit échouer.
    faux = sign_session({"uid": 2, "csrf": "abc"}).rsplit(".", 1)[0]
    assert read_session(faux + "." + signature) is None


def test_session_expiree_est_refusee(monkeypatch):
    jeton = sign_session({"uid": 1}, now=time.time() - 100_000)
    assert read_session(jeton) is None


def test_csrf_token_est_imprevisible():
    jetons = {new_csrf_token() for _ in range(100)}
    assert len(jetons) == 100
    assert all(len(j) >= 43 for j in jetons)


def test_ensure_admin_user_cree_puis_ne_recree_pas(session, monkeypatch):
    from panel.settings import get_settings
    get_settings.cache_clear()
    monkeypatch.setenv("PANEL_ADMIN_PASSWORD", "un-mot-de-passe-de-test")
    u = ensure_admin_user(session)
    assert u is not None and u.username == "admin"
    assert verify_password(u.password_hash, "un-mot-de-passe-de-test")
    assert ensure_admin_user(session) is None
    assert len(session.exec(select(User)).all()) == 1
    get_settings.cache_clear()
```

- [ ] **Step 2: Implémenter `panel/auth.py`**

```python
"""Authentification : hachage argon2id et session signée.

Le panneau est un exécuteur de code à distance. L'authentification n'est pas du
confort — c'est la seule chose entre un formulaire web et un `docker` root sur
une machine de production.
"""
import base64
import hashlib
import hmac
import json
import secrets
import time

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerifyMismatchError, VerificationError
from sqlmodel import Session, select

from panel.models import User
from panel.settings import get_settings

_hasher = PasswordHasher()          # paramètres par défaut d'argon2-cffi (argon2id)


def hash_password(clair: str) -> str:
    return _hasher.hash(clair)


def verify_password(hachage: str, clair: str) -> bool:
    """Ne lève jamais : un hachage corrompu en base est un échec d'auth, pas un 500."""
    try:
        return _hasher.verify(hachage, clair)
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def ensure_admin_user(session: Session) -> User | None:
    """Crée le compte unique au premier démarrage. Renvoie None s'il en existe
    déjà un — ce qui rend l'appel sûr à chaque démarrage de conteneur."""
    if session.exec(select(User)).first() is not None:
        return None
    settings = get_settings()
    if not settings.admin_password:
        raise RuntimeError(
            "aucun utilisateur en base et PANEL_ADMIN_PASSWORD non défini : "
            "le panneau refuserait toute connexion. Définir la variable, ou "
            "créer le compte avec l'assistant d'initialisation."
        )
    if len(settings.admin_password) < 12:
        raise RuntimeError("PANEL_ADMIN_PASSWORD : 12 caractères minimum")
    user = User(username=settings.admin_username,
                password_hash=hash_password(settings.admin_password))
    session.add(user)
    session.commit()
    session.refresh(user)
    return user


# ----- Session signée --------------------------------------------------------
# Format : base64url(json(payload)) + "." + base64url(hmac_sha256(clé, corps))
# Le payload porte "exp" : la signature seule ne suffit pas, un jeton volé doit
# périmer. La clé de signature est DÉRIVÉE de PANEL_SECRET_KEY (et pas égale à
# elle) pour qu'un même secret ne serve pas à deux usages cryptographiques.

def _signing_key() -> bytes:
    return hashlib.sha256(b"session-v1|" + get_settings().secret_key.encode()).digest()


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def _unb64(texte: str) -> bytes:
    return base64.urlsafe_b64decode(texte + "=" * (-len(texte) % 4))


def sign_session(payload: dict, now: float | None = None) -> str:
    now = time.time() if now is None else now
    corps = dict(payload)
    corps["exp"] = int(now) + get_settings().session_max_age_seconds
    brut = _b64(json.dumps(corps, separators=(",", ":"), sort_keys=True).encode())
    signature = hmac.new(_signing_key(), brut.encode(), hashlib.sha256).digest()
    return f"{brut}.{_b64(signature)}"


def read_session(jeton: str | None) -> dict | None:
    """Renvoie le payload (sans "exp") si la signature ET la date sont bonnes."""
    if not jeton or "." not in jeton:
        return None
    brut, signature = jeton.rsplit(".", 1)
    attendue = hmac.new(_signing_key(), brut.encode(), hashlib.sha256).digest()
    try:
        fournie = _unb64(signature)
    except Exception:
        return None
    if not hmac.compare_digest(attendue, fournie):     # temps constant, obligatoire
        return None
    try:
        payload = json.loads(_unb64(brut))
    except Exception:
        return None
    if not isinstance(payload, dict) or payload.get("exp", 0) < time.time():
        return None
    payload.pop("exp", None)
    return payload


def new_csrf_token() -> str:
    return secrets.token_urlsafe(32)
```

- [ ] **Step 3: Voir vert, puis vérifier par mutation**

```bash
.venv/bin/python -m pytest tests/test_auth.py -q   # attendu : 8 passed
```

| Mutation | Assertion qui doit rougir |
|---|---|
| `hmac.compare_digest(...)` → `attendue == fournie` | aucune (comportement identique) — **et c'est normal** : la comparaison en temps constant se relit, elle ne se teste pas unitairement. Le noter dans la revue plutôt que d'écrire un test de timing instable. |
| supprimer le test `payload.get("exp", 0) < time.time()` | `test_session_expiree_est_refusee` |
| `read_session` renvoyant le payload sans vérifier la signature | `test_session_alteree_est_refusee` |
| `verify_password` renvoyant `True` en cas d'exception | `test_un_hachage_corrompu_ne_leve_pas_mais_renvoie_faux` |
| `ensure_admin_user` sans le `if … first() is not None` | `test_ensure_admin_user_cree_puis_ne_recree_pas` |

- [ ] **Step 4: Commit**

```bash
git add panel/auth.py tests/test_auth.py
git commit -m "feat(panel): argon2id, session signée HMAC, création du compte admin"
```

---

## Task 7: `panel/security.py` — session courante, CSRF, `Origin`, rate limiting

**Files:**
- Create: `panel/security.py`, `tests/test_security.py`

**Interfaces:**
- Consumes: `panel.auth.read_session`, `panel.settings`, une connexion Redis.
- Produces (dépendances FastAPI) :
  - `current_user(request, session) -> User` — 401 si pas de session valide.
  - `require_csrf(request) -> None` — 403 si `Origin` absent/inconnu ou `X-CSRF-Token` absent/faux. Posée sur **toutes** les mutations.
  - `RateLimiter(redis, limite: int, fenetre: int)` avec `hit(cle: str) -> bool` (False = quota dépassé) et `reset(cle)`.
  - `set_session_cookie(response, payload)` / `clear_session_cookie(response)`.
  - `client_ip(request) -> str`.

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_security.py` :

```python
"""CSRF, Origin, rate limiting — la couche qui protège l'exécution de code."""
import fakeredis
import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from panel.auth import new_csrf_token, sign_session
from panel.security import RateLimiter, client_ip, require_csrf
from panel.settings import get_settings


@pytest.fixture
def app() -> FastAPI:
    a = FastAPI()

    @a.post("/mutation", dependencies=[Depends(require_csrf)])
    def mutation():
        return {"ok": True}

    @a.get("/lecture")
    def lecture():
        return {"ok": True}

    return a


@pytest.fixture
def client(app):
    return TestClient(app)


def _cookies(csrf: str) -> dict:
    return {get_settings().session_cookie_name: sign_session({"uid": 1, "csrf": csrf})}


def test_mutation_sans_token_csrf_est_rejetee(client):
    csrf = new_csrf_token()
    r = client.post("/mutation", cookies=_cookies(csrf),
                    headers={"Origin": "http://127.0.0.1:8080"})
    assert r.status_code == 403
    assert "csrf" in r.json()["detail"].lower()


def test_mutation_avec_un_mauvais_token_csrf_est_rejetee(client):
    csrf = new_csrf_token()
    r = client.post("/mutation", cookies=_cookies(csrf),
                    headers={"Origin": "http://127.0.0.1:8080",
                             "X-CSRF-Token": new_csrf_token()})
    assert r.status_code == 403


def test_mutation_avec_le_bon_token_passe(client):
    csrf = new_csrf_token()
    r = client.post("/mutation", cookies=_cookies(csrf),
                    headers={"Origin": "http://127.0.0.1:8080", "X-CSRF-Token": csrf})
    assert r.status_code == 200


def test_origin_etranger_est_rejete(client):
    csrf = new_csrf_token()
    r = client.post("/mutation", cookies=_cookies(csrf),
                    headers={"Origin": "https://evil.example", "X-CSRF-Token": csrf})
    assert r.status_code == 403
    assert "origin" in r.json()["detail"].lower()


def test_origin_absent_est_rejete(client):
    """Un formulaire POST cross-site envoie un Origin ; son ABSENCE vient d'un
    client non navigateur. On refuse : le panneau n'a pas de client non
    navigateur au jalon 2, et l'accepter rouvrirait la porte CSRF."""
    csrf = new_csrf_token()
    r = client.post("/mutation", cookies=_cookies(csrf), headers={"X-CSRF-Token": csrf})
    assert r.status_code == 403


def test_les_lectures_ne_sont_pas_soumises_au_csrf(client):
    assert client.get("/lecture").status_code == 200


def test_rate_limiter_bloque_a_la_sixieme_tentative():
    r = fakeredis.FakeStrictRedis()
    limiteur = RateLimiter(r, limite=5, fenetre=300)
    assert [limiteur.hit("1.2.3.4") for _ in range(5)] == [True] * 5
    assert limiteur.hit("1.2.3.4") is False
    assert limiteur.hit("5.6.7.8") is True          # cloisonné par IP


def test_rate_limiter_expire():
    r = fakeredis.FakeStrictRedis()
    limiteur = RateLimiter(r, limite=1, fenetre=300)
    assert limiteur.hit("1.2.3.4") is True
    assert limiteur.hit("1.2.3.4") is False
    assert r.ttl("ratelimit:1.2.3.4") > 0           # la fenêtre est bien posée
    limiteur.reset("1.2.3.4")
    assert limiteur.hit("1.2.3.4") is True


def test_client_ip_prend_le_premier_x_forwarded_for():
    """Le panneau tourne derrière BunkerWeb : sans ça, toutes les tentatives
    de login viennent de l'IP du proxy et le rate limiting est inopérant."""
    from starlette.requests import Request

    scope = {"type": "http", "headers": [(b"x-forwarded-for", b"9.9.9.9, 10.0.0.1")],
             "client": ("10.0.0.1", 1234)}
    assert client_ip(Request(scope)) == "9.9.9.9"
```

- [ ] **Step 2: Implémenter `panel/security.py`**

```python
"""Dépendances de sécurité de l'API.

Point contre-intuitif et central : une authentification posée à l'edge
(BunkerWeb, auth_basic) NE PROTÈGE PAS du CSRF. Le navigateur de la victime
enverra ses identifiants avec la requête forgée. D'où le triptyque appliqué à
toute mutation : session valide + Origin reconnu + token CSRF lié à la session.
"""
from urllib.parse import urlparse

from fastapi import Depends, HTTPException, Request, status
from redis import Redis
from sqlmodel import Session

from panel.auth import read_session
from panel.db import get_session
from panel.models import User
from panel.settings import get_settings

MUTATIONS = {"POST", "PUT", "PATCH", "DELETE"}


def client_ip(request: Request) -> str:
    """L'IP réelle du client, derrière un reverse proxy de confiance.

    Le panneau n'est joignable que sur 127.0.0.1 : le seul émetteur possible
    de X-Forwarded-For est BunkerWeb. Dans une topologie où le port serait
    exposé plus largement, cet en-tête deviendrait falsifiable et il faudrait
    une liste de proxys de confiance — c'est écrit dans docs/PANEL.md.
    """
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()
    return request.client.host if request.client else "inconnue"


def session_payload(request: Request) -> dict | None:
    return read_session(request.cookies.get(get_settings().session_cookie_name))


def current_user(request: Request, session: Session = Depends(get_session)) -> User:
    payload = session_payload(request)
    if not payload or "uid" not in payload:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "authentification requise")
    user = session.get(User, payload["uid"])
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "session obsolète")
    return user


def _origin_autorisee(origin: str) -> bool:
    autorisees = {o.rstrip("/") for o in get_settings().allowed_origins}
    if origin.rstrip("/") in autorisees:
        return True
    # Tolérance de port pour le développement local : 127.0.0.1 et localhost
    # sont la même machine, et le port du panneau est réglable.
    parsed = urlparse(origin)
    return any(parsed.hostname == urlparse(a).hostname and parsed.scheme == urlparse(a).scheme
               for a in autorisees)


def require_csrf(request: Request) -> None:
    """Posée sur TOUTES les mutations, y compris /login et /logout."""
    if request.method not in MUTATIONS:
        return
    origin = request.headers.get("origin")
    if not origin or not _origin_autorisee(origin):
        raise HTTPException(status.HTTP_403_FORBIDDEN,
                            f"origin refusé : {origin or '<absent>'}")
    payload = session_payload(request)
    attendu = (payload or {}).get("csrf")
    fourni = request.headers.get("x-csrf-token") or ""
    if not attendu or not fourni or not _egal(attendu, fourni):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "token CSRF absent ou invalide")


def _egal(a: str, b: str) -> bool:
    import hmac

    return hmac.compare_digest(a, b)


class RateLimiter:
    """Compteur à fenêtre fixe dans Redis : INCR + EXPIRE au premier passage.

    Fenêtre fixe et pas glissante : 5 tentatives / 5 minutes autorise au pire
    10 tentatives à cheval sur deux fenêtres. Contre un mot de passe argon2 de
    12 caractères minimum, la différence est sans intérêt pratique, et le coût
    d'une fenêtre glissante (ZSET, purge) ne se justifie pas ici.
    """

    def __init__(self, redis: Redis, limite: int, fenetre: int) -> None:
        self._redis, self._limite, self._fenetre = redis, limite, fenetre

    def hit(self, cle: str) -> bool:
        rkey = f"ratelimit:{cle}"
        pipe = self._redis.pipeline()
        pipe.incr(rkey)
        pipe.expire(rkey, self._fenetre, nx=True)   # nx : ne repousse pas la fenêtre
        compte, _ = pipe.execute()
        return int(compte) <= self._limite

    def reset(self, cle: str) -> None:
        self._redis.delete(f"ratelimit:{cle}")


def set_session_cookie(response, payload: dict) -> None:
    from panel.auth import sign_session

    s = get_settings()
    response.set_cookie(
        key=s.session_cookie_name,
        value=sign_session(payload),
        max_age=s.session_max_age_seconds,
        httponly=True,          # inaccessible au JS : un XSS ne vole pas la session
        samesite="strict",      # aucune requête cross-site n'emporte le cookie
        secure=s.cookie_secure, # cf. docs/PANEL.md pour le cas http://127.0.0.1
        path="/",
    )


def clear_session_cookie(response) -> None:
    response.delete_cookie(get_settings().session_cookie_name, path="/")
```

- [ ] **Step 3: Voir vert, puis vérifier par mutation**

```bash
.venv/bin/python -m pytest tests/test_security.py -q   # attendu : 9 passed
```

C'est le test de sécurité le plus important du jalon. Chaque mutation ci-dessous doit faire rougir la ligne indiquée ; si l'une passe au vert, le test correspondant ne prouve rien :

| Mutation | Assertion qui doit rougir |
|---|---|
| `require_csrf` → `return` immédiat | les 4 premiers tests |
| retirer la vérification d'`Origin` | `test_origin_etranger_est_rejete`, `test_origin_absent_est_rejete` |
| accepter un `Origin` absent (`if origin and not _origin_autorisee(origin)`) | `test_origin_absent_est_rejete` |
| comparer `attendu == fourni` sans exiger `attendu` non vide | `test_mutation_sans_token_csrf_est_rejetee` |
| `MUTATIONS` réduit à `{"DELETE"}` | les 4 premiers tests |
| `hit()` → `return True` | `test_rate_limiter_bloque_a_la_sixieme_tentative` |
| `expire(..., nx=True)` → `expire(...)` | aucune — **écart connu**, la fenêtre glissante par repoussement n'est pas testable sans horloge simulée. À noter en revue. |
| `client_ip` renvoyant `request.client.host` d'abord | `test_client_ip_prend_le_premier_x_forwarded_for` |

- [ ] **Step 4: Commit**

```bash
git add panel/security.py tests/test_security.py
git commit -m "feat(panel): CSRF, vérification d'Origin, rate limiting Redis, cookie de session durci"
```

---

## Task 8: `panel/api/app.py` — application FastAPI, `lifespan`, `/healthz`, `/readyz`

**Files:**
- Create: `panel/api/__init__.py`, `panel/api/app.py`, `panel/api/deps.py`, `tests/test_api_health.py`
- Modify: `tests/conftest.py` (fixture `client`)

**Interfaces:**
- Consumes: `panel.db.create_all`, `panel.auth.ensure_admin_user`, `panel.worker.reconcile.reconcile_stale_runs` (Task 17 — jusque-là, un import paresseux dans le `lifespan` avec un `try/ImportError` explicite est **interdit** : implémenter la Task 17 avant celle-ci, ou poser une fonction vide temporaire et la remplacer dans la même branche).
- Produces:
  - `create_app() -> FastAPI`
  - `app = create_app()` (cible de gunicorn : `panel.api.app:app`)
  - `deps.get_redis() -> Redis`, `deps.get_queue() -> rq.Queue`
  - `GET /healthz` → `{"status": "ok"}` sans dépendance ; `GET /readyz` → 200 si Postgres **et** Redis répondent, 503 sinon, corps `{"database": bool, "redis": bool}`.

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_api_health.py` :

```python
"""Sondes de santé : /healthz sans dépendance, /readyz avec."""
from fastapi.testclient import TestClient


def test_healthz_ne_depend_de_rien(client: TestClient):
    r = client.get("/healthz")
    assert r.status_code == 200 and r.json()["status"] == "ok"


def test_healthz_ne_demande_pas_dauthentification(client: TestClient):
    """Le healthcheck Docker n'a pas de session : s'il prenait un 401, le
    conteneur serait déclaré unhealthy et depends_on ne démarrerait jamais."""
    assert "cookie" not in {h.lower() for h in client.get("/healthz").request.headers}
    assert client.get("/healthz").status_code == 200


def test_readyz_signale_les_dependances(client: TestClient):
    r = client.get("/readyz")
    assert r.status_code in (200, 503)
    assert set(r.json()) == {"database", "redis"}


def test_une_route_protegee_repond_401_sans_session(client: TestClient):
    """Critère d'acceptation n°2 du jalon 2."""
    assert client.get("/api/apps").status_code == 401
```

- [ ] **Step 2: Implémenter `panel/api/deps.py`**

```python
"""Dépendances partagées : Redis et la file RQ.

Une seule connexion Redis par processus, créée paresseusement. rq.Queue n'est
pas thread-safe pour l'écriture concurrente d'un même job, mais `enqueue` l'est
— chaque appel ouvre sa propre transaction Redis.
"""
from functools import lru_cache

from redis import Redis
from rq import Queue

from panel.settings import get_settings

QUEUE_NAME = "deploymatic"


@lru_cache
def get_redis() -> Redis:
    return Redis.from_url(get_settings().redis_url)


@lru_cache
def get_queue() -> Queue:
    return Queue(QUEUE_NAME, connection=get_redis(),
                 default_timeout=get_settings().run_timeout_seconds + 120)
```

Le `+ 120` : le timeout RQ doit être **plus grand** que le timeout applicatif du run, sinon RQ tue le job avant que le runner ait pu écrire `failed` en base — et on retombe exactement sur le run bloqué en `running` que la réconciliation existe pour rattraper.

- [ ] **Step 3: Implémenter `panel/api/app.py`**

```python
"""Création de l'application FastAPI."""
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy import text

from panel.api import deps
from panel.auth import ensure_admin_user
from panel.db import create_all, engine, session_scope
from panel.settings import REPO_ROOT
from panel.worker.reconcile import reconcile_stale_runs

log = logging.getLogger("panel")


@asynccontextmanager
async def lifespan(app: FastAPI):
    create_all()
    with session_scope() as session:
        if ensure_admin_user(session) is not None:
            log.warning("compte admin créé depuis PANEL_ADMIN_PASSWORD")
        # D4, appel n°1 sur 2 : redémarrer le panneau seul doit suffire à
        # débloquer des runs orphelins. L'appel n°2 est dans le worker.
        orphelins = reconcile_stale_runs(session, deps.get_redis())
    if orphelins:
        log.warning("réconciliation : %d run(s) orphelin(s) marqué(s) failed : %s",
                    len(orphelins), orphelins)
    yield


def create_app() -> FastAPI:
    from panel.api import routes_apps, routes_auth, routes_runs, routes_targets, routes_ui

    app = FastAPI(title="DeployMatic", lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)
    # docs_url=None : le panneau n'est pas une API publique, et /docs exposerait
    # la surface complète à quiconque atteint le port avant de s'authentifier.

    app.mount("/static", StaticFiles(directory=REPO_ROOT / "panel" / "static"), name="static")

    @app.get("/healthz")
    def healthz() -> dict:
        """Le processus répond. Aucune dépendance : c'est le healthcheck Docker."""
        return {"status": "ok"}

    @app.get("/readyz")
    def readyz() -> JSONResponse:
        """Les dépendances répondent. C'est ce que regarde depends_on."""
        etat = {"database": False, "redis": False}
        try:
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            etat["database"] = True
        except Exception:
            log.exception("readyz : base injoignable")
        try:
            etat["redis"] = bool(deps.get_redis().ping())
        except Exception:
            log.exception("readyz : redis injoignable")
        code = 200 if all(etat.values()) else 503
        return JSONResponse(etat, status_code=code)

    app.include_router(routes_auth.router)
    app.include_router(routes_targets.router)
    app.include_router(routes_apps.router)
    app.include_router(routes_runs.router)
    app.include_router(routes_ui.router)
    return app


app = create_app()
```

- [ ] **Step 4: Ajouter la fixture `client` à `tests/conftest.py`**

```python
@pytest.fixture
def client(monkeypatch, tmp_path):
    """Application complète sur SQLite + fakeredis, sans conteneur."""
    import fakeredis
    from fastapi.testclient import TestClient

    monkeypatch.setenv("PANEL_DATABASE_URL", f"sqlite:///{tmp_path/'panel.db'}")
    from panel.settings import get_settings
    get_settings.cache_clear()

    import panel.db as db
    from sqlmodel import create_engine
    db.engine = create_engine(get_settings().database_url,
                              connect_args={"check_same_thread": False})

    from panel.api import deps
    deps.get_redis.cache_clear()
    deps.get_queue.cache_clear()
    monkeypatch.setattr(deps, "get_redis", lambda: fakeredis.FakeStrictRedis())

    from panel.api.app import create_app
    with TestClient(create_app()) as c:
        yield c
    get_settings.cache_clear()
```

- [ ] **Step 5: Voir vert**

```bash
.venv/bin/python -m pytest tests/test_api_health.py -q   # attendu : 4 passed
```

- [ ] **Step 6: Commit**

```bash
git add panel/api/ tests/test_api_health.py tests/conftest.py
git commit -m "feat(panel): application FastAPI, lifespan (schéma, admin, réconciliation), /healthz et /readyz"
```

---

## Task 9: `panel/api/routes_auth.py` — `/login`, `/logout`, rate limiting effectif

**Files:**
- Create: `panel/api/routes_auth.py`, `panel/api/schemas.py`, `tests/test_api_auth.py`

**Interfaces:**
- Consumes: `panel.auth`, `panel.security`, `panel.api.deps.get_redis`.
- Produces:
  - `POST /api/login` — corps `LoginIn{username: str, password: str}` → 204 + cookie de session ; 401 identifiants invalides ; 429 quota dépassé.
  - `POST /api/logout` — 204, cookie effacé. Exige CSRF comme toute mutation.
  - `GET /api/csrf` — `{"csrf": "<token>"}`, pose une session anonyme si nécessaire : c'est ce que le formulaire de login lit avant de poster.
  - `schemas.LoginIn`, `schemas.TargetIn/Out`, `schemas.AppIn/Out`, `schemas.RunOut`, `schemas.StepOut`.

**Le point non évident** : `/login` est une mutation, donc soumise à `require_csrf` — mais un visiteur sans session n'a pas encore de token CSRF. D'où `GET /api/csrf`, qui pose un cookie de session **anonyme** (payload `{"csrf": …}` sans `uid`) et renvoie le token. La session anonyme ne donne accès à rien : `current_user` exige `uid`. Une connexion réussie remplace le cookie par une session `{"uid": …, "csrf": …}` avec un **nouveau** token CSRF — la rotation à l'élévation de privilège évite la fixation de session.

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_api_auth.py` :

```python
"""Cycle de connexion, rejet CSRF, rate limiting, rotation de session."""
from fastapi.testclient import TestClient

ORIGIN = {"Origin": "http://127.0.0.1:8080"}
MDP = "motdepasse-de-test-1234"


def _csrf(client: TestClient) -> str:
    return client.get("/api/csrf").json()["csrf"]


def test_login_puis_acces_a_une_route_protegee(client: TestClient):
    csrf = _csrf(client)
    r = client.post("/api/login", json={"username": "admin", "password": MDP},
                    headers={**ORIGIN, "X-CSRF-Token": csrf})
    assert r.status_code == 204
    assert client.get("/api/apps").status_code == 200


def test_mauvais_mot_de_passe(client: TestClient):
    csrf = _csrf(client)
    r = client.post("/api/login", json={"username": "admin", "password": "faux"},
                    headers={**ORIGIN, "X-CSRF-Token": csrf})
    assert r.status_code == 401
    assert client.get("/api/apps").status_code == 401


def test_login_sans_csrf_est_rejete(client: TestClient):
    r = client.post("/api/login", json={"username": "admin", "password": MDP},
                    headers=ORIGIN)
    assert r.status_code == 403


def test_le_token_csrf_change_apres_connexion(client: TestClient):
    """Anti-fixation : le token posé avant l'authentification ne doit plus
    être valide après."""
    avant = _csrf(client)
    client.post("/api/login", json={"username": "admin", "password": MDP},
                headers={**ORIGIN, "X-CSRF-Token": avant})
    apres = _csrf(client)
    assert apres != avant
    r = client.post("/api/logout", headers={**ORIGIN, "X-CSRF-Token": avant})
    assert r.status_code == 403


def test_logout_invalide_la_session(client: TestClient):
    csrf = _csrf(client)
    client.post("/api/login", json={"username": "admin", "password": MDP},
                headers={**ORIGIN, "X-CSRF-Token": csrf})
    csrf = _csrf(client)
    assert client.post("/api/logout",
                       headers={**ORIGIN, "X-CSRF-Token": csrf}).status_code == 204
    assert client.get("/api/apps").status_code == 401


def test_rate_limiting_sur_login(client: TestClient):
    """5 tentatives / 5 min / IP. La 6e est refusée même avec le BON mot de
    passe : c'est ce qui rend le quota utile."""
    for _ in range(5):
        csrf = _csrf(client)
        r = client.post("/api/login", json={"username": "admin", "password": "faux"},
                        headers={**ORIGIN, "X-CSRF-Token": csrf})
        assert r.status_code == 401
    csrf = _csrf(client)
    r = client.post("/api/login", json={"username": "admin", "password": MDP},
                    headers={**ORIGIN, "X-CSRF-Token": csrf})
    assert r.status_code == 429
    assert r.headers.get("retry-after")


def test_le_mot_de_passe_napparait_dans_aucune_reponse(client: TestClient):
    csrf = _csrf(client)
    r = client.post("/api/login", json={"username": "admin", "password": MDP},
                    headers={**ORIGIN, "X-CSRF-Token": csrf})
    assert MDP not in r.text
```

- [ ] **Step 2: Implémenter `panel/api/schemas.py`** (le strict nécessaire ici, complété aux Tasks 10-11 et 18)

```python
"""Schémas d'entrée/sortie de l'API.

Règle unique et non négociable : AUCUN schéma de sortie ne porte un champ
secret. Les modèles SQLModel ne sont jamais renvoyés directement — un `*_enc`
oublié dans une réponse est une fuite, et `response_model` est ce qui l'empêche.
"""
from datetime import datetime

from pydantic import BaseModel, Field

from panel.models import AppStatus, AuthMethod, RunStatus, StepKind, StepStatus
from panel.spec import AppSpec


class LoginIn(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=1024)


class TargetIn(BaseModel):
    name: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
    host: str = Field(min_length=1, max_length=255)
    port: int = Field(default=22, ge=1, le=65535)
    ssh_user: str = Field(min_length=1, max_length=64)
    auth_method: AuthMethod = AuthMethod.KEY
    ssh_key_path: str | None = None
    password: str | None = Field(default=None, max_length=1024)   # chiffré à l'entrée
    bind_addr: str = "0.0.0.0"
    is_local: bool = False


class TargetOut(BaseModel):
    id: int
    name: str
    host: str
    port: int
    ssh_user: str
    auth_method: AuthMethod
    bind_addr: str
    is_local: bool
    created_at: datetime
    # ni password, ni password_enc : ils ne sortent jamais.


class AppIn(BaseModel):
    target_id: int
    spec: AppSpec
    env: dict[str, str] = Field(default_factory=dict)
    ports: dict[str, int] = Field(default_factory=dict)   # jalon 3 : allocateur
    registry_user: str | None = None
    registry_token: str | None = None                     # chiffré à l'entrée
    github_enabled: bool = False
    github_user: str | None = None
    github_repo: str | None = None
    github_token: str | None = None                       # chiffré à l'entrée


class AppOut(BaseModel):
    id: int
    name: str
    target_id: int
    status: AppStatus
    spec: dict
    env: dict
    created_at: datetime
    updated_at: datetime


class StepOut(BaseModel):
    name: str
    ordinal: int
    kind: StepKind
    status: StepStatus
    attempts: int
    exit_code: int | None
    error: str | None
    started_at: datetime | None
    finished_at: datetime | None


class RunOut(BaseModel):
    id: int
    app_id: int
    status: RunStatus
    error: str | None
    started_at: datetime | None
    finished_at: datetime | None
    steps: list[StepOut]
```

- [ ] **Step 3: Implémenter `panel/api/routes_auth.py`**

```python
"""Connexion, déconnexion, distribution du token CSRF."""
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from sqlmodel import Session, select

from panel.api import deps
from panel.api.schemas import LoginIn
from panel.auth import new_csrf_token, verify_password
from panel.db import get_session
from panel.models import User
from panel.security import (RateLimiter, clear_session_cookie, client_ip,
                            require_csrf, session_payload, set_session_cookie)
from panel.settings import get_settings

router = APIRouter(prefix="/api", tags=["auth"])


@router.get("/csrf")
def csrf(request: Request, response: Response) -> dict:
    """Renvoie le token CSRF de la session courante, en en posant une (anonyme)
    si nécessaire. Une session anonyme ne donne accès à rien : current_user
    exige `uid`."""
    payload = session_payload(request) or {}
    if "csrf" not in payload:
        payload = {**payload, "csrf": new_csrf_token()}
        set_session_cookie(response, payload)
    return {"csrf": payload["csrf"]}


@router.post("/login", status_code=status.HTTP_204_NO_CONTENT,
             dependencies=[Depends(require_csrf)])
def login(corps: LoginIn, request: Request, response: Response,
          session: Session = Depends(get_session)) -> Response:
    settings = get_settings()
    limite, fenetre = settings.login_rate_limit
    limiteur = RateLimiter(deps.get_redis(), limite=limite, fenetre=fenetre)
    ip = client_ip(request)
    if not limiteur.hit(f"login:{ip}"):
        # Le quota s'applique AVANT la vérification du mot de passe : sinon une
        # tentative valide « consommerait » le blocage et le rendrait
        # contournable en alternant les mots de passe.
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS,
                            "trop de tentatives, réessayez plus tard",
                            headers={"Retry-After": str(fenetre)})

    user = session.exec(select(User).where(User.username == corps.username)).first()
    if user is None or not verify_password(user.password_hash, corps.password):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "identifiants invalides")

    limiteur.reset(f"login:{ip}")
    user.last_login = datetime.now(timezone.utc)
    session.add(user)
    session.commit()
    # Rotation du token CSRF à l'élévation de privilège (anti-fixation).
    set_session_cookie(response, {"uid": user.id, "csrf": new_csrf_token()})
    response.status_code = status.HTTP_204_NO_CONTENT
    return response


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT,
             dependencies=[Depends(require_csrf)])
def logout(response: Response) -> Response:
    clear_session_cookie(response)
    response.status_code = status.HTTP_204_NO_CONTENT
    return response
```

- [ ] **Step 4: Voir vert, puis vérifier par mutation**

```bash
.venv/bin/python -m pytest tests/test_api_auth.py -q   # attendu : 7 passed
```

| Mutation | Assertion qui doit rougir |
|---|---|
| déplacer `limiteur.hit(...)` **après** la vérification du mot de passe | `test_rate_limiting_sur_login` (la 6e tentative avec le bon mot de passe passerait) |
| `verify_password(...)` → `True` | `test_mauvais_mot_de_passe` |
| retirer `Depends(require_csrf)` de `/login` | `test_login_sans_csrf_est_rejete` |
| réutiliser l'ancien token CSRF à la connexion | `test_le_token_csrf_change_apres_connexion` |
| `clear_session_cookie` → `pass` | `test_logout_invalide_la_session` |

- [ ] **Step 5: Commit**

```bash
git add panel/api/routes_auth.py panel/api/schemas.py tests/test_api_auth.py
git commit -m "feat(panel): /login, /logout, /csrf avec rate limiting et rotation de session"
```

---

## Task 10: `panel/api/routes_targets.py` — cibles et test de connexion SSH

**Files:**
- Create: `panel/api/routes_targets.py`, `tests/test_api_targets.py`

**Interfaces:**
- Consumes: `schemas.TargetIn/TargetOut`, `panel.crypto.encrypt_optional`, `panel.security.current_user`, `require_csrf`.
- Produces:
  - `GET /api/targets` → `list[TargetOut]`
  - `POST /api/targets` → 201 `TargetOut` ; teste la connexion SSH **avant** d'insérer, 400 avec le message de l'erreur si elle échoue
  - `DELETE /api/targets/{id}` → 204 ; 409 si une application la référence
  - `panel.ssh_check.tester_connexion(target: Target, password: str | None) -> dict` — `{"ok": bool, "detail": str, "docker": str | None}`

**Décision** : le test de connexion tourne dans le processus **panel**, pas dans le worker. C'est une opération de moins de 10 secondes, synchrone, dont le résultat doit s'afficher dans le formulaire ; passer par une file la rendrait asynchrone pour rien. C'est la **seule** commande externe que le panneau lance — et elle ne lance ni build ni déploiement. Le worker garde le monopole de l'exécution des runs.

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_api_targets.py` :

```python
"""Cibles : création avec test SSH, secrets non renvoyés, suppression protégée."""
import pytest

ORIGIN = {"Origin": "http://127.0.0.1:8080"}
MDP = "motdepasse-de-test-1234"


@pytest.fixture
def connecte(client):
    csrf = client.get("/api/csrf").json()["csrf"]
    client.post("/api/login", json={"username": "admin", "password": MDP},
                headers={**ORIGIN, "X-CSRF-Token": csrf})
    client.headers.update({**ORIGIN, "X-CSRF-Token": client.get("/api/csrf").json()["csrf"]})
    return client


def _cible(**kw) -> dict:
    base = {"name": "vm-test", "host": "127.0.0.1", "port": 60122,
            "ssh_user": "devops", "auth_method": "key",
            "ssh_key_path": "/secrets/id_ed25519"}
    base.update(kw)
    return base


def test_creation_avec_ssh_ok(connecte, monkeypatch):
    import panel.ssh_check as ssh_check
    monkeypatch.setattr(ssh_check, "tester_connexion",
                        lambda *a, **k: {"ok": True, "detail": "ok", "docker": "27.3.1"})
    r = connecte.post("/api/targets", json=_cible())
    assert r.status_code == 201
    assert r.json()["port"] == 60122


def test_ssh_en_echec_nenregistre_rien(connecte, monkeypatch):
    import panel.ssh_check as ssh_check
    monkeypatch.setattr(ssh_check, "tester_connexion",
                        lambda *a, **k: {"ok": False, "detail": "Permission denied", "docker": None})
    r = connecte.post("/api/targets", json=_cible())
    assert r.status_code == 400
    assert "Permission denied" in r.json()["detail"]
    assert connecte.get("/api/targets").json() == []


def test_le_mot_de_passe_est_chiffre_et_jamais_renvoye(connecte, monkeypatch):
    import panel.ssh_check as ssh_check
    monkeypatch.setattr(ssh_check, "tester_connexion",
                        lambda *a, **k: {"ok": True, "detail": "ok", "docker": "27.3.1"})
    r = connecte.post("/api/targets",
                      json=_cible(auth_method="password", ssh_key_path=None,
                                  password="secret-ssh-en-clair"))
    assert r.status_code == 201
    assert "secret-ssh-en-clair" not in r.text
    assert "password" not in r.json()

    from sqlalchemy import text
    import panel.db as db
    with db.engine.connect() as conn:
        brut = str(conn.execute(text("SELECT * FROM target")).all())
    assert "secret-ssh-en-clair" not in brut


def test_creation_sans_authentification(client):
    assert client.post("/api/targets", json=_cible()).status_code == 401


def test_suppression_refusee_si_une_app_la_reference(connecte, monkeypatch):
    import panel.ssh_check as ssh_check
    monkeypatch.setattr(ssh_check, "tester_connexion",
                        lambda *a, **k: {"ok": True, "detail": "ok", "docker": "27.3.1"})
    cible = connecte.post("/api/targets", json=_cible()).json()
    connecte.post("/api/apps", json={
        "target_id": cible["id"],
        "spec": {"name": "mon-app", "services": [
            {"id": "api", "build": "./services/api", "port": 3000,
             "health": "/health", "expose": "/api/"}]}})
    r = connecte.delete(f"/api/targets/{cible['id']}")
    assert r.status_code == 409
```

- [ ] **Step 2: Implémenter `panel/ssh_check.py`**

```python
"""Test de connexion à une cible — SSH, puis version de Docker et de Compose.

Aucune commande n'est construite par concaténation de chaîne : subprocess reçoit
une LISTE, il n'y a pas de shell, et un hôte nommé `; rm -rf /` n'est qu'un nom
d'hôte que ssh ne résoudra pas.
"""
import subprocess

from panel.models import AuthMethod, Target

TIMEOUT = 15


def tester_connexion(target: Target, password: str | None = None) -> dict:
    if target.auth_method is AuthMethod.PASSWORD:
        if not password:
            return {"ok": False, "detail": "mot de passe requis", "docker": None}
        base = ["sshpass", "-e", "ssh", "-p", str(target.port),
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "PreferredAuthentications=password",
                "-o", "PubkeyAuthentication=no"]
        env = {"SSHPASS": password}
    else:
        if not target.ssh_key_path:
            return {"ok": False, "detail": "chemin de clé SSH requis", "docker": None}
        base = ["ssh", "-i", target.ssh_key_path, "-p", str(target.port),
                "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"]
        env = {}

    cible = f"{target.ssh_user}@{target.host}"
    cmd = [*base, "-o", f"ConnectTimeout={TIMEOUT}", cible,
           "docker version --format '{{.Server.Version}}' 2>/dev/null || echo ABSENT"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              timeout=TIMEOUT + 10, env={**env, "PATH": "/usr/bin:/bin"})
    except subprocess.TimeoutExpired:
        return {"ok": False, "detail": f"délai dépassé ({TIMEOUT}s)", "docker": None}
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip().splitlines()[-1:] or ["échec SSH"]
        return {"ok": False, "detail": detail[0], "docker": None}
    version = proc.stdout.strip()
    if version == "ABSENT":
        # Pas une erreur : prepare_server installera Docker. On le signale.
        return {"ok": True, "detail": "SSH ok, Docker absent (prepare_server l'installera)",
                "docker": None}
    return {"ok": True, "detail": f"SSH ok, Docker {version}", "docker": version}
```

- [ ] **Step 3: Implémenter `panel/api/routes_targets.py`**

```python
"""Cibles de déploiement."""
from fastapi import APIRouter, Depends, HTTPException, status
from sqlmodel import Session, select

import panel.ssh_check as ssh_check
from panel.api.schemas import TargetIn, TargetOut
from panel.crypto import encrypt_optional
from panel.db import get_session
from panel.models import App, Target, User
from panel.security import current_user, require_csrf

router = APIRouter(prefix="/api/targets", tags=["targets"])


@router.get("", response_model=list[TargetOut])
def lister(session: Session = Depends(get_session),
           _: User = Depends(current_user)) -> list[Target]:
    return list(session.exec(select(Target).order_by(Target.name)))


@router.post("", response_model=TargetOut, status_code=status.HTTP_201_CREATED,
             dependencies=[Depends(require_csrf)])
def creer(corps: TargetIn, session: Session = Depends(get_session),
          _: User = Depends(current_user)) -> Target:
    if session.exec(select(Target).where(Target.name == corps.name)).first():
        raise HTTPException(status.HTTP_409_CONFLICT,
                            f"une cible nommée '{corps.name}' existe déjà")
    cible = Target(**corps.model_dump(exclude={"password"}),
                   password_enc=encrypt_optional(corps.password))
    resultat = ssh_check.tester_connexion(cible, corps.password)
    if not resultat["ok"]:
        # Rien n'est inséré : une cible injoignable en base n'a aucune valeur,
        # et un run qui la viserait échouerait à validate_ssh de toute façon.
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            f"connexion impossible : {resultat['detail']}")
    session.add(cible)
    session.commit()
    session.refresh(cible)
    return cible


@router.delete("/{target_id}", status_code=status.HTTP_204_NO_CONTENT,
               dependencies=[Depends(require_csrf)])
def supprimer(target_id: int, session: Session = Depends(get_session),
              _: User = Depends(current_user)) -> None:
    cible = session.get(Target, target_id)
    if cible is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "cible inconnue")
    if session.exec(select(App).where(App.target_id == target_id)).first():
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            "cible référencée par au moins une application : la destruction "
            "d'application arrive au jalon 3, supprimez l'application d'abord")
    session.delete(cible)
    session.commit()
```

- [ ] **Step 4: Voir vert**

```bash
.venv/bin/python -m pytest tests/test_api_targets.py -q   # attendu : 5 passed
```

- [ ] **Step 5: Commit**

```bash
git add panel/ssh_check.py panel/api/routes_targets.py tests/test_api_targets.py
git commit -m "feat(panel): CRUD des cibles avec test de connexion SSH et mot de passe chiffré"
```

---

## Task 11: `panel/api/routes_apps.py` — applications et mise en file d'un run

**Files:**
- Create: `panel/api/routes_apps.py`, `tests/test_api_apps.py`

**Interfaces:**
- Consumes: `schemas.AppIn/AppOut`, `panel.spec.AppSpec`, `panel.api.deps.get_queue`.
- Produces:
  - `GET /api/apps` → `list[AppOut]`
  - `POST /api/apps` → 201 `AppOut` ; 422 si le nom ou le spec est invalide ; 409 si le nom existe déjà
  - `GET /api/apps/{id}` → `AppOut`, 404 sinon
  - `POST /api/apps/{id}/deploy` → 202 `{"run_id": int}` ; 409 si un run de cette app est déjà `queued`/`running`

**Verrou d'unicité de run** : au jalon 2, un seul run actif par application, garanti par une requête `SELECT … WHERE app_id = ? AND status IN ('queued','running')` dans la même transaction que l'insertion. C'est suffisant pour un panneau mono-instance ; le vrai verrou en base (jalon 3, « un seul run actif par app ») remplacera cette garde quand plusieurs workers tourneront en parallèle. **À écrire dans le code en commentaire, pour que personne ne prenne cette garde pour un verrou.**

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_api_apps.py` :

```python
"""Applications : validation du nom (D5), secrets chiffrés, mise en file d'un run."""
import pytest

ORIGIN = {"Origin": "http://127.0.0.1:8080"}
MDP = "motdepasse-de-test-1234"
SPEC = {"name": "mon-app", "services": [
    {"id": "api", "build": "./services/api", "port": 3000,
     "health": "/health", "expose": "/api/"}]}


@pytest.fixture
def connecte(client, monkeypatch):
    import panel.ssh_check as ssh_check
    monkeypatch.setattr(ssh_check, "tester_connexion",
                        lambda *a, **k: {"ok": True, "detail": "ok", "docker": "27.3.1"})
    csrf = client.get("/api/csrf").json()["csrf"]
    client.post("/api/login", json={"username": "admin", "password": MDP},
                headers={**ORIGIN, "X-CSRF-Token": csrf})
    client.headers.update({**ORIGIN, "X-CSRF-Token": client.get("/api/csrf").json()["csrf"]})
    client.post("/api/targets", json={"name": "vm", "host": "127.0.0.1", "port": 60122,
                                      "ssh_user": "devops", "auth_method": "key",
                                      "ssh_key_path": "/secrets/id_ed25519"})
    return client


@pytest.mark.parametrize("nom", ["../foo", "..", "/etc/passwd", "A_b", "1app", "a" * 32,
                                 "mon app", "mon;app", "mon.app"])
def test_nom_dapplication_invalide_est_rejete(connecte, nom):
    """Critère d'acceptation n°4 du jalon 2, et correctif définitif du point
    n°4 de la dette technique (--workspace ../../foo)."""
    r = connecte.post("/api/apps", json={"target_id": 1, "spec": {**SPEC, "name": nom}})
    assert r.status_code == 422, f"{nom!r} accepté !"


def test_creation_puis_lecture(connecte):
    r = connecte.post("/api/apps", json={"target_id": 1, "spec": SPEC})
    assert r.status_code == 201
    app_id = r.json()["id"]
    assert connecte.get(f"/api/apps/{app_id}").json()["name"] == "mon-app"
    assert connecte.get("/api/apps").json()[0]["status"] == "new"


def test_nom_deja_pris(connecte):
    connecte.post("/api/apps", json={"target_id": 1, "spec": SPEC})
    assert connecte.post("/api/apps", json={"target_id": 1, "spec": SPEC}).status_code == 409


def test_les_tokens_sont_chiffres_et_jamais_renvoyes(connecte):
    r = connecte.post("/api/apps", json={"target_id": 1, "spec": SPEC,
                                         "registry_user": "moi",
                                         "registry_token": "dckr_pat_ultrasecret"})
    assert r.status_code == 201
    assert "dckr_pat_ultrasecret" not in r.text
    from sqlalchemy import text
    import panel.db as db
    with db.engine.connect() as conn:
        brut = str(conn.execute(text("SELECT * FROM app")).all())
    assert "dckr_pat_ultrasecret" not in brut          # critère d'acceptation n°7


def test_deploy_met_un_run_en_file(connecte):
    app_id = connecte.post("/api/apps", json={"target_id": 1, "spec": SPEC}).json()["id"]
    r = connecte.post(f"/api/apps/{app_id}/deploy")
    assert r.status_code == 202
    run_id = r.json()["run_id"]
    detail = connecte.get(f"/api/runs/{run_id}").json()
    assert detail["status"] == "queued"
    # Les lignes Step sont créées à la mise en file, pas par le worker : l'UI
    # doit pouvoir afficher la liste complète avant que le worker démarre.
    assert [s["name"] for s in detail["steps"]][0] == "prepare_workspace"
    assert all(s["status"] == "pending" for s in detail["steps"])


def test_un_seul_run_actif_par_application(connecte):
    app_id = connecte.post("/api/apps", json={"target_id": 1, "spec": SPEC}).json()["id"]
    assert connecte.post(f"/api/apps/{app_id}/deploy").status_code == 202
    assert connecte.post(f"/api/apps/{app_id}/deploy").status_code == 409


def test_deploy_sans_authentification(client):
    assert client.post("/api/apps/1/deploy").status_code == 401
```

- [ ] **Step 2: Implémenter `panel/api/routes_apps.py`**

```python
"""Applications et déclenchement de run."""
import json
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlmodel import Session, select

from panel.api import deps
from panel.api.schemas import AppIn, AppOut
from panel.crypto import encrypt
from panel.db import get_session
from panel.models import App, Run, RunStatus, RunTrigger, Step, StepStatus, Target, User
from panel.pipeline import PIPELINE
from panel.security import current_user, require_csrf

router = APIRouter(prefix="/api/apps", tags=["apps"])
ACTIFS = (RunStatus.QUEUED, RunStatus.RUNNING)


@router.get("", response_model=list[AppOut])
def lister(session: Session = Depends(get_session),
           _: User = Depends(current_user)) -> list[App]:
    return list(session.exec(select(App).order_by(App.name)))


@router.post("", response_model=AppOut, status_code=status.HTTP_201_CREATED,
             dependencies=[Depends(require_csrf)])
def creer(corps: AppIn, session: Session = Depends(get_session),
          _: User = Depends(current_user)) -> App:
    # corps.spec est un AppSpec : le nom a DÉJÀ été validé par Pydantic contre
    # ^[a-z][a-z0-9-]{1,30}$ (D5). Une requête avec "../foo" n'arrive jamais ici,
    # elle est refusée en 422 par FastAPI avant d'entrer dans la fonction.
    if session.get(Target, corps.target_id) is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "cible inconnue")
    if session.exec(select(App).where(App.name == corps.spec.name)).first():
        raise HTTPException(status.HTTP_409_CONFLICT,
                            f"une application nommée '{corps.spec.name}' existe déjà")

    secrets = {k: v for k, v in {"registry_token": corps.registry_token,
                                 "github_token": corps.github_token}.items() if v}
    app = App(
        name=corps.spec.name,
        target_id=corps.target_id,
        spec=corps.spec.to_engine_json(),
        env={"vars": corps.env, "ports": corps.ports,
             "registry_user": corps.registry_user or "",
             "github": {"enabled": corps.github_enabled,
                        "user": corps.github_user or "",
                        "repo": corps.github_repo or ""}},
        secrets_enc=encrypt(json.dumps(secrets)) if secrets else None,
    )
    session.add(app)
    session.commit()
    session.refresh(app)
    return app


@router.get("/{app_id}", response_model=AppOut)
def lire(app_id: int, session: Session = Depends(get_session),
         _: User = Depends(current_user)) -> App:
    app = session.get(App, app_id)
    if app is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "application inconnue")
    return app


@router.post("/{app_id}/deploy", status_code=status.HTTP_202_ACCEPTED,
             dependencies=[Depends(require_csrf)])
def deployer(app_id: int, session: Session = Depends(get_session),
             _: User = Depends(current_user)) -> dict:
    app = session.get(App, app_id)
    if app is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "application inconnue")

    # Garde d'unicité, PAS un verrou : deux requêtes simultanées sur un panneau
    # multi-instances pourraient toutes deux passer. Le verrou en base arrive au
    # jalon 3 (« un seul run actif par app »), en même temps que le besoin réel.
    if session.exec(select(Run).where(Run.app_id == app_id,
                                      Run.status.in_(ACTIFS))).first():
        raise HTTPException(status.HTTP_409_CONFLICT,
                            "un run est déjà en cours pour cette application")

    run = Run(app_id=app_id, trigger=RunTrigger.MANUAL, status=RunStatus.QUEUED)
    session.add(run)
    session.commit()
    session.refresh(run)

    # Les Step sont créées ICI, pas par le worker : l'UI affiche la liste
    # complète des étapes dès la mise en file, y compris si le worker est à
    # l'arrêt — ce qui est justement le cas qu'il faut pouvoir diagnostiquer.
    for ordinal, definition in enumerate(PIPELINE):
        session.add(Step(run_id=run.id, name=definition.name, ordinal=ordinal,
                         kind=definition.kind, status=StepStatus.PENDING))
    app.updated_at = datetime.now(timezone.utc)
    session.add(app)
    session.commit()

    job = deps.get_queue().enqueue("panel.worker.runner.execute_run", run.id,
                                   job_id=f"run-{run.id}")
    run.rq_job_id = job.id            # D4 : sans ça, la réconciliation est aveugle
    session.add(run)
    session.commit()
    return {"run_id": run.id}
```

- [ ] **Step 3: Voir vert, puis vérifier par mutation**

```bash
.venv/bin/python -m pytest tests/test_api_apps.py -q   # attendu : 15 passed
```

| Mutation | Assertion qui doit rougir |
|---|---|
| `spec: AppSpec` → `spec: dict` dans `AppIn` | les 9 cas de `test_nom_dapplication_invalide_est_rejete` |
| retirer le `Depends(current_user)` de `deployer` | `test_deploy_sans_authentification` |
| supprimer la garde d'unicité de run | `test_un_seul_run_actif_par_application` |
| `secrets_enc=json.dumps(secrets)` (sans `encrypt`) | `test_les_tokens_sont_chiffres_et_jamais_renvoyes` |
| `response_model=AppOut` → suppression | à vérifier à la main : la réponse porterait `secrets_enc` |

- [ ] **Step 4: Commit**

```bash
git add panel/api/routes_apps.py tests/test_api_apps.py
git commit -m "feat(panel): CRUD des applications et mise en file d'un run avec ses étapes"
```

---

## Task 12: `panel/runspace.py` — matérialisation de `runs/<slug>/`

**Files:**
- Create: `panel/runspace.py`, `tests/test_runspace.py`

**Interfaces:**
- Consumes: `panel.spec.valider_nom_application`, `panel.crypto.decrypt`, `panel.settings.get_settings().runs_dir`, les modèles `App` / `Target`.
- Produces:
  - `workspace_dir(nom: str) -> Path` — refuse tout nom non conforme **avant** de construire le chemin, et vérifie que le résultat est bien sous `runs_dir` après résolution.
  - `build_env_json(app: App, target: Target) -> dict` — contrat **C4**, secrets déchiffrés.
  - `write_workspace(app: App, target: Target) -> Path` — crée `runs/<slug>/` en 700, écrit `spec.json` et `env.json` en 600, écriture atomique.
  - `cleanup_secrets(nom: str) -> None` — supprime `env.json` en fin de run (D3).

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_runspace.py` :

```python
"""Écriture du workspace : chemins, permissions, contrat env.json, secrets."""
import json
import os
import stat

import pytest

from panel.crypto import encrypt
from panel.models import App, AuthMethod, Target
from panel.runspace import build_env_json, cleanup_secrets, workspace_dir, write_workspace

SPEC = {"name": "mon-app", "services": [
    {"id": "api", "build": "./services/api", "port": 3000,
     "health": "/health", "expose": "/api/"}]}


def _app() -> App:
    return App(id=1, name="mon-app", target_id=1, spec=SPEC,
               env={"vars": {"NODE_ENV": "production"}, "ports": {"api": 10001},
                    "registry_user": "moi",
                    "github": {"enabled": False, "user": "", "repo": ""}},
               secrets_enc=encrypt(json.dumps({"registry_token": "dckr_pat_secret"})))


def _target() -> Target:
    return Target(id=1, name="vm", host="127.0.0.1", port=60122, ssh_user="devops",
                  auth_method=AuthMethod.KEY, ssh_key_path="/secrets/id_ed25519",
                  bind_addr="0.0.0.0")


@pytest.mark.parametrize("nom", ["../etc", "..", "/etc", "mon app", "A_b", "",
                                 "mon-app/../autre", "mon-app\x00"])
def test_workspace_dir_refuse_tout_nom_non_conforme(tmp_runs, nom):
    with pytest.raises(ValueError):
        workspace_dir(nom)


def test_workspace_dir_reste_sous_runs(tmp_runs):
    assert workspace_dir("mon-app").parent == tmp_runs.resolve()


def test_env_json_est_le_contrat_c4(tmp_runs):
    env = build_env_json(_app(), _target())
    assert set(env) == {"app", "target", "registry", "github", "ports", "limits", "options"}
    assert env["target"] == {"host": "127.0.0.1", "port": 60122, "user": "devops",
                             "auth_method": "key",
                             "ssh_key_path": "/secrets/id_ed25519", "password": "",
                             "bind_addr": "0.0.0.0"}
    assert env["ports"] == {"api": 10001}
    assert env["registry"]["token"] == "dckr_pat_secret"      # déchiffré ICI, et ici seulement
    assert env["github"]["enabled"] is False


def test_permissions_et_contenu(tmp_runs):
    ws = write_workspace(_app(), _target())
    assert stat.S_IMODE(os.stat(ws).st_mode) == 0o700
    for nom in ("env.json", "spec.json"):
        assert stat.S_IMODE(os.stat(ws / nom).st_mode) == 0o600
    assert json.loads((ws / "spec.json").read_text()) == SPEC


def test_reecriture_est_idempotente(tmp_runs):
    ws1 = write_workspace(_app(), _target())
    (ws1 / "mon-app").mkdir()                    # simule le travail de l'engine
    ws2 = write_workspace(_app(), _target())
    assert ws1 == ws2
    assert (ws2 / "mon-app").is_dir()            # le travail de l'engine survit


def test_cleanup_supprime_env_json_et_pas_le_reste(tmp_runs):
    ws = write_workspace(_app(), _target())
    cleanup_secrets("mon-app")
    assert not (ws / "env.json").exists()
    assert (ws / "spec.json").exists()
    cleanup_secrets("mon-app")                   # deux fois : ne lève pas
```

- [ ] **Step 2: Implémenter `panel/runspace.py`**

```python
"""Matérialisation de runs/<slug>/ — l'unique endroit où un secret redevient clair.

Ce module tourne dans le processus WORKER. Le processus panel ne l'importe pas :
c'est ce qui rend vrai « les secrets ne sortent qu'au moment d'écrire env.json ».

Contrat C4 : la forme d'env.json est celle que lit engine/lib/config.sh (cfg,
cfg_req, cfg_bool, cfg_port). Toute clé ajoutée ici doit avoir un lecteur là-bas.
"""
import json
import os
from pathlib import Path

from panel.crypto import decrypt
from panel.models import App, AuthMethod, Target
from panel.settings import get_settings
from panel.spec import valider_nom_application


def workspace_dir(nom: str) -> Path:
    """Le chemin du workspace, ou ValueError. Deux gardes, volontairement.

    1. La regex (D5) : le nom est validé AVANT toute construction de chemin.
    2. La vérification de confinement après résolution : elle rattraperait un
       lien symbolique posé dans runs/ par un autre processus — ce que la regex
       seule ne peut pas voir.
    """
    valider_nom_application(nom)
    racine = get_settings().runs_dir.resolve()
    chemin = (racine / nom).resolve()
    if chemin.parent != racine:
        raise ValueError(f"chemin de workspace hors de runs/ : {chemin}")
    return chemin


def build_env_json(app: App, target: Target) -> dict:
    """Contrat C4. Les secrets sont déchiffrés ici, en mémoire, et n'existent
    en clair que le temps d'être sérialisés dans un fichier en 600."""
    secrets = json.loads(decrypt(app.secrets_enc)) if app.secrets_enc else {}
    env = app.env or {}
    github = env.get("github", {})
    return {
        "app": {"name": app.name, "author": ""},
        "target": {
            "host": target.host,
            "port": target.port,
            "user": target.ssh_user,
            "auth_method": target.auth_method.value,
            "ssh_key_path": target.ssh_key_path or "",
            "password": decrypt(target.password_enc) if target.password_enc else "",
            "bind_addr": target.bind_addr,
        },
        "registry": {"user": env.get("registry_user", ""),
                     "token": secrets.get("registry_token", "")},
        "github": {"enabled": bool(github.get("enabled", False)),
                   "user": github.get("user", ""),
                   "repo": github.get("repo", ""),
                   "token": secrets.get("github_token", "")},
        "ports": env.get("ports", {}),
        # Unités Kubernetes : conservées telles quelles, engine/lib/units.sh
        # convertit (200m → 0.2, 128Mi → 128m). Cf. docs/ARCHITECTURE.md §8.
        "limits": env.get("limits", {"cpu": "200m", "memory": "128Mi"}),
        "options": {"reuse_existing_dir": True, "allow_existing_repo": True},
    }


def _ecrire_600(chemin: Path, contenu: str) -> None:
    """Écriture atomique en 600 : le fichier n'existe jamais en 644, même une
    fraction de seconde. os.open + O_CREAT avec le mode voulu, puis rename."""
    temporaire = chemin.with_suffix(chemin.suffix + ".tmp")
    fd = os.open(temporaire, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(contenu)
            f.flush()
            os.fsync(f.fileno())
    except Exception:
        temporaire.unlink(missing_ok=True)
        raise
    os.replace(temporaire, chemin)
    os.chmod(chemin, 0o600)


def write_workspace(app: App, target: Target) -> Path:
    ws = workspace_dir(app.name)
    racine = get_settings().runs_dir
    racine.mkdir(mode=0o700, parents=True, exist_ok=True)
    ws.mkdir(mode=0o700, exist_ok=True)
    os.chmod(ws, 0o700)     # mkdir(exist_ok=True) n'applique pas le mode si le
                            # répertoire existe déjà : un run précédent aurait pu
                            # être créé sous un umask différent.
    _ecrire_600(ws / "spec.json", json.dumps(app.spec, indent=2, ensure_ascii=False))
    _ecrire_600(ws / "env.json",
                json.dumps(build_env_json(app, target), indent=2, ensure_ascii=False))
    return ws


def cleanup_secrets(nom: str) -> None:
    """D3 : env.json disparaît en fin de run. Le volume runs/ est partagé entre
    panel et worker ; y laisser des tokens en clair entre deux runs n'apporte
    rien et élargit la surface. spec.json, lui, reste : il n'a rien de secret et
    la destruction du jalon 3 en aura besoin."""
    try:
        (workspace_dir(nom) / "env.json").unlink(missing_ok=True)
    except ValueError:
        pass      # nom invalide : il n'y a rien à nettoyer
```

- [ ] **Step 3: Voir vert, puis vérifier par mutation**

```bash
.venv/bin/python -m pytest tests/test_runspace.py -q   # attendu : 13 passed
```

| Mutation | Assertion qui doit rougir |
|---|---|
| retirer `valider_nom_application(nom)` de `workspace_dir` | `test_workspace_dir_refuse_tout_nom_non_conforme["../etc"]` |
| retirer la vérification `chemin.parent != racine` | ajouter un test avec un lien symbolique, ou **accepter et le noter** : la regex couvre déjà tous les cas atteignables par l'API |
| `_ecrire_600` → `chemin.write_text(...)` | `test_permissions_et_contenu` |
| `os.chmod(ws, 0o700)` supprimé | à vérifier avec un umask 022 : `test_permissions_et_contenu` sur un répertoire préexistant |
| `cleanup_secrets` supprimant tout le répertoire | `test_cleanup_supprime_env_json_et_pas_le_reste` |

- [ ] **Step 4: Commit**

```bash
git add panel/runspace.py tests/test_runspace.py
git commit -m "feat(panel): écriture de runs/<slug>/ en 600, contrat env.json, nettoyage des secrets"
```

---

## Task 13: `panel/worker/logbus.py` — journal fichier + Redis pub/sub

**Files:**
- Create: `panel/worker/__init__.py`, `panel/worker/logbus.py`, `tests/test_logbus.py`

**Interfaces:**
- Consumes: une connexion Redis, `settings.runs_dir`.
- Produces:
  - `canal(run_id: int) -> str` → `"run:<id>:logs"`
  - `strip_ansi(ligne: str) -> str`
  - `class LogBus` : `__init__(redis, run_id, log_path: Path)`, `emit_log(step: str, ligne: str)`, `emit_event(type: str, **champs)`, `close()`, utilisable en gestionnaire de contexte.
  - Chaque message publié est une ligne JSON : `{"t": "log"|"step"|"run", "step": str|None, "line": str|None, "status": str|None, "ts": float}`.

**Pourquoi un fichier ET Redis** : Redis pub/sub ne conserve rien. Un utilisateur qui ouvre la page d'un run après coup doit voir les logs — d'où le fichier `runs/<slug>/logs/<run_id>-<step>.log`, que le SSE relit avant de s'abonner. Cette relecture, c'est la Task 18.

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_logbus.py` :

```python
"""Journal : nettoyage ANSI, écriture fichier, publication Redis."""
import json

import fakeredis

from panel.worker.logbus import LogBus, canal, strip_ansi


def test_strip_ansi():
    assert strip_ansi("\x1b[32m✓\x1b[0m Docker présent") == "✓ Docker présent"
    assert strip_ansi("\x1b[1;31mErreur\x1b[0m") == "Erreur"
    assert strip_ansi("rien à nettoyer") == "rien à nettoyer"
    assert strip_ansi("\x1b[2K\x1b[1Gprogression") == "progression"


def test_les_logs_partent_dans_le_fichier_et_dans_redis(tmp_path):
    r = fakeredis.FakeStrictRedis()
    pubsub = r.pubsub()
    pubsub.subscribe(canal(7))
    pubsub.get_message(timeout=1)                       # message de souscription

    chemin = tmp_path / "run.log"
    with LogBus(r, run_id=7, log_path=chemin) as bus:
        bus.emit_log("check_prereqs", "\x1b[32m✓\x1b[0m jq présent")
        bus.emit_event("step", step="check_prereqs", status="ok")

    contenu = chemin.read_text()
    assert "✓ jq présent" in contenu
    assert "\x1b[" not in contenu                        # l'ANSI est nettoyé À L'ÉCRITURE

    messages = []
    while (m := pubsub.get_message(timeout=0.5)):
        if m["type"] == "message":
            messages.append(json.loads(m["data"]))
    assert messages[0]["t"] == "log" and messages[0]["line"] == "✓ jq présent"
    assert messages[1]["t"] == "step" and messages[1]["status"] == "ok"


def test_une_panne_redis_ninterrompt_pas_le_run(tmp_path, monkeypatch):
    """Le journal est de l'observabilité, pas du déploiement. Si Redis tombe,
    le run doit continuer et le fichier rester complet."""
    class RedisCasse:
        def publish(self, *a, **k):
            raise ConnectionError("redis down")

    chemin = tmp_path / "run.log"
    with LogBus(RedisCasse(), run_id=7, log_path=chemin) as bus:
        bus.emit_log("etape", "une ligne")
    assert "une ligne" in chemin.read_text()


def test_le_fichier_est_cree_avec_ses_parents(tmp_path):
    chemin = tmp_path / "logs" / "sous" / "run.log"
    with LogBus(fakeredis.FakeStrictRedis(), run_id=1, log_path=chemin) as bus:
        bus.emit_log("e", "x")
    assert chemin.exists()
```

- [ ] **Step 2: Implémenter `panel/worker/logbus.py`**

```python
"""Diffusion des logs d'un run : fichier durable + Redis pub/sub temps réel.

Les deux ne servent pas la même chose. Redis pub/sub ne CONSERVE rien : c'est
le flux temps réel que le SSE consomme. Le fichier est ce que lit quelqu'un qui
ouvre la page d'un run terminé. Les deux reçoivent la MÊME ligne, déjà nettoyée
de ses séquences ANSI — l'engine colore ses sorties, et ces codes n'ont aucun
sens dans un <pre> HTML.
"""
import json
import re
import time
from pathlib import Path
from typing import Any

# Séquences CSI, OSC et codes à un caractère. Volontairement large : mieux vaut
# retirer une séquence exotique que la voir s'afficher telle quelle dans l'UI.
_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")


def strip_ansi(ligne: str) -> str:
    return _ANSI.sub("", ligne)


def canal(run_id: int) -> str:
    return f"run:{run_id}:logs"


class LogBus:
    def __init__(self, redis: Any, run_id: int, log_path: Path) -> None:
        self._redis = redis
        self._canal = canal(run_id)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        self._fichier = open(log_path, "a", encoding="utf-8", buffering=1)  # ligne à ligne

    def emit_log(self, step: str, ligne: str) -> None:
        propre = strip_ansi(ligne.rstrip("\n"))
        self._fichier.write(f"[{step}] {propre}\n")
        self._publier({"t": "log", "step": step, "line": propre})

    def emit_event(self, type_: str, **champs: Any) -> None:
        self._publier({"t": type_, **champs})

    def _publier(self, message: dict) -> None:
        message["ts"] = time.time()
        try:
            self._redis.publish(self._canal, json.dumps(message, ensure_ascii=False))
        except Exception:
            # Une panne de Redis dégrade l'affichage temps réel ; elle ne doit
            # jamais faire échouer un déploiement en cours. Le fichier reste la
            # source de vérité.
            pass

    def close(self) -> None:
        try:
            self._fichier.close()
        except Exception:
            pass

    def __enter__(self) -> "LogBus":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()
```

- [ ] **Step 3: Voir vert**

```bash
.venv/bin/python -m pytest tests/test_logbus.py -q   # attendu : 4 passed
```

- [ ] **Step 4: Commit**

```bash
git add panel/worker/logbus.py panel/worker/__init__.py tests/test_logbus.py
git commit -m "feat(worker): journal de run — fichier durable et publication Redis, ANSI nettoyé"
```

---

## Task 14: `panel/worker/engine.py` — invocation d'UNE étape de l'engine

**Files:**
- Create: `panel/worker/engine.py`, `tests/fixtures/fake_engine.sh`, `tests/test_engine_call.py`

**Interfaces:**
- Consumes: `settings.engine_path`, `settings.step_timeout_seconds`, `LogBus`.
- Produces:
  - `@dataclass StepResult(ok: bool, exit_code: int, data: dict | None, error: str | None)`
  - `run_engine_step(workspace: str, step: str, bus: LogBus, timeout: int | None = None, engine_path: Path | None = None) -> StepResult`

**C'est le point de contact avec le contrat C1. Cinq exigences, chacune testée :**
1. stderr est lu **au fil de l'eau** et poussé dans le `LogBus` — pas à la fin, sinon les logs « en direct » arrivent tous d'un coup.
2. stdout est lu en entier à la fin et sa **dernière ligne non vide** est parsée en JSON. stdout ne dépasse jamais quelques centaines d'octets, très en dessous des 64 Kio du tube : le lire après la fin du processus ne peut pas provoquer d'interblocage. Cette hypothèse est **écrite dans le code**, parce que le jour où une étape se met à écrire massivement sur stdout, elle cesse d'être vraie.
3. Le code de sortie est rendu tel quel : `0` / `1` / `2`. La décision de réessayer appartient au runner, pas à ce module.
4. Une sortie sans ligne JSON parsable est un **échec fatal** (code 2 en interne) : le contrat est rompu, réessayer n'a aucun sens.
5. Le dépassement du timeout tue le **groupe de processus** (`start_new_session=True` + `killpg`), pas seulement bash — sinon un `ssh` enfant survit et garde le tube ouvert.

- [ ] **Step 1: Écrire le faux engine, scriptable**

Créer `tests/fixtures/fake_engine.sh` :

```bash
#!/usr/bin/env bash
# Faux engine : reproduit le contrat C1 à la demande, pour tester le worker
# sans cible SSH. Piloté par la variable FAKE_MODE.
#
#   ok        3 lignes de log sur stderr, {"ok":true,...} sur stdout, code 0
#   retry     log + {"ok":false,...}, code 1
#   fatal     log + {"ok":false,...}, code 2
#   silence   des logs, AUCUNE ligne JSON, code 0  (contrat rompu)
#   bruit     deux lignes JSON sur stdout          (contrat rompu)
#   lent      boucle infinie                       (test du timeout)
#   ansi      une ligne de log colorée
set -uo pipefail
STEP=""
while (( $# > 0 )); do
  case "$1" in
    --step) STEP="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "${FAKE_MODE:-ok}" in
  ok)      printf 'début %s\n' "$STEP" >&2; printf 'travail\n' >&2
           printf '{"ok":true,"data":{"step":"%s"}}\n' "$STEP"; exit 0 ;;
  retry)   printf 'connexion refusée\n' >&2
           printf '{"ok":false,"error":"connexion refusée"}\n'; exit 1 ;;
  fatal)   printf 'configuration invalide\n' >&2
           printf '{"ok":false,"error":"configuration invalide"}\n'; exit 2 ;;
  silence) printf 'je travaille\n' >&2; exit 0 ;;
  bruit)   printf '{"ok":true,"data":{}}\n'; printf '{"ok":true,"data":{"second":1}}\n'; exit 0 ;;
  lent)    printf 'je pars pour longtemps\n' >&2; sleep 300; exit 0 ;;
  ansi)    printf '\033[32m✓\033[0m tout va bien\n' >&2
           printf '{"ok":true,"data":null}\n'; exit 0 ;;
esac
```

- [ ] **Step 2: Écrire le test**

Créer `tests/test_engine_call.py` :

```python
"""Contrat C1, vu du worker : une ligne JSON, des logs, trois codes."""
import time
from pathlib import Path

import fakeredis
import pytest

from panel.worker.engine import run_engine_step
from panel.worker.logbus import LogBus

FAKE = Path(__file__).parent / "fixtures" / "fake_engine.sh"


@pytest.fixture
def bus(tmp_path):
    with LogBus(fakeredis.FakeStrictRedis(), 1, tmp_path / "run.log") as b:
        yield b


def _appel(mode: str, bus, monkeypatch, **kw):
    monkeypatch.setenv("FAKE_MODE", mode)
    return run_engine_step("mon-app", "check_prereqs", bus, engine_path=FAKE, **kw)


def test_succes(bus, monkeypatch, tmp_path):
    r = _appel("ok", bus, monkeypatch)
    assert (r.ok, r.exit_code, r.data) == (True, 0, {"step": "check_prereqs"})
    assert r.error is None


def test_les_logs_stderr_arrivent_dans_le_bus(bus, monkeypatch, tmp_path):
    _appel("ok", bus, monkeypatch)
    bus.close()
    contenu = (tmp_path / "run.log").read_text()
    assert "début check_prereqs" in contenu and "travail" in contenu
    assert "{" not in contenu          # la ligne JSON de stdout n'est PAS un log


def test_echec_reessayable(bus, monkeypatch):
    r = _appel("retry", bus, monkeypatch)
    assert (r.ok, r.exit_code) == (False, 1)
    assert r.error == "connexion refusée"


def test_echec_fatal(bus, monkeypatch):
    r = _appel("fatal", bus, monkeypatch)
    assert (r.ok, r.exit_code) == (False, 2)
    assert r.error == "configuration invalide"


def test_absence_de_ligne_json_est_fatale(bus, monkeypatch):
    """Contrat rompu : réessayer une étape qui ne respecte pas le protocole ne
    peut pas mieux se passer la deuxième fois."""
    r = _appel("silence", bus, monkeypatch)
    assert (r.ok, r.exit_code) == (False, 2)
    assert "aucune ligne de résultat" in r.error


def test_plusieurs_lignes_json_la_derniere_gagne(bus, monkeypatch):
    r = _appel("bruit", bus, monkeypatch)
    assert r.ok and r.data == {"second": 1}


def test_timeout_tue_le_groupe_de_processus(bus, monkeypatch):
    debut = time.monotonic()
    r = _appel("lent", bus, monkeypatch, timeout=2)
    assert (r.ok, r.exit_code) == (False, 2)
    assert "délai" in r.error
    assert time.monotonic() - debut < 10


def test_ansi_nettoye_dans_le_journal(bus, monkeypatch, tmp_path):
    _appel("ansi", bus, monkeypatch)
    bus.close()
    assert "\x1b[" not in (tmp_path / "run.log").read_text()


def test_le_workspace_est_passe_tel_quel_en_argument(bus, monkeypatch):
    """Aucune interpolation shell : subprocess reçoit une liste. Un nom exotique
    ne peut pas devenir une commande — et de toute façon il n'arrive jamais
    jusqu'ici (D5)."""
    monkeypatch.setenv("FAKE_MODE", "ok")
    r = run_engine_step("mon-app", "check_prereqs", bus, engine_path=FAKE)
    assert r.ok
```

- [ ] **Step 3: Implémenter `panel/worker/engine.py`**

```python
"""Invocation d'UNE étape de l'engine — le point de contact avec le contrat C1.

    engine/bootstrap.sh --workspace <ws> --step <nom>
    stderr = logs · stdout = UNE ligne JSON · codes 0 succès / 1 réessayable / 2 fatal

Ce module ne décide RIEN : il exécute, il traduit, il rend un StepResult. La
politique de retry appartient au runner.
"""
import json
import os
import signal
import subprocess
from dataclasses import dataclass
from pathlib import Path

from panel.settings import get_settings
from panel.worker.logbus import LogBus

FATAL = 2


@dataclass(frozen=True, slots=True)
class StepResult:
    ok: bool
    exit_code: int
    data: dict | None = None
    error: str | None = None


def _env_minimal() -> dict[str, str]:
    """L'engine n'hérite QUE de ce dont il a besoin. PANEL_SECRET_KEY,
    DATABASE_URL et consorts n'ont rien à faire dans l'environnement d'un
    subprocess qui lance ssh — ni dans son /proc/<pid>/environ."""
    garde = ("PATH", "HOME", "LANG", "LC_ALL", "TERM", "SSH_AUTH_SOCK", "FAKE_MODE")
    env = {k: v for k, v in os.environ.items() if k in garde}
    env.setdefault("PATH", "/usr/local/bin:/usr/bin:/bin")
    env.setdefault("LC_ALL", "C")   # cf. CONVENTIONS.md §8 : la locale fr_FR
                                    # produisait "0,200" au lieu de "0.200"
    return env


def run_engine_step(workspace: str, step: str, bus: LogBus,
                    timeout: int | None = None,
                    engine_path: Path | None = None) -> StepResult:
    chemin = engine_path or get_settings().engine_path
    delai = timeout if timeout is not None else get_settings().step_timeout_seconds
    cmd = ["bash", str(chemin), "--workspace", workspace, "--step", step]

    proc = subprocess.Popen(
        cmd, cwd=str(Path(chemin).resolve().parent.parent),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1, env=_env_minimal(),
        start_new_session=True,   # groupe de processus dédié : le timeout doit
                                  # pouvoir tuer ssh/docker enfants, pas que bash
    )

    # stderr est lu AU FIL DE L'EAU : c'est ce qui fait des « logs en direct »
    # autre chose qu'une promesse. stdout n'est lu qu'à la fin — le contrat
    # garantit UNE ligne de quelques centaines d'octets, très en dessous des
    # 64 Kio du tube, donc aucun risque d'interblocage. Si une étape se mettait
    # à écrire massivement sur stdout, elle violerait le contrat ET ce code.
    try:
        assert proc.stderr is not None
        for ligne in proc.stderr:
            bus.emit_log(step, ligne)
        proc.wait(timeout=delai)
    except subprocess.TimeoutExpired:
        _tuer(proc)
        return StepResult(False, FATAL,
                          error=f"délai dépassé pour l'étape '{step}' ({delai}s)")
    finally:
        if proc.stderr:
            proc.stderr.close()

    sortie = proc.stdout.read() if proc.stdout else ""
    if proc.stdout:
        proc.stdout.close()
    return _interpreter(step, sortie, proc.returncode)


def _tuer(proc: subprocess.Popen) -> None:
    """SIGTERM au groupe, puis SIGKILL. Tuer proc seul laisserait ssh en vie."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(os.getpgid(proc.pid), sig)
            proc.wait(timeout=5)
            return
        except (ProcessLookupError, PermissionError):
            return
        except subprocess.TimeoutExpired:
            continue


def _interpreter(step: str, sortie: str, code: int) -> StepResult:
    lignes = [l for l in sortie.splitlines() if l.strip()]
    resultat = None
    for ligne in reversed(lignes):      # la DERNIÈRE ligne JSON fait foi
        try:
            candidat = json.loads(ligne)
        except json.JSONDecodeError:
            continue
        if isinstance(candidat, dict) and "ok" in candidat:
            resultat = candidat
            break

    if resultat is None:
        # Contrat rompu. Fatal, jamais réessayable : une étape qui ne parle pas
        # le protocole ne le parlera pas mieux au deuxième essai.
        return StepResult(False, FATAL,
                          error=(f"contrat rompu par l'étape '{step}' : aucune ligne "
                                 f"de résultat JSON sur stdout (code {code})"))
    if resultat.get("ok") is True:
        return StepResult(True, code, data=resultat.get("data"))
    return StepResult(False, code or FATAL,
                      error=str(resultat.get("error", "échec sans message")))
```

- [ ] **Step 4: Voir vert, puis vérifier par mutation**

```bash
chmod +x tests/fixtures/fake_engine.sh
.venv/bin/python -m pytest tests/test_engine_call.py -q   # attendu : 9 passed
```

| Mutation | Assertion qui doit rougir |
|---|---|
| `resultat is None` → renvoyer `StepResult(True, 0)` | `test_absence_de_ligne_json_est_fatale` |
| itérer `lignes` au lieu de `reversed(lignes)` | `test_plusieurs_lignes_json_la_derniere_gagne` |
| `start_new_session=True` retiré + `proc.kill()` | difficile à faire rougir sans processus enfant réel — ajouter au faux engine un mode `enfant` qui lance `sleep 300 &`, et vérifier qu'aucun `sleep` ne survit |
| `proc.wait(timeout=delai)` sans timeout | `test_timeout_tue_le_groupe_de_processus` (le test bloquerait 300 s : le borner avec `pytest-timeout` ou le mode `lent` réglé à 30 s) |
| lire stderr après `proc.wait()` | `test_les_logs_stderr_arrivent_dans_le_bus` reste vert — **écart connu** : le caractère « au fil de l'eau » ne se prouve pas ainsi. Ajouter un mode `progressif` qui écrit une ligne, dort 1 s, écrit la suivante, et vérifier que la première est dans le bus avant la fin. |

- [ ] **Step 5: Commit**

```bash
git add panel/worker/engine.py tests/fixtures/fake_engine.sh tests/test_engine_call.py
git commit -m "feat(worker): invocation d'une étape de l'engine, contrat C1 respecté et testé"
```

---

## Task 15: `panel/worker/steps_py.py` — le registre des étapes Python (D1)

**Files:**
- Create: `panel/worker/steps_py.py`, `tests/test_steps_py.py`

**Interfaces:**
- Consumes: `panel.runspace.write_workspace`, `panel.worker.engine.StepResult`.
- Produces:
  - `@dataclass StepContext(app: App, target: Target, run_id: int, bus: LogBus, session: Session)`
  - `PYTHON_STEPS: dict[str, Callable[[StepContext], StepResult]]`
  - `@python_step("nom")` — décorateur d'enregistrement
  - `run_python_step(nom: str, ctx: StepContext) -> StepResult`
  - Implémentation `prepare_workspace`

**Le contrat d'une étape Python est le même que celui d'une étape engine** : elle rend un `StepResult`, écrit ses logs dans le `bus`, et n'a que trois issues — `ok`, réessayable (`exit_code=1`), fatale (`exit_code=2`). Une exception non rattrapée est traduite en échec fatal par `run_python_step`, jamais propagée jusqu'à RQ : sinon RQ marquerait le job `failed` sans que personne n'écrive quoi que ce soit dans `Run` ni dans `Step`, et on retomberait sur le run bloqué en `running`.

**C'est ici que le jalon 4 branchera** `register_bunkerweb`, `unregister_bunkerweb` et `validate_public` : trois `@python_step` de plus, zéro ligne à changer dans le runner, dans le modèle ou dans le SSE.

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_steps_py.py` :

```python
"""Le registre des étapes Python et la première d'entre elles."""
import json

import fakeredis
import pytest

from panel.models import App, AuthMethod, Target
from panel.worker.logbus import LogBus
from panel.worker.steps_py import (PYTHON_STEPS, StepContext, python_step,
                                   run_python_step)

SPEC = {"name": "mon-app", "services": [
    {"id": "api", "build": "./services/api", "port": 3000,
     "health": "/health", "expose": "/api/"}]}


@pytest.fixture
def ctx(tmp_path, tmp_runs):
    bus = LogBus(fakeredis.FakeStrictRedis(), 1, tmp_path / "run.log")
    app = App(id=1, name="mon-app", target_id=1, spec=SPEC,
              env={"ports": {"api": 10001}})
    target = Target(id=1, name="vm", host="127.0.0.1", ssh_user="devops",
                    auth_method=AuthMethod.KEY, ssh_key_path="/k")
    yield StepContext(app=app, target=target, run_id=1, bus=bus, session=None)
    bus.close()


def test_prepare_workspace_est_enregistree():
    assert "prepare_workspace" in PYTHON_STEPS


def test_prepare_workspace_ecrit_les_deux_fichiers(ctx, tmp_runs):
    r = run_python_step("prepare_workspace", ctx)
    assert r.ok and r.exit_code == 0
    ws = tmp_runs / "mon-app"
    assert json.loads((ws / "spec.json").read_text())["name"] == "mon-app"
    assert (ws / "env.json").exists()
    assert r.data["workspace"].endswith("mon-app")


def test_une_exception_devient_un_echec_fatal(ctx):
    @python_step("qui-explose")
    def _(_ctx):
        raise RuntimeError("bang")

    r = run_python_step("qui-explose", ctx)
    assert (r.ok, r.exit_code) == (False, 2)
    assert "bang" in r.error
    del PYTHON_STEPS["qui-explose"]


def test_une_etape_inconnue_est_un_echec_fatal(ctx):
    r = run_python_step("nexiste-pas", ctx)
    assert (r.ok, r.exit_code) == (False, 2)
    assert "inconnue" in r.error


def test_un_secret_najamais_sa_place_dans_le_message_derreur(ctx, tmp_runs, monkeypatch):
    """Une exception dont le message contiendrait un token ne doit pas finir
    dans Step.error, qui est affiché dans l'UI et lisible en base."""
    import panel.worker.steps_py as m

    def _explose(*a, **k):
        raise RuntimeError("échec en écrivant dckr_pat_ultrasecret")

    monkeypatch.setattr(m, "write_workspace", _explose)
    r = run_python_step("prepare_workspace", ctx)
    assert not r.ok
    assert "dckr_pat" not in r.error
```

- [ ] **Step 2: Implémenter `panel/worker/steps_py.py`**

```python
"""Étapes de nature `python` (D1).

Une étape Python respecte EXACTEMENT le même contrat qu'une étape de l'engine :
elle rend un StepResult, elle journalise dans le bus, elle a trois issues. La
différence est qu'elle tourne dans le processus worker et peut donc utiliser
les modules du panneau — ce que le contrat interdit formellement à l'engine.

Jalon 4 : register_bunkerweb / unregister_bunkerweb / validate_public
s'ajouteront ici, avec panel/bunkerweb.py. Le runner, le modèle et le SSE
n'auront rien à changer.
"""
import re
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from panel.models import App, Target
from panel.runspace import write_workspace
from panel.worker.engine import StepResult
from panel.worker.logbus import LogBus

FATAL = 2

# Motifs de secrets connus, retirés de tout message d'erreur avant qu'il
# n'atteigne Step.error (affiché dans l'UI, lisible en base).
_SECRETS = re.compile(r"(dckr_pat_[A-Za-z0-9_-]+|gh[pousr]_[A-Za-z0-9]{20,}|"
                      r"-----BEGIN [A-Z ]*PRIVATE KEY-----)")


def censurer(message: str) -> str:
    return _SECRETS.sub("[secret masqué]", message)


@dataclass(slots=True)
class StepContext:
    app: App
    target: Target
    run_id: int
    bus: LogBus
    session: Any            # sqlmodel.Session ; typé large pour éviter un import


PYTHON_STEPS: dict[str, Callable[[StepContext], StepResult]] = {}


def python_step(nom: str):
    def decorateur(fn: Callable[[StepContext], StepResult]):
        PYTHON_STEPS[nom] = fn
        return fn
    return decorateur


def run_python_step(nom: str, ctx: StepContext) -> StepResult:
    """Exécute une étape Python. Ne laisse JAMAIS remonter d'exception : une
    exception qui atteindrait RQ marquerait le job failed sans que personne
    n'ait écrit dans Run ni dans Step — le run resterait `running` pour
    toujours, exactement le défaut que D4 existe pour rattraper."""
    fn = PYTHON_STEPS.get(nom)
    if fn is None:
        return StepResult(False, FATAL, error=f"étape Python inconnue : {nom}")
    try:
        return fn(ctx)
    except Exception as exc:               # noqa: BLE001 — traduction volontaire
        ctx.bus.emit_log(nom, f"exception : {censurer(str(exc))}")
        return StepResult(False, FATAL,
                          error=censurer(f"{type(exc).__name__}: {exc}"))


@python_step("prepare_workspace")
def prepare_workspace(ctx: StepContext) -> StepResult:
    """Écrit runs/<slug>/spec.json et env.json en 600 (D3, D5).

    C'est la seule étape qui déchiffre des secrets, et elle tourne dans le
    worker. Le contenu d'env.json n'est JAMAIS journalisé.
    """
    ctx.bus.emit_log("prepare_workspace",
                     f"matérialisation du workspace '{ctx.app.name}'")
    ws = write_workspace(ctx.app, ctx.target)
    ctx.bus.emit_log("prepare_workspace",
                     "spec.json et env.json écrits en 600 (contenu non journalisé)")
    return StepResult(True, 0, data={"workspace": str(ws)})
```

- [ ] **Step 3: Voir vert**

```bash
.venv/bin/python -m pytest tests/test_steps_py.py -q   # attendu : 5 passed
```

- [ ] **Step 4: Commit**

```bash
git add panel/worker/steps_py.py tests/test_steps_py.py
git commit -m "feat(worker): registre des étapes Python et prepare_workspace"
```

---

## Task 16: `panel/worker/runner.py` — le job RQ : un job = un run

**Files:**
- Create: `panel/worker/runner.py`, `tests/test_runner.py`

**Interfaces:**
- Consumes: `PIPELINE`, `run_engine_step`, `run_python_step`, `LogBus`, `session_scope`, `cleanup_secrets`.
- Produces:
  - `execute_run(run_id: int) -> None` — la fonction que RQ appelle.
  - `doit_sauter(session, app_id: int, definition: StepDef, env: dict) -> str | None` — renvoie la raison du saut, ou `None`.
  - `log_path_for(app_name: str, run_id: int) -> Path`

**La boucle, dans l'ordre exact :**
1. `Run` → `running`, `started_at`, événement `run` sur le bus.
2. Pour chaque `StepDef` du `PIPELINE` :
   a. drapeau non satisfait (`requires_flag`) → `skipped`, raison journalisée ;
   b. `always_rerun=False` et un `Step` `ok` existe pour cette **application** → `skipped` (D2) ;
   c. sinon : `Step` → `running`, exécution selon `kind`, puis `ok` / `failed` ;
   d. `exit_code == 1` → **un** retry après `retry_backoff_seconds` (`attempts=1`), puis échec ;
   e. `exit_code == 2` → arrêt immédiat du run ;
   f. dépassement du timeout global de run → arrêt, `Run.error` explicite.
3. `finally` : statut final du `Run`, `finished_at`, `cleanup_secrets`, événement final sur le bus, fermeture du bus.

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_runner.py` :

```python
"""La boucle d'exécution d'un run : idempotence, retry, arrêt fatal, statuts."""
import pytest
from sqlmodel import Session, SQLModel, create_engine, select

from panel.models import (App, AppStatus, AuthMethod, Run, RunStatus, Step,
                          StepStatus, Target)
from panel.pipeline import PIPELINE
from panel.worker.engine import StepResult

SPEC = {"name": "mon-app", "services": [
    {"id": "api", "build": "./services/api", "port": 3000,
     "health": "/health", "expose": "/api/"}]}


@pytest.fixture
def base(monkeypatch, tmp_runs):
    import fakeredis
    import panel.db as db
    import panel.worker.runner as runner

    engine = create_engine("sqlite://", connect_args={"check_same_thread": False},
                           poolclass=__import__("sqlalchemy").pool.StaticPool)
    SQLModel.metadata.create_all(engine)
    monkeypatch.setattr(db, "engine", engine)
    monkeypatch.setattr(runner, "get_redis", lambda: fakeredis.FakeStrictRedis())
    with Session(engine) as s:
        s.add(Target(id=1, name="vm", host="127.0.0.1", ssh_user="devops",
                     auth_method=AuthMethod.KEY, ssh_key_path="/k"))
        s.add(App(id=1, name="mon-app", target_id=1, spec=SPEC, env={"ports": {"api": 10001}}))
        s.commit()
    return engine


def _nouveau_run(engine) -> int:
    from panel.models import StepKind
    with Session(engine) as s:
        run = Run(app_id=1, status=RunStatus.QUEUED, rq_job_id="job-x")
        s.add(run)
        s.commit()
        s.refresh(run)
        for i, d in enumerate(PIPELINE):
            s.add(Step(run_id=run.id, name=d.name, ordinal=i, kind=d.kind,
                       status=StepStatus.PENDING))
        s.commit()
        return run.id


def _tout_reussit(monkeypatch, appels: list):
    import panel.worker.runner as runner
    monkeypatch.setattr(runner, "run_engine_step",
                        lambda ws, nom, bus, **k: appels.append(nom) or StepResult(True, 0))


def test_run_complet_passe_ok(base, monkeypatch):
    import panel.worker.runner as runner
    appels: list[str] = []
    _tout_reussit(monkeypatch, appels)
    run_id = _nouveau_run(base)
    runner.execute_run(run_id)

    with Session(base) as s:
        run = s.get(Run, run_id)
        assert run.status is RunStatus.OK and run.finished_at is not None
        assert s.get(App, 1).status is AppStatus.DEPLOYED
        etapes = s.exec(select(Step).where(Step.run_id == run_id)).all()
        # Les 4 étapes github sont sautées : github.enabled est faux.
        assert sum(1 for e in etapes if e.status is StepStatus.SKIPPED) == 4
        assert "github_create_repo" not in appels


def test_code_2_arrete_le_run_immediatement(base, monkeypatch):
    import panel.worker.runner as runner
    appels: list[str] = []

    def faux(ws, nom, bus, **k):
        appels.append(nom)
        if nom == "validate_ssh":
            return StepResult(False, 2, error="clé refusée")
        return StepResult(True, 0)

    monkeypatch.setattr(runner, "run_engine_step", faux)
    run_id = _nouveau_run(base)
    runner.execute_run(run_id)

    with Session(base) as s:
        run = s.get(Run, run_id)
        assert run.status is RunStatus.FAILED and "clé refusée" in run.error
        assert s.get(App, 1).status is AppStatus.FAILED
        assert "create_project_dir" not in appels        # rien après l'échec fatal
        etape = s.exec(select(Step).where(Step.run_id == run_id,
                                          Step.name == "validate_ssh")).one()
        assert etape.status is StepStatus.FAILED and etape.exit_code == 2


def test_code_1_declenche_exactement_un_retry(base, monkeypatch):
    import panel.worker.runner as runner
    monkeypatch.setattr(runner, "time_sleep", lambda _s: None)
    essais: list[str] = []

    def faux(ws, nom, bus, **k):
        essais.append(nom)
        if nom == "build_images":
            return StepResult(False, 1, error="registre injoignable")
        return StepResult(True, 0)

    monkeypatch.setattr(runner, "run_engine_step", faux)
    run_id = _nouveau_run(base)
    runner.execute_run(run_id)

    assert essais.count("build_images") == 2            # un essai + un retry, pas plus
    with Session(base) as s:
        etape = s.exec(select(Step).where(Step.run_id == run_id,
                                          Step.name == "build_images")).one()
        assert etape.status is StepStatus.FAILED and etape.attempts == 1
        assert s.get(Run, run_id).status is RunStatus.FAILED


def test_idempotence_les_etapes_deja_ok_sont_sautees(base, monkeypatch):
    """D2 : au deuxième run, prepare_server est sauté, generate_compose non."""
    import panel.worker.runner as runner
    appels: list[str] = []
    _tout_reussit(monkeypatch, appels)
    runner.execute_run(_nouveau_run(base))

    appels.clear()
    runner.execute_run(_nouveau_run(base))
    assert "prepare_server" not in appels
    assert "create_project_dir" not in appels
    assert "enable_sudo_nopasswd" not in appels
    assert "generate_compose" in appels                 # générateur : toujours rejoué
    assert "deploy_stack" in appels


def test_une_etape_sautee_nest_pas_marquee_ok(base, monkeypatch):
    """Un `skipped` ne doit pas servir de preuve de succès au run suivant,
    sinon un run entièrement sauté se déclarerait déployé."""
    import panel.worker.runner as runner
    appels: list[str] = []
    _tout_reussit(monkeypatch, appels)
    runner.execute_run(_nouveau_run(base))
    runner.execute_run(_nouveau_run(base))
    with Session(base) as s:
        sautees = s.exec(select(Step).where(Step.status == StepStatus.SKIPPED)).all()
        assert all(e.exit_code is None for e in sautees)


def test_les_secrets_sont_nettoyes_en_fin_de_run(base, monkeypatch, tmp_runs):
    import panel.worker.runner as runner
    _tout_reussit(monkeypatch, [])
    runner.execute_run(_nouveau_run(base))
    assert not (tmp_runs / "mon-app" / "env.json").exists()
    assert (tmp_runs / "mon-app" / "spec.json").exists()


def test_timeout_global_de_run(base, monkeypatch):
    import panel.worker.runner as runner
    from panel.settings import get_settings
    get_settings.cache_clear()
    monkeypatch.setenv("PANEL_RUN_TIMEOUT_SECONDS", "0")
    _tout_reussit(monkeypatch, [])
    run_id = _nouveau_run(base)
    runner.execute_run(run_id)
    with Session(base) as s:
        run = s.get(Run, run_id)
        assert run.status is RunStatus.FAILED and "délai" in run.error
    get_settings.cache_clear()
```

- [ ] **Step 2: Implémenter `panel/worker/runner.py`**

```python
"""Un job RQ = un run. La boucle qui traduit PIPELINE en lignes de Step."""
import logging
import time
from datetime import datetime, timezone
from pathlib import Path

from sqlmodel import Session, select

from panel.api.deps import get_redis
from panel.db import engine as db_engine
from panel.models import (App, AppStatus, Run, RunStatus, Step, StepKind,
                          StepStatus, Target)
from panel.pipeline import PIPELINE, StepDef
from panel.runspace import cleanup_secrets
from panel.settings import get_settings
from panel.worker.engine import StepResult, run_engine_step
from panel.worker.logbus import LogBus
from panel.worker.steps_py import StepContext, run_python_step

log = logging.getLogger("worker")
time_sleep = time.sleep          # indirection : monkeypatchée dans les tests


def _now():
    return datetime.now(timezone.utc)


def log_path_for(app_name: str, run_id: int) -> Path:
    return get_settings().runs_dir / app_name / "logs" / f"run-{run_id}.log"


def _drapeau(env: dict, chemin: str) -> bool:
    """Lit un chemin pointé dans l'env applicatif, comme cfg_bool côté engine."""
    courant: object = env
    for morceau in chemin.split("."):
        if not isinstance(courant, dict):
            return False
        courant = courant.get(morceau)
    return courant is True


def doit_sauter(session: Session, app_id: int, definition: StepDef, env: dict) -> str | None:
    """Renvoie la raison du saut, ou None. C'est TOUTE l'idempotence (D2)."""
    if definition.requires_flag and not _drapeau(env, definition.requires_flag):
        return f"{definition.requires_flag} n'est pas activé"
    if definition.always_rerun:
        return None
    deja = session.exec(
        select(Step).join(Run, Step.run_id == Run.id)
        .where(Run.app_id == app_id, Step.name == definition.name,
               Step.status == StepStatus.OK)
        .order_by(Step.id.desc())
    ).first()
    return "déjà réussie lors d'un run précédent" if deja else None


def execute_run(run_id: int) -> None:
    settings = get_settings()
    with Session(db_engine) as session:
        run = session.get(Run, run_id)
        if run is None:
            log.error("run %s introuvable", run_id)
            return
        app = session.get(App, run.app_id)
        target = session.get(Target, app.target_id)

        bus = LogBus(get_redis(), run_id, log_path_for(app.name, run_id))
        run.status, run.started_at = RunStatus.RUNNING, _now()
        app.status = AppStatus.DEPLOYING
        session.add_all([run, app])
        session.commit()
        bus.emit_event("run", status="running")

        echeance = time.monotonic() + settings.run_timeout_seconds
        erreur: str | None = None
        try:
            for definition in PIPELINE:
                etape = session.exec(
                    select(Step).where(Step.run_id == run_id,
                                       Step.name == definition.name)).one()

                if time.monotonic() > echeance:
                    erreur = (f"délai global du run dépassé "
                              f"({settings.run_timeout_seconds}s)")
                    break

                raison = doit_sauter(session, app.id, definition, app.env or {})
                if raison:
                    etape.status, etape.finished_at = StepStatus.SKIPPED, _now()
                    etape.error = raison
                    session.add(etape)
                    session.commit()
                    bus.emit_event("step", step=definition.name,
                                   status="skipped", detail=raison)
                    continue

                etape.status, etape.started_at = StepStatus.RUNNING, _now()
                etape.log_path = str(log_path_for(app.name, run_id))
                session.add(etape)
                session.commit()
                bus.emit_event("step", step=definition.name, status="running")

                resultat = _executer(definition, app, target, run_id, bus, session)
                if not resultat.ok and resultat.exit_code == 1:
                    # UN seul retry, et seulement sur un échec réessayable.
                    bus.emit_log(definition.name,
                                 f"échec réessayable, nouvel essai dans "
                                 f"{settings.retry_backoff_seconds}s")
                    time_sleep(settings.retry_backoff_seconds)
                    etape.attempts = 1
                    resultat = _executer(definition, app, target, run_id, bus, session)

                etape.finished_at = _now()
                etape.exit_code = resultat.exit_code
                etape.data = resultat.data
                etape.error = resultat.error
                etape.status = StepStatus.OK if resultat.ok else StepStatus.FAILED
                session.add(etape)
                session.commit()
                bus.emit_event("step", step=definition.name,
                               status=etape.status.value, detail=resultat.error)

                if not resultat.ok:
                    erreur = f"étape '{definition.name}' : {resultat.error}"
                    break
        except Exception as exc:                       # noqa: BLE001
            log.exception("run %s : exception non prévue", run_id)
            erreur = f"exception du worker : {type(exc).__name__}: {exc}"
        finally:
            run = session.get(Run, run_id)
            run.status = RunStatus.FAILED if erreur else RunStatus.OK
            run.error, run.finished_at = erreur, _now()
            app = session.get(App, run.app_id)
            app.status = AppStatus.FAILED if erreur else AppStatus.DEPLOYED
            app.updated_at = _now()
            session.add_all([run, app])
            session.commit()
            bus.emit_event("run", status=run.status.value, detail=erreur)
            cleanup_secrets(app.name)        # D3 : env.json ne survit pas au run
            bus.close()


def _executer(definition: StepDef, app: App, target: Target, run_id: int,
              bus: LogBus, session: Session) -> StepResult:
    """L'aiguillage des deux natures d'étape (D1) — tout tient en cinq lignes,
    et c'est exactement ce qu'on aurait dû réécrire au jalon 4 sans D1."""
    if definition.kind is StepKind.PYTHON:
        ctx = StepContext(app=app, target=target, run_id=run_id, bus=bus, session=session)
        return run_python_step(definition.python_handler or definition.name, ctx)
    return run_engine_step(app.name, definition.name, bus)
```

- [ ] **Step 3: Voir vert, puis vérifier par mutation**

```bash
.venv/bin/python -m pytest tests/test_runner.py -q   # attendu : 7 passed
```

| Mutation | Assertion qui doit rougir |
|---|---|
| `doit_sauter` → `return None` toujours | `test_idempotence_les_etapes_deja_ok_sont_sautees` |
| `Step.status == StepStatus.OK` → `.in_([OK, SKIPPED])` | `test_une_etape_sautee_nest_pas_marquee_ok` (deuxième run) |
| retirer le `break` après un échec | `test_code_2_arrete_le_run_immediatement` |
| retry sur `exit_code == 2` aussi | ajouter l'assertion `essais.count("validate_ssh") == 1` dans `test_code_2…` |
| boucle `while` de retry au lieu d'un seul | `test_code_1_declenche_exactement_un_retry` |
| `finally:` supprimé | `test_les_secrets_sont_nettoyes_en_fin_de_run` **et** l'exception laisserait le run en `running` |
| `requires_flag` ignoré | `test_run_complet_passe_ok` (les 4 `skipped` deviennent des appels à des étapes inexistantes) |

- [ ] **Step 4: Commit**

```bash
git add panel/worker/runner.py tests/test_runner.py
git commit -m "feat(worker): boucle d'exécution d'un run — idempotence par Step, retry, timeouts"
```

---

## Task 17: `panel/worker/reconcile.py` et l'entrée `rq worker` (D4)

**Files:**
- Create: `panel/worker/reconcile.py`, `panel/worker/main.py`, `tests/test_reconcile.py`

**Interfaces:**
- Consumes: `rq.job.Job.exists`, `panel.models.Run/Step`.
- Produces:
  - `reconcile_stale_runs(session: Session, redis) -> list[int]` — renvoie les ids des runs marqués `failed`.
  - `main() -> None` dans `panel/worker/main.py` — réconcilie, puis `Worker([queue]).work()`.

**Le raisonnement, à écrire dans le code** : un `Run` en `running` n'a que deux explications. Soit un worker l'exécute vraiment — et alors son job RQ existe dans Redis. Soit le worker est mort en cours de route (redémarrage du conteneur, OOM, `docker compose restart worker`) — et alors le job a disparu avec lui, sans que personne n'ait pu écrire `failed`. La deuxième explication est exactement le critère d'acceptation n°6. La distinction se fait sur `Job.exists(rq_job_id, connection=redis)`, ce qui est la raison d'être de la colonne `rq_job_id`.

**Faux positif à éviter** : un run **tout juste** mis en file, dont l'API n'a pas encore écrit `rq_job_id`, aurait `rq_job_id is None` et serait fauché à tort par un démarrage de panneau concurrent. La garde : on ne réconcilie que les runs dont `created_at` remonte à plus de 60 secondes, ou dont le `rq_job_id` est renseigné.

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_reconcile.py` :

```python
"""D4 : les runs orphelins deviennent failed, les runs vivants sont épargnés."""
from datetime import datetime, timedelta, timezone

import fakeredis
import pytest
from sqlmodel import Session, SQLModel, create_engine, select

from panel.models import App, AuthMethod, Run, RunStatus, Step, StepKind, StepStatus, Target
from panel.worker.reconcile import reconcile_stale_runs


@pytest.fixture
def session():
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False})
    SQLModel.metadata.create_all(engine)
    with Session(engine) as s:
        s.add(Target(id=1, name="vm", host="h", ssh_user="u", auth_method=AuthMethod.KEY))
        s.add(App(id=1, name="mon-app", target_id=1, spec={}, env={}))
        s.commit()
        yield s


def _run(session, statut, job_id, age_secondes=3600) -> Run:
    run = Run(app_id=1, status=statut, rq_job_id=job_id,
              created_at=datetime.now(timezone.utc) - timedelta(seconds=age_secondes),
              started_at=datetime.now(timezone.utc))
    session.add(run)
    session.commit()
    session.refresh(run)
    session.add(Step(run_id=run.id, name="build_images", ordinal=0,
                     kind=StepKind.ENGINE, status=StepStatus.RUNNING))
    session.commit()
    return run


def test_un_run_running_sans_job_devient_failed(session):
    run = _run(session, RunStatus.RUNNING, "job-disparu")
    ids = reconcile_stale_runs(session, fakeredis.FakeStrictRedis())
    assert ids == [run.id]
    session.refresh(run)
    assert run.status is RunStatus.FAILED
    assert "n'existe plus" in run.error and run.finished_at is not None
    etape = session.exec(select(Step).where(Step.run_id == run.id)).one()
    assert etape.status is StepStatus.FAILED         # l'étape en cours aussi


def test_un_run_dont_le_job_existe_est_epargne(session):
    from rq import Queue
    r = fakeredis.FakeStrictRedis()
    job = Queue("deploymatic", connection=r).enqueue(print, "coucou")
    run = _run(session, RunStatus.RUNNING, job.id)
    assert reconcile_stale_runs(session, r) == []
    session.refresh(run)
    assert run.status is RunStatus.RUNNING


def test_un_run_termine_nest_pas_touche(session):
    run = _run(session, RunStatus.OK, "job-disparu")
    assert reconcile_stale_runs(session, fakeredis.FakeStrictRedis()) == []
    session.refresh(run)
    assert run.status is RunStatus.OK


def test_un_run_tout_juste_mis_en_file_est_epargne(session):
    """Faux positif à éviter : rq_job_id pas encore écrit par l'API."""
    run = _run(session, RunStatus.QUEUED, None, age_secondes=1)
    assert reconcile_stale_runs(session, fakeredis.FakeStrictRedis()) == []
    session.refresh(run)
    assert run.status is RunStatus.QUEUED


def test_un_run_queued_ancien_sans_job_est_fauche(session):
    run = _run(session, RunStatus.QUEUED, None, age_secondes=3600)
    assert reconcile_stale_runs(session, fakeredis.FakeStrictRedis()) == [run.id]


def test_appel_repete_est_idempotent(session):
    _run(session, RunStatus.RUNNING, "job-disparu")
    r = fakeredis.FakeStrictRedis()
    assert len(reconcile_stale_runs(session, r)) == 1
    assert reconcile_stale_runs(session, r) == []
```

- [ ] **Step 2: Implémenter `panel/worker/reconcile.py`**

```python
"""Réconciliation des runs orphelins (D4).

Un Run en `running` n'a que deux explications :
  - un worker l'exécute vraiment → son job RQ existe dans Redis ;
  - le worker est mort en cours de route (redémarrage du conteneur, OOM,
    `docker compose restart worker`) → le job a disparu avec lui, et personne
    n'a pu écrire `failed`.

Sans cette fonction, la deuxième explication laisse un run bloqué en `running`
pour toujours, et l'application avec — c'est le défaut du couple `Popen`
détaché + fichier PID de l'ancien web/, et c'est le critère d'acceptation n°6.

Appelée DEUX fois : au démarrage du panel (lifespan) et au démarrage du worker
(main.py). Redémarrer l'un ne redémarre pas l'autre.
"""
import logging
from datetime import datetime, timedelta, timezone

from rq.job import Job
from sqlmodel import Session, select

from panel.models import App, AppStatus, Run, RunStatus, Step, StepStatus

log = logging.getLogger("worker.reconcile")

# Un run plus jeune que ce délai peut légitimement n'avoir pas encore de
# rq_job_id : l'API l'écrit juste après l'enqueue, en deux commits.
GRACE_SECONDES = 60

ACTIFS = (RunStatus.QUEUED, RunStatus.RUNNING)


def reconcile_stale_runs(session: Session, redis) -> list[int]:
    limite = datetime.now(timezone.utc) - timedelta(seconds=GRACE_SECONDES)
    fauches: list[int] = []

    for run in session.exec(select(Run).where(Run.status.in_(ACTIFS))):
        if run.rq_job_id:
            try:
                if Job.exists(run.rq_job_id, connection=redis):
                    continue          # quelqu'un travaille : ne pas y toucher
            except Exception:
                log.exception("réconciliation : Redis injoignable, run %s laissé "
                              "en l'état", run.id)
                continue
        elif (run.created_at.replace(tzinfo=timezone.utc) if run.created_at.tzinfo is None
              else run.created_at) > limite:
            continue                  # trop jeune : l'API n'a peut-être pas fini

        run.status = RunStatus.FAILED
        run.finished_at = datetime.now(timezone.utc)
        run.error = (f"run interrompu : le job RQ '{run.rq_job_id or '<jamais mis en "
                     f"file>'}' n'existe plus (redémarrage du worker ?)")
        session.add(run)

        for etape in session.exec(select(Step).where(
                Step.run_id == run.id,
                Step.status.in_((StepStatus.RUNNING, StepStatus.PENDING)))):
            etape.status = StepStatus.FAILED
            etape.finished_at = run.finished_at
            etape.error = "interrompue par l'arrêt du worker"
            session.add(etape)

        app = session.get(App, run.app_id)
        if app is not None and app.status is AppStatus.DEPLOYING:
            app.status = AppStatus.FAILED
            session.add(app)

        fauches.append(run.id)

    session.commit()
    if fauches:
        log.warning("réconciliation : %d run(s) orphelin(s) → failed : %s",
                    len(fauches), fauches)
    return fauches
```

- [ ] **Step 3: Implémenter `panel/worker/main.py`**

```python
"""Point d'entrée du conteneur worker : `python -m panel.worker.main`.

Pourquoi pas `rq worker` directement : la réconciliation doit tourner AVANT
que le worker se mette à dépiler, et il faut que le schéma existe. Un
`rq worker` nu ne le ferait pas.
"""
import logging

from rq import Queue, Worker

from panel.api.deps import QUEUE_NAME, get_redis
from panel.db import create_all, session_scope
from panel.worker.reconcile import reconcile_stale_runs


def main() -> None:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    create_all()
    redis = get_redis()
    # D4, appel n°2 sur 2. `docker compose restart worker` passe par ici.
    with session_scope() as session:
        reconcile_stale_runs(session, redis)
    Worker([Queue(QUEUE_NAME, connection=redis)], connection=redis).work(
        with_scheduler=False)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Voir vert, puis vérifier par mutation**

```bash
.venv/bin/python -m pytest tests/test_reconcile.py -q   # attendu : 6 passed
```

| Mutation | Assertion qui doit rougir |
|---|---|
| `reconcile_stale_runs` → `return []` | `test_un_run_running_sans_job_devient_failed` |
| retirer le `if Job.exists(...): continue` | `test_un_run_dont_le_job_existe_est_epargne` |
| élargir `ACTIFS` à tous les statuts | `test_un_run_termine_nest_pas_touche` |
| `GRACE_SECONDES = 0` | `test_un_run_tout_juste_mis_en_file_est_epargne` |
| ne pas marquer les `Step` en cours | `test_un_run_running_sans_job_devient_failed` (dernière assertion) |
| retirer l'appel dans `main()` | vérification manuelle du critère n°6 (Task 23) |

- [ ] **Step 5: Commit**

```bash
git add panel/worker/reconcile.py panel/worker/main.py tests/test_reconcile.py
git commit -m "feat(worker): réconciliation des runs orphelins au démarrage du panel et du worker"
```

---

## Task 18: `panel/api/routes_runs.py` — état d'un run et SSE sans fuite

**Files:**
- Create: `panel/api/routes_runs.py`, `tests/test_api_runs.py`

**Interfaces:**
- Consumes: `LogBus.canal`, `redis.asyncio`.
- Produces:
  - `GET /api/runs/{id}` → `RunOut` (avec ses `steps` triées par `ordinal`)
  - `GET /api/runs/{id}/events` → `text/event-stream` : d'abord un événement `snapshot` (état complet + logs déjà écrits), puis les messages publiés sur `run:<id>:logs`, plus un `ping` toutes les 15 s.

**La fuite de thread SSE (dette technique n°3) et son correctif.** L'ancien `web/` lançait un thread par connexion SSE et ne le terminait jamais quand le navigateur fermait l'onglet : chaque rechargement de page ajoutait un thread bloqué en lecture. Ici :
- l'endpoint est une **coroutine**, pas un thread : le coût d'un client déconnecté est un objet, pas un thread système ;
- `redis.asyncio` fournit un `pubsub` asynchrone, et le `finally` fait `unsubscribe` + `aclose()` **dans tous les cas**, y compris annulation ;
- une boucle `while True` sans condition de sortie est interdite : la boucle teste `await request.is_disconnected()` à chaque itération et sur chaque timeout de lecture ;
- le flux se termine tout seul dès que le `Run` atteint un statut terminal, sans attendre que le client parte.

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_api_runs.py` :

```python
"""Lecture d'un run et flux SSE."""
import json

import pytest

ORIGIN = {"Origin": "http://127.0.0.1:8080"}
MDP = "motdepasse-de-test-1234"
SPEC = {"name": "mon-app", "services": [
    {"id": "api", "build": "./services/api", "port": 3000,
     "health": "/health", "expose": "/api/"}]}


@pytest.fixture
def run_id(client, monkeypatch):
    import panel.ssh_check as ssh_check
    monkeypatch.setattr(ssh_check, "tester_connexion",
                        lambda *a, **k: {"ok": True, "detail": "ok", "docker": "27"})
    csrf = client.get("/api/csrf").json()["csrf"]
    client.post("/api/login", json={"username": "admin", "password": MDP},
                headers={**ORIGIN, "X-CSRF-Token": csrf})
    client.headers.update({**ORIGIN, "X-CSRF-Token": client.get("/api/csrf").json()["csrf"]})
    client.post("/api/targets", json={"name": "vm", "host": "h", "ssh_user": "u",
                                      "auth_method": "key", "ssh_key_path": "/k"})
    app_id = client.post("/api/apps", json={"target_id": 1, "spec": SPEC}).json()["id"]
    return client.post(f"/api/apps/{app_id}/deploy").json()["run_id"]


def test_lecture_dun_run(client, run_id):
    corps = client.get(f"/api/runs/{run_id}").json()
    assert corps["status"] == "queued"
    assert [s["ordinal"] for s in corps["steps"]] == list(range(len(corps["steps"])))
    assert corps["steps"][0]["name"] == "prepare_workspace"


def test_run_inconnu(client, run_id):
    assert client.get("/api/runs/999999").status_code == 404


def test_sse_exige_une_authentification(client, run_id):
    client.cookies.clear()
    assert client.get(f"/api/runs/{run_id}/events").status_code == 401


def test_sse_envoie_un_snapshot_puis_se_termine_sur_un_run_fini(client, run_id):
    """Un run terminé ne doit pas laisser le flux ouvert indéfiniment."""
    import panel.db as db
    from sqlmodel import Session
    from panel.models import Run, RunStatus
    with Session(db.engine) as s:
        run = s.get(Run, run_id)
        run.status = RunStatus.OK
        s.add(run)
        s.commit()

    with client.stream("GET", f"/api/runs/{run_id}/events") as r:
        assert r.status_code == 200
        assert r.headers["content-type"].startswith("text/event-stream")
        assert r.headers["cache-control"] == "no-cache"
        lignes = [l for l in r.iter_lines() if l]
    charge = json.loads(next(l for l in lignes if l.startswith("data:"))[5:])
    assert charge["t"] == "snapshot"
    assert charge["run"]["status"] == "ok"
    assert any(l.startswith("event: end") for l in lignes)
```

- [ ] **Step 2: Implémenter `panel/api/routes_runs.py`**

```python
"""État d'un run et flux d'événements."""
import asyncio
import json

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import StreamingResponse
from redis.asyncio import Redis as AsyncRedis
from sqlmodel import Session, select

from panel.api.schemas import RunOut, StepOut
from panel.db import get_session
from panel.models import App, Run, RunStatus, Step, User
from panel.security import current_user
from panel.settings import get_settings
from panel.worker.logbus import canal
from panel.worker.runner import log_path_for

router = APIRouter(prefix="/api/runs", tags=["runs"])

TERMINES = (RunStatus.OK, RunStatus.FAILED)
PING_SECONDES = 15


def _charger(session: Session, run_id: int) -> tuple[Run, list[Step]]:
    run = session.get(Run, run_id)
    if run is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "run inconnu")
    etapes = list(session.exec(select(Step).where(Step.run_id == run_id)
                               .order_by(Step.ordinal)))
    return run, etapes


@router.get("/{run_id}", response_model=RunOut)
def lire(run_id: int, session: Session = Depends(get_session),
         _: User = Depends(current_user)) -> RunOut:
    run, etapes = _charger(session, run_id)
    return RunOut(**run.model_dump(),
                  steps=[StepOut(**e.model_dump()) for e in etapes])


@router.get("/{run_id}/events")
async def evenements(run_id: int, request: Request,
                     session: Session = Depends(get_session),
                     _: User = Depends(current_user)) -> StreamingResponse:
    run, etapes = _charger(session, run_id)
    app = session.get(App, run.app_id)
    snapshot = {
        "t": "snapshot",
        "run": json.loads(RunOut(**run.model_dump(),
                                 steps=[StepOut(**e.model_dump()) for e in etapes]
                                 ).model_dump_json()),
        "logs": _logs_existants(app.name, run_id),
    }
    termine = run.status in TERMINES

    async def flux():
        # Le snapshot d'abord : quelqu'un qui ouvre la page d'un run terminé
        # doit voir son historique complet, que Redis n'a jamais conservé.
        yield _sse(json.dumps(snapshot, ensure_ascii=False))
        if termine:
            yield "event: end\ndata: {}\n\n"
            return

        redis = AsyncRedis.from_url(get_settings().redis_url)
        pubsub = redis.pubsub()
        try:
            await pubsub.subscribe(canal(run_id))
            while True:
                # Correctif de la dette technique n°3 : aucune boucle sans
                # condition de sortie, et la déconnexion du client est testée
                # à CHAQUE tour, y compris quand rien n'arrive.
                if await request.is_disconnected():
                    return
                message = await pubsub.get_message(ignore_subscribe_messages=True,
                                                   timeout=PING_SECONDES)
                if message is None:
                    yield ": ping\n\n"      # commentaire SSE : garde le tube ouvert
                    continue
                charge = message["data"].decode()
                yield _sse(charge)
                try:
                    if json.loads(charge).get("t") == "run" and \
                            json.loads(charge).get("status") in ("ok", "failed"):
                        yield "event: end\ndata: {}\n\n"
                        return
                except json.JSONDecodeError:
                    continue
        except asyncio.CancelledError:
            raise
        finally:
            # Dans TOUS les cas, y compris annulation : c'est ce qui manquait
            # à l'ancienne implémentation, qui laissait un thread par onglet.
            try:
                await pubsub.unsubscribe(canal(run_id))
                await pubsub.aclose()
                await redis.aclose()
            except Exception:
                pass

    return StreamingResponse(flux(), media_type="text/event-stream", headers={
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",   # BunkerWeb/NGINX : ne pas tamponner le flux
        "Connection": "keep-alive",
    })


def _sse(donnees: str) -> str:
    return f"data: {donnees}\n\n"


def _logs_existants(app_name: str, run_id: int, max_lignes: int = 2000) -> list[str]:
    chemin = log_path_for(app_name, run_id)
    if not chemin.exists():
        return []
    with chemin.open(encoding="utf-8", errors="replace") as f:
        return [l.rstrip("\n") for l in f][-max_lignes:]
```

- [ ] **Step 3: Voir vert**

```bash
.venv/bin/python -m pytest tests/test_api_runs.py -q   # attendu : 4 passed
```

Vérification manuelle de l'absence de fuite, une fois la stack debout (Task 21) :

```bash
# Ouvrir puis fermer 20 flux SSE, et compter les threads du conteneur panel
for i in $(seq 20); do curl -sN --max-time 1 -b cookies.txt \
  http://127.0.0.1:8080/api/runs/1/events >/dev/null; done
docker compose exec panel sh -c 'ls /proc/1/task | wc -l'
```

Attendu : le nombre de threads est stable avant et après.

- [ ] **Step 4: Commit**

```bash
git add panel/api/routes_runs.py tests/test_api_runs.py
git commit -m "feat(panel): lecture d'un run et flux SSE asynchrone sans fuite de thread"
```

---

## Task 19: Frontend Jinja2 — trois écrans, JS vanilla

**Files:**
- Create: `panel/api/routes_ui.py`, `panel/templates/{base,login,targets,apps,run}.html`, `panel/static/{app.css,run.js}`, `tests/test_ui.py`

**Interfaces:**
- Consumes: `panel.security.session_payload`, `Jinja2Templates`.
- Produces:
  - `GET /` → redirection vers `/apps` si session, vers `/login` sinon
  - `GET /login`, `GET /targets`, `GET /apps`, `GET /runs/{id}` — rendus serveur, chacun injecte `csrf_token` dans un `<meta>`
  - `panel/static/run.js` — `EventSource` sur `/api/runs/{id}/events`, étapes à gauche, logs à droite, auto-scroll.

**Trois règles, non négociables** :
1. **Aucun framework JS**, aucun CDN : la page ne charge que ses propres fichiers. C'est aussi ce qui permet une CSP stricte.
2. **Le token CSRF vient du serveur**, dans un `<meta name="csrf-token">` rempli par `GET /api/csrf` côté serveur, et le JS le rejoue dans l'en-tête `X-CSRF-Token`. Il n'est jamais dans l'URL ni dans le `localStorage`.
3. **Aucune interpolation de données dans du HTML par le JS.** Les lignes de log arrivent par SSE et sont insérées avec `textContent`, jamais `innerHTML` : un log de l'engine contenant `<script>` est du texte, pas du code. C'est le seul XSS réaliste de ce panneau, et il vient de la sortie d'un serveur distant.

- [ ] **Step 1: Écrire le test d'abord**

Créer `tests/test_ui.py` :

```python
"""Les trois écrans : redirection, CSRF dans la page, pas de CDN."""
ORIGIN = {"Origin": "http://127.0.0.1:8080"}
MDP = "motdepasse-de-test-1234"


def test_racine_redirige_vers_login_sans_session(client):
    r = client.get("/", follow_redirects=False)
    assert r.status_code in (302, 307) and r.headers["location"].endswith("/login")


def test_login_affiche_un_token_csrf(client):
    page = client.get("/login").text
    assert 'name="csrf-token"' in page
    assert "http://cdn" not in page and "https://cdn" not in page


def test_les_ecrans_exigent_une_session(client):
    for chemin in ("/targets", "/apps", "/runs/1"):
        r = client.get(chemin, follow_redirects=False)
        assert r.status_code in (302, 307), chemin


def test_apres_connexion_les_ecrans_repondent(client):
    csrf = client.get("/api/csrf").json()["csrf"]
    client.post("/api/login", json={"username": "admin", "password": MDP},
                headers={**ORIGIN, "X-CSRF-Token": csrf})
    assert client.get("/apps").status_code == 200
    assert client.get("/targets").status_code == 200


def test_aucun_script_externe_dans_les_gabarits():
    from pathlib import Path
    for f in Path("panel/templates").glob("*.html"):
        contenu = f.read_text()
        assert "src=\"http" not in contenu, f
        assert "href=\"http" not in contenu or "static" in contenu, f
```

- [ ] **Step 2: Implémenter `panel/api/routes_ui.py`**

```python
"""Les trois écrans, rendus côté serveur."""
from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlmodel import Session, select

from panel.auth import new_csrf_token
from panel.db import get_session
from panel.models import App, Run, Target
from panel.security import session_payload, set_session_cookie
from panel.settings import REPO_ROOT

router = APIRouter(tags=["ui"])
templates = Jinja2Templates(directory=str(REPO_ROOT / "panel" / "templates"))


def _csrf(request: Request, response: Response) -> str:
    payload = session_payload(request) or {}
    if "csrf" not in payload:
        payload = {**payload, "csrf": new_csrf_token()}
        set_session_cookie(response, payload)
    return payload["csrf"]


def _connecte(request: Request) -> bool:
    return "uid" in (session_payload(request) or {})


@router.get("/", response_class=RedirectResponse)
def racine(request: Request):
    return RedirectResponse("/apps" if _connecte(request) else "/login", status_code=302)


@router.get("/login", response_class=HTMLResponse)
def login(request: Request):
    reponse = templates.TemplateResponse(request, "login.html", {"csrf_token": ""})
    reponse.context["csrf_token"] = _csrf(request, reponse)
    return templates.TemplateResponse(request, "login.html",
                                      {"csrf_token": _csrf(request, reponse)},
                                      headers=dict(reponse.headers))


@router.get("/targets", response_class=HTMLResponse)
def ecran_targets(request: Request, session: Session = Depends(get_session)):
    if not _connecte(request):
        return RedirectResponse("/login", status_code=302)
    reponse = Response()
    return templates.TemplateResponse(request, "targets.html", {
        "csrf_token": _csrf(request, reponse),
        "targets": list(session.exec(select(Target).order_by(Target.name)))})


@router.get("/apps", response_class=HTMLResponse)
def ecran_apps(request: Request, session: Session = Depends(get_session)):
    if not _connecte(request):
        return RedirectResponse("/login", status_code=302)
    reponse = Response()
    return templates.TemplateResponse(request, "apps.html", {
        "csrf_token": _csrf(request, reponse),
        "apps": list(session.exec(select(App).order_by(App.name))),
        "targets": list(session.exec(select(Target).order_by(Target.name)))})


@router.get("/runs/{run_id}", response_class=HTMLResponse)
def ecran_run(run_id: int, request: Request, session: Session = Depends(get_session)):
    if not _connecte(request):
        return RedirectResponse("/login", status_code=302)
    run = session.get(Run, run_id)
    reponse = Response()
    return templates.TemplateResponse(request, "run.html", {
        "csrf_token": _csrf(request, reponse), "run_id": run_id,
        "app_name": session.get(App, run.app_id).name if run else "?"})
```

- [ ] **Step 3: Écrire `panel/templates/base.html`**

```html
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="csrf-token" content="{{ csrf_token }}">
  <title>{% block titre %}DeployMatic{% endblock %}</title>
  <link rel="stylesheet" href="/static/app.css">
</head>
<body>
  <nav><a href="/apps">Applications</a> <a href="/targets">Cibles</a>
    <button id="deconnexion">Déconnexion</button></nav>
  <main>{% block contenu %}{% endblock %}</main>
  <script src="/static/app.js"></script>
  {% block scripts %}{% endblock %}
</body>
</html>
```

- [ ] **Step 4: Écrire `panel/static/app.js` — le helper de mutation**

```javascript
// Toute mutation passe par ici : le token CSRF vient du <meta> rempli par le
// serveur, jamais du localStorage (qu'un XSS lirait) ni de l'URL (que les logs
// du proxy garderaient).
const CSRF = document.querySelector('meta[name="csrf-token"]').content;

async function mutation(methode, url, corps) {
  const r = await fetch(url, {
    method: methode,
    headers: {'Content-Type': 'application/json', 'X-CSRF-Token': CSRF},
    credentials: 'same-origin',
    body: corps === undefined ? undefined : JSON.stringify(corps),
  });
  if (!r.ok) {
    let detail = r.statusText;
    try { detail = (await r.json()).detail || detail; } catch (_) {}
    throw new Error(detail);
  }
  return r.status === 204 ? null : r.json();
}

document.getElementById('deconnexion')?.addEventListener('click', async () => {
  await mutation('POST', '/api/logout');
  location.href = '/login';
});
```

- [ ] **Step 5: Écrire `panel/static/run.js` — l'écran de run en direct**

```javascript
// Étapes à gauche, logs à droite. Auto-scroll tant que l'utilisateur n'a pas
// remonté lui-même : rien de plus agaçant qu'un log qui se dérobe pendant
// qu'on lit une erreur.
const runId = document.body.dataset.runId;
const etapes = document.getElementById('etapes');
const logs = document.getElementById('logs');
let colle = true;

logs.addEventListener('scroll', () => {
  colle = logs.scrollHeight - logs.scrollTop - logs.clientHeight < 40;
});

function ligne(texte) {
  const el = document.createElement('div');
  el.textContent = texte;          // JAMAIS innerHTML : la sortie de l'engine
  logs.appendChild(el);            // vient d'une machine distante.
  if (colle) logs.scrollTop = logs.scrollHeight;
}

function majEtape(nom, statut) {
  const el = etapes.querySelector(`[data-step="${CSS.escape(nom)}"]`);
  if (el) { el.dataset.statut = statut; el.querySelector('.statut').textContent = statut; }
}

const source = new EventSource(`/api/runs/${runId}/events`);
source.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.t === 'snapshot') {
    m.run.steps.forEach((s) => majEtape(s.name, s.status));
    (m.logs || []).forEach(ligne);
  } else if (m.t === 'log') {
    ligne(`[${m.step}] ${m.line}`);
  } else if (m.t === 'step') {
    majEtape(m.step, m.status);
    if (m.detail) ligne(`— ${m.step} : ${m.detail}`);
  } else if (m.t === 'run') {
    document.getElementById('statut-run').textContent = m.status;
  }
};
source.addEventListener('end', () => source.close());   // le serveur a fini
source.onerror = () => ligne('— flux interrompu, rechargez la page —');
```

- [ ] **Step 6: Écrire `apps.html`, `targets.html`, `run.html`, `login.html` et `app.css`**

Contenu minimal, sans dépendance : un formulaire de création par écran (qui appelle `mutation()`), une table de listing, et pour `run.html` le squelette `<ul id="etapes">` rempli côté serveur depuis `PIPELINE` + `<pre id="logs">`. `run.html` porte `<body data-run-id="{{ run_id }}">` et charge `run.js` dans le bloc `scripts`.

- [ ] **Step 7: Voir vert**

```bash
.venv/bin/python -m pytest tests/test_ui.py -q   # attendu : 5 passed
```

- [ ] **Step 8: Commit**

```bash
git add panel/api/routes_ui.py panel/templates panel/static tests/test_ui.py
git commit -m "feat(panel): trois écrans Jinja2 et JS vanilla, logs SSE en direct"
```

---

## Task 20: `Dockerfile` — image commune `panel` et `worker` (rôle Infra)

**Files:**
- Create: `Dockerfile`, `.dockerignore`

**Interfaces:**
- Consumes: `pyproject.toml`.
- Produces: une image portant Python 3.11+, `jq`, le client `ssh`, `sshpass`, le client Docker **et** le plugin Compose, un utilisateur `panel` en UID 10001, et l'application en `/app`. Contrat **C7**.

**Pourquoi ces paquets et pas d'autres** : `check_prereqs` (engine/lib/prereqs.sh) exige `git`, `ssh`, `scp`, `curl`, `jq`, `docker` et le plugin `docker compose` ; `sshpass` seulement si `auth_method=password` ; `gh` seulement si `github.enabled`. On embarque tout sauf `gh` — dont les étapes ne sont de toute façon pas implémentées côté engine (cf. `requires_flag`). **Le client Docker est un binaire client : il ne parle à aucun démon local, il se connecte par `DOCKER_HOST=ssh://`. Le socket n'est monté nulle part.**

- [ ] **Step 1: Écrire le `Dockerfile`**

```dockerfile
# Image commune aux services panel et worker : mêmes dépendances, commandes
# différentes. Une seule image à construire, à scanner et à mettre à jour.
FROM python:3.12-slim AS base

# Dépendances de l'engine (cf. engine/lib/prereqs.sh) + client Docker.
# gh est volontairement absent : les étapes github_* ne sont pas implémentées
# côté engine, et le drapeau github.enabled les neutralise (cf. pipeline.py).
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash git jq curl ca-certificates openssh-client sshpass gnupg \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg \
      -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# UID fixe et non-root : le volume runs/ est partagé entre panel et worker,
# les deux doivent lire et écrire les mêmes fichiers en 600.
RUN groupadd -g 10001 panel && useradd -u 10001 -g 10001 -m -s /bin/bash panel

WORKDIR /app
COPY pyproject.toml /app/
RUN pip install --no-cache-dir /app 2>/dev/null || \
    (pip install --no-cache-dir hatchling && pip install --no-cache-dir /app)

COPY --chown=panel:panel panel/ /app/panel/
COPY --chown=panel:panel engine/ /app/engine/

# runs/ est un volume monté ; le répertoire doit exister et appartenir à panel.
RUN mkdir -p /app/runs && chown panel:panel /app/runs && chmod 700 /app/runs

USER 10001:10001
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
EXPOSE 8000

# Commande par défaut : le panneau. Le worker surcharge avec sa propre commande.
CMD ["gunicorn", "panel.api.app:app", \
     "--worker-class", "uvicorn.workers.UvicornWorker", \
     "--workers", "2", "--bind", "0.0.0.0:8000", \
     "--timeout", "120", "--graceful-timeout", "30", "--access-logfile", "-"]
```

**Note sur « gunicorn threads, pas gevent ».** La feuille de route demande des *workers threads* pour que les subprocess fonctionnent. Ce plan tranche autrement, et c'est délibéré : **le panneau ne lance aucun subprocess** (sauf le test SSH de la Task 10, court et synchrone) — c'est le **worker** qui exécute les runs, et il tourne sous `rq worker`, un modèle par processus fils, pas sous gunicorn. Le panneau, lui, sert du SSE, ce qui exige un worker **asynchrone** : avec des workers threads, chaque flux SSE mobiliserait un thread pour la durée du run, et deux onglets suffiraient à saturer le pool. `UvicornWorker` est donc le bon choix ici. Ce qui reste vrai de la mise en garde d'origine : **jamais gevent**, dont le monkey-patching casserait `subprocess` dans le test SSH.

- [ ] **Step 2: Écrire `.dockerignore`**

```
.git
.venv
runs
web
docs
tests
.test-target
**/__pycache__
*.pyc
.pytest_cache
.env
```

- [ ] **Step 3: Construire et vérifier**

```bash
docker build -t deploymatic-panel:dev .
docker run --rm deploymatic-panel:dev id                    # attendu : uid=10001
docker run --rm deploymatic-panel:dev sh -c \
  'for t in git ssh scp curl jq docker; do command -v $t >/dev/null || echo "MANQUANT: $t"; done; \
   docker compose version >/dev/null || echo "MANQUANT: compose"'
docker run --rm deploymatic-panel:dev python -c "import panel.api.app; print('import ok')"
docker run --rm deploymatic-panel:dev sh -c 'ls -ld /app/runs'   # attendu : drwx------ panel
```

Attendu : aucun `MANQUANT`, `uid=10001`, `import ok`.

- [ ] **Step 4: Commit**

```bash
git add Dockerfile .dockerignore
git commit -m "feat(infra): image commune panel/worker en UID 10001 avec les outils de l'engine"
```

---
