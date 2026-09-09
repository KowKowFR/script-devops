"""Panneau DeployMatic — UI et API FastAPI, worker RQ.

Ce paquet orchestre `engine/bootstrap.sh` étape par étape, sans jamais le
sourcer ni importer une fonction bash : voir `docs/ENGINE.md` pour le contrat
d'appel et `docs/superpowers/plans/2026-09-08-jalon-2-panel-fastapi.md` pour
l'architecture du jalon.
"""

__version__ = "0.2.0"
