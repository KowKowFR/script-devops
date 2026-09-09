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


def test_secret_key_masque_dans_toute_representation(monkeypatch):
    # Un objet Settings journalisé (gestionnaire d'exception générique, mode
    # debug de FastAPI) ne doit jamais faire fuiter la clé de chiffrement,
    # quelle que soit la représentation textuelle utilisée.
    cle = "s3cr3t-valeur-a-ne-jamais-afficher-000!"
    monkeypatch.setenv("PANEL_SECRET_KEY", cle)
    s = Settings()
    assert cle not in repr(s)
    assert cle not in str(s)
    assert cle not in str(vars(s))
    assert cle not in str(s.model_dump())
    assert cle not in s.model_dump_json()
    assert s.secret_key.get_secret_value() == cle
