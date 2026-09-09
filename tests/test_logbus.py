"""Journal : nettoyage ANSI, écriture fichier, publication Redis."""
import json
import logging

import fakeredis

from panel.worker.logbus import LogBus, canal, strip_ansi


def test_strip_ansi():
    assert strip_ansi("\x1b[32m✓\x1b[0m Docker présent") == "✓ Docker présent"
    assert strip_ansi("\x1b[1;31mErreur\x1b[0m") == "Erreur"
    assert strip_ansi("rien à nettoyer") == "rien à nettoyer"
    assert strip_ansi("\x1b[2K\x1b[1Gprogression") == "progression"


def test_les_logs_partent_dans_le_fichier_et_dans_redis(tmp_path):
    r = fakeredis.FakeStrictRedis()
    pubsub = r.pubsub()
    pubsub.subscribe(canal(7))
    pubsub.get_message(timeout=1)                       # message de souscription

    chemin = tmp_path / "run.log"
    with LogBus(r, run_id=7, log_path=chemin) as bus:
        bus.emit_log("check_prereqs", "\x1b[32m✓\x1b[0m jq présent")
        bus.emit_event("step", step="check_prereqs", status="ok")

    contenu = chemin.read_text()
    assert "✓ jq présent" in contenu
    assert "\x1b[" not in contenu                        # l'ANSI est nettoyé À L'ÉCRITURE

    messages = []
    while (m := pubsub.get_message(timeout=0.5)):
        if m["type"] == "message":
            messages.append(json.loads(m["data"]))
    assert messages[0]["t"] == "log" and messages[0]["line"] == "✓ jq présent"
    assert messages[1]["t"] == "step" and messages[1]["status"] == "ok"


def test_une_panne_redis_ninterrompt_pas_le_run(tmp_path, monkeypatch):
    """Le journal est de l'observabilité, pas du déploiement. Si Redis tombe,
    le run doit continuer et le fichier rester complet."""
    class RedisCasse:
        def publish(self, *a, **k):
            raise ConnectionError("redis down")

    chemin = tmp_path / "run.log"
    with LogBus(RedisCasse(), run_id=7, log_path=chemin) as bus:
        bus.emit_log("etape", "une ligne")
    assert "une ligne" in chemin.read_text()


def test_chaque_ligne_est_visible_au_fichier_pendant_le_run_pas_seulement_a_la_fin(tmp_path):
    """Le point qui compte pour l'engine : `prepare_server` peut tourner plusieurs
    minutes, donc le fichier ne doit PAS attendre le vidage final du buffer
    (fermeture du fichier / fin du `with`) pour contenir les lignes déjà
    émises. On relit `chemin` DEPUIS L'INTÉRIEUR du bloc, entre deux emit_log,
    ce qu'aucun autre test ne fait — un test qui relit seulement après la
    fermeture ne distinguerait pas un flux ligne à ligne d'un flux bufferisé
    jusqu'à la fin."""
    r = fakeredis.FakeStrictRedis()
    chemin = tmp_path / "run.log"
    with LogBus(r, run_id=11, log_path=chemin) as bus:
        bus.emit_log("etape", "première ligne")
        # Le `with` n'est pas encore sorti, `close()` n'a pas été appelé : si
        # le fichier ne rendait ses écritures qu'à la fermeture, cette lecture
        # verrait un fichier vide.
        assert "première ligne" in chemin.read_text()

        bus.emit_log("etape", "deuxième ligne")
        contenu = chemin.read_text()
        assert "première ligne" in contenu
        assert "deuxième ligne" in contenu


def test_une_panne_redis_dun_autre_type_ninterrompt_pas_le_run(tmp_path):
    """`except Exception` doit intercepter N'IMPORTE QUELLE panne de publication,
    pas seulement `ConnectionError` (déjà couvert par le test précédent). On
    utilise ici un type totalement différent (TimeoutError) pour ne pas laisser
    passer un `except ConnectionError` trop étroit."""
    class RedisCasseAutrement:
        def publish(self, *a, **k):
            raise TimeoutError("le serveur Redis ne répond pas")

    chemin = tmp_path / "run.log"
    with LogBus(RedisCasseAutrement(), run_id=7, log_path=chemin) as bus:
        bus.emit_log("etape", "une ligne malgré un TimeoutError")
    assert "une ligne malgré un TimeoutError" in chemin.read_text()


def test_une_panne_redis_est_journalisee_une_seule_fois_par_run(tmp_path, caplog):
    """La panne ne doit pas être totalement silencieuse (sinon personne ne sait
    que l'affichage temps réel est mort) — mais elle ne doit pas non plus
    produire un avertissement par ligne : sur un run de plusieurs milliers de
    lignes avec Redis indisponible, ce serait des milliers d'entrées
    identiques dans les logs du worker."""
    class RedisCasse:
        def publish(self, *a, **k):
            raise ConnectionError("redis down")

    chemin = tmp_path / "run.log"
    with caplog.at_level(logging.WARNING, logger="panel.worker.logbus"):
        with LogBus(RedisCasse(), run_id=7, log_path=chemin) as bus:
            for i in range(5):
                bus.emit_log("etape", f"ligne {i}")

    avertissements = [r for r in caplog.records if r.levelno >= logging.WARNING]
    assert len(avertissements) == 1, (
        f"attendu un seul avertissement pour 5 lignes en échec, obtenu {len(avertissements)}"
    )


def test_le_fichier_est_cree_avec_ses_parents(tmp_path):
    chemin = tmp_path / "logs" / "sous" / "run.log"
    with LogBus(fakeredis.FakeStrictRedis(), run_id=1, log_path=chemin) as bus:
        bus.emit_log("e", "x")
    assert chemin.exists()


def test_deux_runs_simultanes_ne_melangent_pas_leurs_canaux(tmp_path):
    """Chaque run publie sur son propre canal Redis : un abonné au run 1 ne doit
    jamais recevoir un message émis pour le run 2, même en parallèle."""
    r = fakeredis.FakeStrictRedis()
    pubsub_1 = r.pubsub()
    pubsub_1.subscribe(canal(1))
    pubsub_1.get_message(timeout=1)

    with LogBus(r, run_id=1, log_path=tmp_path / "1.log") as bus_1, \
            LogBus(r, run_id=2, log_path=tmp_path / "2.log") as bus_2:
        bus_1.emit_log("etape", "ligne du run 1")
        bus_2.emit_log("etape", "ligne du run 2")

    messages = []
    while (m := pubsub_1.get_message(timeout=0.5)):
        if m["type"] == "message":
            messages.append(json.loads(m["data"]))
    assert len(messages) == 1
    assert messages[0]["line"] == "ligne du run 1"


def test_ligne_avec_retour_chariot_et_tres_longue_ne_casse_rien(tmp_path):
    """Une ligne avec \\r (barre de progression) ou très longue doit être
    absorbée sans exception et retrouvée intacte dans le fichier.

    On lit en octets bruts : `Path.read_text()` fait de la traduction
    universal-newline à la LECTURE et transformerait \\r en \\n, masquant le
    comportement réel de l'écriture qu'on veut vérifier ici."""
    r = fakeredis.FakeStrictRedis()
    ligne_longue = "x" * 20000
    chemin = tmp_path / "run.log"
    with LogBus(r, run_id=3, log_path=chemin) as bus:
        bus.emit_log("etape", "progression\r50%\r100%")
        bus.emit_log("etape", ligne_longue)

    contenu = chemin.read_bytes().decode("utf-8")
    assert "progression\r50%\r100%" in contenu
    assert ligne_longue in contenu
