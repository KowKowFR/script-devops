"""Provisoire — bouchon minimal pour la tâche 5 (panel/pipeline.py).

Ce fichier n'appartient PAS au périmètre de la tâche 5 : le modèle de données
complet (User, Target, App, Run, Step et tous les enums) est la tâche 3,
rédigée en parallèle par un autre agent dans un worktree isolé. Comme les
worktrees ne partagent rien avant la fusion, ce module ne peut pas être vu ici
et panel/pipeline.py ne peut pas être exécuté sans lui.

Ce bouchon ne définit QUE `StepKind`, à l'identique de ce que la tâche 3
prévoit (cf. docs/superpowers/plans/2026-09-08-jalon-2-panel-fastapi.md,
section Task 3, Step 2). Il doit être remplacé par le panel/models.py complet
lors de la fusion des branches — voir task-5-report.md pour le signalement.
"""
from enum import Enum


class StepKind(str, Enum):
    """D1 : deux natures d'étape. `engine` appelle bootstrap.sh, `python`
    appelle un enregistré de panel/worker/steps_py.py."""

    ENGINE = "engine"
    PYTHON = "python"
