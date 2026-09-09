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
