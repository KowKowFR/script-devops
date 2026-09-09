"""Journal : nettoyage ANSI, écriture fichier, publication Redis."""
import json

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
