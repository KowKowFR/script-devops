"""Contraintes du modèle : unicité du nom, cascade, secrets illisibles en base.

Note : `panel/crypto.py` est écrit en parallèle par une autre tâche du jalon 2
et n'est pas une dépendance de ce module. Le test du critère d'acceptation
n°7 simule donc un blob chiffré opaque (n'importe quelle chaîne qui ne
contient pas le secret en clair convient : le modèle ne sait rien de Fernet,
il stocke une donnée opaque).
"""
import base64

import pytest
from sqlalchemy import event, text
from sqlalchemy.exc import IntegrityError
from sqlmodel import Session, SQLModel, create_engine, select

from panel.models import App, AppStatus, AuthMethod, Run, RunStatus, Step, StepKind, StepStatus, Target, User


def _faux_chiffre(clair: str) -> str:
    """Simule un blob Fernet : opaque, ne contient jamais le clair."""
    return base64.urlsafe_b64encode(clair.encode()).decode()


def _activer_cles_etrangeres(dbapi_connection, _connection_record):
    """SQLite n'applique PAS les clés étrangères par défaut (contrairement à
    PostgreSQL, où NO ACTION/RESTRICT est toujours vérifié). Sans ce PRAGMA,
    un test de suppression vert ne prouverait rien : la contrainte serait
    silencieusement absente en test alors qu'elle existe en production."""
    dbapi_connection.execute("PRAGMA foreign_keys=ON")


@pytest.fixture
def session():
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False})
    event.listen(engine, "connect", _activer_cles_etrangeres)
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


def test_step_kind_par_defaut_est_engine(session):
    """D1 : sans précision, une étape appelle bootstrap.sh (ENGINE) — c'est le
    cas majoritaire du pipeline actuel, PYTHON reste l'exception déclarée."""
    t = _cible(session)
    app = App(name="mon-app", target_id=t.id, spec={"name": "mon-app", "services": []})
    session.add(app)
    session.commit()
    run = Run(app_id=app.id, rq_job_id="job-kind")
    session.add(run)
    session.commit()
    step = Step(run_id=run.id, name="check_prereqs", ordinal=0)
    session.add(step)
    session.commit()
    assert step.kind is StepKind.ENGINE


def test_app_sans_cible_est_refusee(session):
    """target_id est obligatoire : une App sans cible n'a pas de sens (c'est
    elle qui dit à l'engine et au worker où déployer)."""
    app = App(name="sans-cible", target_id=None, spec={"name": "sans-cible", "services": []})
    session.add(app)
    with pytest.raises(IntegrityError):
        session.commit()
    session.rollback()


def test_suppression_dune_cible_utilisee_est_refusee(session):
    """RESTRICT (Target -> App) : une cible qui héberge une App ne doit
    jamais être effacée en silence, sous peine de laisser l'App avec un
    target_id fantôme."""
    t = _cible(session)
    app = App(name="mon-app", target_id=t.id, spec={"name": "mon-app", "services": []})
    session.add(app)
    session.commit()

    session.delete(t)
    with pytest.raises(IntegrityError):
        session.commit()
    session.rollback()

    # La cible et son App sont toujours là : la suppression a bien été refusée.
    assert session.get(Target, t.id) is not None
    assert session.get(App, app.id) is not None


def test_suppression_dune_app_emporte_ses_runs(session):
    """CASCADE (App -> Run) : un Run est un historique d'exécution qui n'a
    pas de sens sans son App ; le jalon 3 doit pouvoir détruire une
    application sans purger son historique à la main."""
    t = _cible(session)
    app = App(name="mon-app", target_id=t.id, spec={"name": "mon-app", "services": []})
    session.add(app)
    session.commit()
    run = Run(app_id=app.id, rq_job_id="job-cascade-app")
    session.add(run)
    session.commit()
    run_id = run.id

    session.delete(app)
    session.commit()

    assert session.get(Run, run_id) is None


def test_suppression_dun_run_emporte_ses_etapes(session):
    """CASCADE (Run -> Step) : une Step n'a aucune existence propre une fois
    son Run supprimé."""
    t = _cible(session)
    app = App(name="mon-app", target_id=t.id, spec={"name": "mon-app", "services": []})
    session.add(app)
    session.commit()
    run = Run(app_id=app.id, rq_job_id="job-cascade-run")
    session.add(run)
    session.commit()
    step = Step(run_id=run.id, name="check_prereqs", ordinal=0)
    session.add(step)
    session.commit()
    step_id = step.id

    session.delete(run)
    session.commit()

    assert session.get(Step, step_id) is None


def test_suppression_dune_app_emporte_transitivement_ses_etapes(session):
    """La cascade App -> Run -> Step doit se propager sur deux niveaux : la
    suppression d'une App ne doit laisser aucune Step orpheline."""
    t = _cible(session)
    app = App(name="mon-app", target_id=t.id, spec={"name": "mon-app", "services": []})
    session.add(app)
    session.commit()
    run = Run(app_id=app.id, rq_job_id="job-cascade-transitive")
    session.add(run)
    session.commit()
    step = Step(run_id=run.id, name="check_prereqs", ordinal=0)
    session.add(step)
    session.commit()
    step_id = step.id

    session.delete(app)
    session.commit()

    assert session.get(Step, step_id) is None
