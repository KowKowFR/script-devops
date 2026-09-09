"""Diffusion des logs d'un run : fichier durable + Redis pub/sub temps réel.

Les deux ne servent pas la même chose. Redis pub/sub ne CONSERVE rien : c'est
le flux temps réel que le SSE consomme. Le fichier est ce que lit quelqu'un qui
ouvre la page d'un run terminé (tâche 18). Les deux reçoivent la MÊME ligne,
déjà nettoyée de ses séquences ANSI — l'engine colore ses sorties, et ces codes
n'ont aucun sens dans un <pre> HTML.

L'engine écrit ses logs ligne par ligne sur stderr, en continu, pendant parfois
plusieurs minutes (ex. `prepare_server`). `LogBus` ne bufferise donc jamais :
chaque appel à `emit_log`/`emit_event` écrit et publie immédiatement, pour que
l'utilisateur voie les logs défiler en direct plutôt qu'un bloc à la fin.
"""
import json
import re
import time
from pathlib import Path
from typing import Any

# Séquences CSI, OSC et codes à un caractère. Volontairement large : mieux vaut
# retirer une séquence exotique que la voir s'afficher telle quelle dans l'UI.
_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")


def strip_ansi(ligne: str) -> str:
    """Retire les séquences d'échappement ANSI (couleurs, curseur, etc.) d'une ligne."""
    return _ANSI.sub("", ligne)


def canal(run_id: int) -> str:
    """Nom du canal Redis pub/sub dédié à un run — un canal par run, jamais partagé,
    pour que deux runs simultanés ne mélangent jamais leurs flux de logs."""
    return f"run:{run_id}:logs"


class LogBus:
    """Journal d'un run unique : écrit chaque ligne dans un fichier (source de
    vérité, relue par la tâche 18) et la publie sur le canal Redis du run
    (confort d'affichage temps réel, rien de plus).

    Utilisable comme gestionnaire de contexte pour garantir la fermeture du
    fichier même si l'appelant lève une exception en cours de run.
    """

    def __init__(self, redis: Any, run_id: int, log_path: Path) -> None:
        self._redis = redis
        self._canal = canal(run_id)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        # buffering=1 : ligne à ligne, pas de tampon qui retarderait l'écriture
        # jusqu'à la fin du run — cohérent avec l'objectif de flux continu.
        self._fichier = open(log_path, "a", encoding="utf-8", buffering=1)

    def emit_log(self, step: str, ligne: str) -> None:
        """Écrit et publie une ligne de log rattachée à une étape donnée."""
        propre = strip_ansi(ligne.rstrip("\n"))
        self._fichier.write(f"[{step}] {propre}\n")
        self._publier({"t": "log", "step": step, "line": propre})

    def emit_event(self, type_: str, **champs: Any) -> None:
        """Publie un événement de contrôle (changement d'étape, fin de run…),
        sans l'écrire dans le fichier de logs : ce n'est pas une ligne de sortie
        de l'engine, juste une notification pour l'interface."""
        self._publier({"t": type_, **champs})

    def _publier(self, message: dict) -> None:
        message["ts"] = time.time()
        try:
            self._redis.publish(self._canal, json.dumps(message, ensure_ascii=False))
        except Exception:
            # Une panne de Redis dégrade l'affichage temps réel ; elle ne doit
            # jamais faire échouer un déploiement en cours. Le fichier reste la
            # source de vérité — on avale volontairement toute exception ici,
            # y compris au-delà de ConnectionError (Redis peut aussi refuser
            # l'écriture pour d'autres raisons : mémoire pleine, ACL, etc.).
            pass

    def close(self) -> None:
        """Ferme le fichier. Ne lève jamais — appelée aussi depuis `__exit__`
        pendant un déroulement d'exception, elle ne doit pas en masquer une autre."""
        try:
            self._fichier.close()
        except Exception:
            pass

    def __enter__(self) -> "LogBus":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()
