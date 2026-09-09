"""Le modèle de données du panneau.

La SÉQUENCE d'étapes n'est pas une table : c'est panel/pipeline.py, versionné
avec le code. `Step` n'enregistre que des INSTANCES d'exécution — et c'est
cette table qui porte l'idempotence (cf. D2), à la place de l'ancien fichier
d'état .bootstrap-state.
"""
from datetime import datetime, timezone
from enum import Enum

from sqlalchemy import JSON, Column
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
    id: int | None = Field(default=None, primary_key=True)
    # name == slug == workspace == répertoire == projet Compose == réseau Docker
    # Validé par ^[a-z][a-z0-9-]{1,30}$ AVANT l'insertion (D5, panel/spec.py).
    # unique=True + index=True (et non une UniqueConstraint séparée) : un seul
    # index, comme Target.name et User.username.
    name: str = Field(unique=True, index=True, max_length=31)
    # RESTRICT : une cible qui héberge des applications ne doit jamais être
    # supprimée en silence — l'App resterait avec un target_id fantôme.
    # Il faut d'abord réassigner ou supprimer les Apps qui la référencent.
    target_id: int = Field(foreign_key="target.id", ondelete="RESTRICT")
    spec: dict = Field(sa_column=Column(JSON), default_factory=dict)
    env: dict = Field(sa_column=Column(JSON), default_factory=dict)   # NON secret
    secrets_enc: str | None = None                                   # blob opaque (Fernet, worker)
    status: AppStatus = Field(default=AppStatus.NEW)
    created_at: datetime = Field(default_factory=_now)
    updated_at: datetime = Field(default_factory=_now)

    @property
    def slug(self) -> str:
        """Il n'y a rien à calculer : le nom EST le slug (D5)."""
        return self.name


class Run(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    # CASCADE : un Run est un historique d'exécution qui n'a pas de sens sans
    # son App ; le supprimer avec elle évite d'avoir à nettoyer l'historique
    # à la main avant de pouvoir détruire une application (jalon 3).
    app_id: int = Field(foreign_key="app.id", index=True, ondelete="CASCADE")
    trigger: RunTrigger = Field(default=RunTrigger.MANUAL)
    status: RunStatus = Field(default=RunStatus.QUEUED, index=True)
    rq_job_id: str | None = Field(default=None, index=True)   # D4
    started_at: datetime | None = None
    finished_at: datetime | None = None
    error: str | None = None
    created_at: datetime = Field(default_factory=_now)


class Step(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    # CASCADE : une Step est une instance d'exécution d'un Run précis (D2),
    # elle n'a aucune existence propre une fois ce Run supprimé.
    run_id: int = Field(foreign_key="run.id", index=True, ondelete="CASCADE")
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
