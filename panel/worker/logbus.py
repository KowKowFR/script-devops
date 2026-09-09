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
import logging
import re
import time
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# Séquences CSI, OSC et codes à un caractère. Volontairement large : mieux vaut
# retirer une séquence exotique que la voir s'afficher telle quelle dans l'UI.
_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")


def strip_ansi(ligne: str) -> str:
    """Retire les séquences d'échappement ANSI (couleurs, curseur, etc.) d'une ligne."""
    return _ANSI.sub("", ligne)


def canal(run_id: int) -> str:
    """Nom du canal Redis pub/sub dédié à un run — un canal par run, jamais partagé,
    pour que deux runs simultanés ne mélangent jamais leurs flux de logs.

    `int(run_id)` assainit volontairement l'entrée : `SUBSCRIBE` fait un match
    exact (contrairement à `PSUBSCRIBE`), donc un run_id contenant `*`/`?`/`:`
    n'est pas exploitable aujourd'hui — mais si un futur consommateur bascule
    sur du pattern-matching, un identifiant non numérique pourrait fabriquer un
    joker et faire fuiter les logs d'un run vers un autre. Autant fermer la
    porte ici : un run_id qui n'est pas un entier propre lève franchement,
    plutôt que de produire un canal surprenant.
    """
    return f"run:{int(run_id)}:logs"


class LogBus:
    """Journal d'un run unique : écrit chaque ligne dans un fichier (source de
    vérité, relue par la tâche 18) et la publie sur le canal Redis du run
    (confort d'affichage temps réel, rien de plus).

    Utilisable comme gestionnaire de contexte pour garantir la fermeture du
    fichier même si l'appelant lève une exception en cours de run.
    """

    def __init__(self, redis: Any, run_id: int, log_path: Path) -> None:
        self._redis = redis
        self._run_id = run_id
        self._canal = canal(run_id)
        # Une seule alerte par instance : si Redis tombe au milieu d'un run de
        # plusieurs milliers de lignes, on ne veut pas un warning par ligne —
        # juste savoir, une fois, que l'affichage temps réel est mort.
        self._panne_redis_signalee = False
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
        except Exception as exc:
            # Une panne de Redis dégrade l'affichage temps réel ; elle ne doit
            # jamais faire échouer un déploiement en cours. Le fichier reste la
            # source de vérité — on avale volontairement toute exception ici,
            # `Exception` large et pas seulement `ConnectionError` : Redis peut
            # aussi refuser la publication pour d'autres raisons (timeout,
            # mémoire pleine, ACL, erreur de sérialisation…) et aucune de ces
            # causes ne doit faire échouer le run.
            #
            # Mais avaler ne veut pas dire faire disparaître : sans trace, une
            # panne Redis est invisible en production (l'affichage live meurt,
            # rien ne le signale). On journalise donc — une seule fois par run,
            # pas une fois par ligne, pour ne pas noyer les logs si Redis reste
            # indisponible pendant des milliers de lignes.
            if not self._panne_redis_signalee:
                self._panne_redis_signalee = True
                logger.warning(
                    "run %s : publication Redis indisponible (%s), "
                    "l'affichage temps réel est dégradé — le fichier de log reste la source de vérité",
                    self._run_id,
                    exc,
                )

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
