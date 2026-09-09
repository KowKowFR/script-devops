"""La séquence d'étapes — une CONSTANTE Python, pas une table.

Pourquoi pas une table : la séquence est du code, elle change avec le code, et
une table qui la duplique se désynchronise silencieusement du jour où quelqu'un
déploie une nouvelle version sans migrer les lignes. `Step` (panel/models.py)
enregistre les INSTANCES d'exécution ; PIPELINE décrit la partition.

Contrat C2 : ce fichier et la constante STEPS de engine/bootstrap.sh sont
dupliqués À DESSEIN. tests/test_pipeline.py confronte les deux à chaque
exécution de la suite — c'est ce qui rend la duplication tenable.
"""
from dataclasses import dataclass

from panel.models import StepKind


@dataclass(frozen=True, slots=True)
class StepDef:
    """Définition d'une étape.

    name           nom de l'étape ; pour kind=ENGINE, le --step passé à bootstrap.sh
    kind           D1 : ENGINE (subprocess) ou PYTHON (appelable enregistré)
    always_rerun   D2 : True = rejouée à chaque run ; False = `skipped` si déjà `ok`
    requires_flag  chemin pointé d'env.json ; l'étape est `skipped` si le drapeau
                   n'est pas vrai (ex. "github.enabled")
    python_handler clé dans le registre de panel/worker/steps_py.py (kind=PYTHON)
    """

    name: str
    kind: StepKind
    always_rerun: bool
    requires_flag: str | None = None
    python_handler: str | None = None


def _engine(name: str, *, always_rerun: bool, requires_flag: str | None = None) -> StepDef:
    return StepDef(name=name, kind=StepKind.ENGINE, always_rerun=always_rerun,
                    requires_flag=requires_flag)


PIPELINE: tuple[StepDef, ...] = (
    # --- Nature python : matérialise runs/<slug>/ avant tout appel à l'engine.
    StepDef(name="prepare_workspace", kind=StepKind.PYTHON, always_rerun=True,
            python_handler="prepare_workspace"),

    # --- Vérifications : coût nul, résultat périssable → toujours rejouées.
    _engine("check_prereqs", always_rerun=True),
    _engine("validate_ssh", always_rerun=True),

    # --- Effet durable sur la cible → sauté si déjà ok pour cette application.
    _engine("create_project_dir", always_rerun=False),

    # --- Générateurs : leur sortie dépend du spec COURANT. Les rejouer est le
    #     seul moyen qu'un spec modifié se reflète dans les fichiers générés.
    _engine("generate_microservices", always_rerun=True),
    _engine("generate_compose", always_rerun=True),
    _engine("generate_skills", always_rerun=True),
    _engine("generate_workflow", always_rerun=True),

    # --- Provisionnement : coûteux, idempotent côté engine, mais lent. Sauté.
    _engine("enable_sudo_nopasswd", always_rerun=False),
    _engine("prepare_server", always_rerun=False),

    # --- Build et déploiement : c'est le cœur d'un run, jamais sauté.
    _engine("build_images", always_rerun=True),
    _engine("deploy_stack", always_rerun=True),
    _engine("validate_deployment", always_rerun=True),

    # --- Bloc GitHub, optionnel. engine/lib/steps.sh court-circuite proprement
    #     (skipped=true) quand github.enabled est faux ; requires_flag rend
    #     cette condition visible et testable côté panneau, sans lancer l'engine.
    _engine("github_create_repo", always_rerun=False, requires_flag="github.enabled"),
    _engine("github_set_secrets", always_rerun=False, requires_flag="github.enabled"),
    _engine("git_init", always_rerun=False, requires_flag="github.enabled"),
    _engine("git_push", always_rerun=False, requires_flag="github.enabled"),
)

_INDEX = {s.name: s for s in PIPELINE}


def step_def(name: str) -> StepDef:
    """Renvoie la définition de l'étape `name`. Lève `KeyError` si inconnue."""
    return _INDEX[name]


def engine_step_names() -> tuple[str, ...]:
    """Les noms d'étapes de nature `engine`, dans l'ordre du pipeline — c'est
    ce que le test de parité confronte à `bootstrap.sh --list-steps`."""
    return tuple(s.name for s in PIPELINE if s.kind is StepKind.ENGINE)
