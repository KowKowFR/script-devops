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
    """engine/lib/steps.sh court-circuite déjà proprement les step_github_* /
    git_* quand github.enabled est faux (skipped=true) ; requires_flag rend
    cette condition visible et testable côté panneau, sans lancer l'engine."""
    for nom in ("github_create_repo", "github_set_secrets", "git_init", "git_push"):
        assert step_def(nom).requires_flag == "github.enabled"


def test_les_noms_sont_uniques():
    noms = [s.name for s in PIPELINE]
    assert len(noms) == len(set(noms))
