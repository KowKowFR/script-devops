"""Configuration du panneau — lue une seule fois, dans l'environnement.

Tout ce qui est réglable vit ici. Aucun module ne lit os.environ directement :
c'est ce qui rend la configuration testable (monkeypatch d'un seul objet) et
qui garantit qu'une variable oubliée casse au démarrage, pas au premier run.
"""
from functools import lru_cache
from pathlib import Path

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

REPO_ROOT = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="PANEL_", extra="ignore")

    # --- Secrets et base ---
    # SecretStr : la valeur reste lisible via .get_secret_value(), mais toute
    # représentation textuelle (repr, str, model_dump, model_dump_json) est
    # masquée — un log ou une trace génériques n'exposent jamais la clé.
    secret_key: SecretStr = Field(min_length=32)
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
