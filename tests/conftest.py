"""Fixtures communes : environnement minimal, base éphémère, répertoire runs/."""
import os
from pathlib import Path

import pytest

os.environ.setdefault("PANEL_SECRET_KEY", "0" * 43 + "=")
os.environ.setdefault("PANEL_ADMIN_PASSWORD", "motdepasse-de-test-1234")


@pytest.fixture
def settings():
    """L'instance de configuration courante (environnement de test minimal ci-dessus)."""
    from panel.settings import get_settings

    get_settings.cache_clear()
    yield get_settings()
    get_settings.cache_clear()


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
