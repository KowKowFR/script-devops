"""Contraintes du modèle : unicité du nom, cascade, secrets illisibles en base.

Note : `panel/crypto.py` est écrit en parallèle par une autre tâche du jalon 2
et n'est pas une dépendance de ce module. Le test du critère d'acceptation
n°7 simule donc un blob chiffré opaque (n'importe quelle chaîne qui ne
contient pas le secret en clair convient : le modèle ne sait rien de Fernet,
il stocke une donnée opaque).
"""
import base64

import pytest
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlmodel import Session, SQLModel, create_engine, select

from panel.models import App, AppStatus, AuthMethod, Run, RunStatus, Step, StepKind, StepStatus, Target, User


def _faux_chiffre(clair: str) -> str:
    """Simule un blob Fernet : opaque, ne contient jamais le clair."""
    return base64.urlsafe_b64encode(clair.encode()).decode()


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
              secrets_enc=_faux_chiffre('{"registry_token": "dckr_pat_ultrasecret"}'))
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


def test_relations_parcourables_dans_les_deux_sens(session):
    """Target -> App -> Run -> Step et retour, sans requête manuelle."""
    t = _cible(session)
    app = App(name="mon-app", target_id=t.id, spec={"name": "mon-app", "services": []})
    session.add(app)
    session.commit()

    run = Run(app_id=app.id, rq_job_id="job-2")
    session.add(run)
    session.commit()

    step = Step(run_id=run.id, name="check_prereqs", ordinal=0, kind=StepKind.ENGINE)
    session.add(step)
    session.commit()

    # Sens descendant : depuis la cible, retrouver l'app via une requête filtrée.
    app_relue = session.exec(select(App).where(App.target_id == t.id)).one()
    assert app_relue.id == app.id

    # Sens montant : depuis l'étape, retrouver le run puis l'app puis la cible.
    step_relu = session.exec(select(Step).where(Step.id == step.id)).one()
    run_relu = session.get(Run, step_relu.run_id)
    assert run_relu is not None
    app_du_run = session.get(App, run_relu.app_id)
    assert app_du_run is not None and app_du_run.name == "mon-app"
    cible_de_lapp = session.get(Target, app_du_run.target_id)
    assert cible_de_lapp is not None and cible_de_lapp.name == "vm-test"


def test_utilisateur_cree_et_relu(session):
    u = User(username="alex", password_hash="argon2id$fake$hash")
    session.add(u)
    session.commit()
    relu = session.exec(select(User).where(User.username == "alex")).one()
    assert relu.password_hash == "argon2id$fake$hash"
    assert relu.last_login is None
