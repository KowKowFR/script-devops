"""Validation du spec et, surtout, du nom d'application (D5).

Le nom d'application devient, ailleurs dans le panneau, le nom du workspace,
le sous-répertoire de travail, le nom de projet Compose et le nom du réseau
Docker. Ce fichier attaque la regex qui le protège avec les mêmes vecteurs
que ceux qui ont historiquement traversé une validation trop permissive :
traversée de chemin, ancre de fin mal posée, caractères qui ressemblent à des
lettres ASCII sans en être, octets de contrôle injectés.
"""
import re

import pytest
from pydantic import ValidationError

from panel.spec import AppSpec, valider_nom_application


def _spec(**kw) -> dict:
    base = {"name": "mon-app",
            "services": [{"id": "api", "build": "./services/api", "port": 3000,
                          "health": "/health", "expose": "/api/"}]}
    base.update(kw)
    return base


# --- Le nom d'application : la vraie barrière -------------------------------

@pytest.mark.parametrize("nom", ["a" * 31, "mon-app", "app1", "web-front-2", "aa"])
def test_noms_valides(nom):
    assert AppSpec.model_validate(_spec(name=nom)).name == nom


@pytest.mark.parametrize("nom", [
    "../foo",            # traversée de chemin — le bug historique du jalon 1
    "..",
    ".",                 # répertoire courant
    "/etc/passwd",
    "A_b",               # majuscule + underscore
    "MonApp",
    "1app",               # ne commence pas par une lettre
    "-app",               # commence par un tiret
    "a",                  # trop court (2 caractères minimum)
    "a" * 32,             # 32 caractères : un de trop
    "mon app",            # espace
    "mon.app",
    "mon;app",
    "mon-app\n",          # une regex non ancrée sur la chaîne ENTIÈRE laisserait passer ceci
    "mon-app\r\n",
    "mon\x00app",         # octet nul injecté
    "\x00",
    "",                   # chaîne vide
    "mоn-app",            # 'о' cyrillique (U+043E) à la place du 'o' latin
    "mon-аpp",            # 'а' cyrillique (U+0430) à la place du 'a' latin
    "ｍｏｎ－ａｐｐ",          # variantes pleine chasse (fullwidth) de lettres/tiret ASCII
])
def test_noms_invalides(nom):
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(name=nom))


def test_le_nom_du_panneau_est_accepte_par_lengine():
    """La regex du panneau est un sous-ensemble strict de celle de l'engine
    (^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$, docs/ENGINE.md §1) : tout ce que le
    panneau accepte, l'engine l'accepte aussi."""
    engine_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$")
    for nom in ["mon-app", "a1", "a" * 31, "z-9-z", "aa"]:
        assert engine_re.match(AppSpec.model_validate(_spec(name=nom)).name)


# --- La garde de dernier recours (valider_nom_application) ------------------

@pytest.mark.parametrize("nom", ["mon-app", "a" * 31, "aa"])
def test_valider_nom_application_accepte_les_noms_valides(nom):
    assert valider_nom_application(nom) == nom


@pytest.mark.parametrize("nom", [
    "../foo", "..", ".", "/etc/passwd", "A_b", "1app", "-app", "a", "a" * 32,
    "mon app", "mon-app\n", "mon\x00app", "\x00", "",
    "mоn-app", "mon-аpp",
])
def test_valider_nom_application_refuse_les_tentatives_devasion(nom):
    with pytest.raises(ValueError):
        valider_nom_application(nom)


# --- Cohérence d'un service ---------------------------------------------------

def test_un_service_exige_build_ou_image_mais_pas_les_deux():
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(services=[{"id": "api", "port": 3000}]))
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(services=[
            {"id": "api", "build": "./a", "image": "nginx:alpine", "port": 3000}]))


def test_ids_de_service_uniques_et_conformes():
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(services=[
            {"id": "api", "build": "./a", "port": 3000},
            {"id": "api", "build": "./b", "port": 3001}]))
    with pytest.raises(ValidationError):
        # spec_init (engine/lib/config.sh) refuse déjà ces ids ; le panneau ne
        # doit jamais produire un spec que l'engine rejettera en code 2.
        AppSpec.model_validate(_spec(services=[{"id": "a b", "build": "./a", "port": 3000}]))


def test_expose_et_internal_sont_exclusifs():
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(services=[
            {"id": "db", "image": "postgres:16-alpine", "internal": True, "expose": "/"}]))


def test_expose_doit_etre_un_chemin_absolu():
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(services=[
            {"id": "api", "build": "./a", "port": 3000, "expose": "api"}]))


def test_service_expose_sans_port_conteneur_est_refuse():
    """Sans 'port', la ligne 'ports:' de gen_compose.sh (bind:hôte:conteneur)
    se retrouverait avec un port conteneur vide — un compose.yml cassé,
    découvert seulement au déploiement plutôt qu'à la saisie."""
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(services=[
            {"id": "web", "image": "nginx:alpine", "expose": "/"}]))


def test_au_moins_un_service_expose():
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(services=[
            {"id": "db", "image": "postgres:16-alpine", "internal": True}]))


def test_deux_services_ne_peuvent_pas_exposer_le_meme_chemin():
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(services=[
            {"id": "api", "build": "./a", "port": 3000, "expose": "/"},
            {"id": "web", "build": "./b", "port": 8080, "expose": "/"}]))


def test_extra_forbid_sur_appspec_et_servicespec():
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(unknown_field=True))
    with pytest.raises(ValidationError):
        AppSpec.model_validate(_spec(services=[
            {"id": "api", "build": "./a", "port": 3000, "expose": "/", "unknown": 1}]))


# --- Le contrat C3 : to_engine_json() ---------------------------------------

def test_to_engine_json_est_le_contrat_c3():
    spec = AppSpec.model_validate(_spec())
    brut = spec.to_engine_json()
    assert brut == {"name": "mon-app",
                    "services": [{"id": "api", "build": "./services/api", "port": 3000,
                                  "health": "/health", "expose": "/api/"}]}
    # Les champs absents ne doivent pas apparaître à null : spec_get distingue
    # « absent » de « null » mais gen_compose.sh lit des chaînes.
    assert "image" not in brut["services"][0]
    assert "env" not in brut["services"][0]
    assert "volumes" not in brut["services"][0]
    assert "internal" not in brut["services"][0]


def test_to_engine_json_avec_service_interne_complet():
    spec = AppSpec.model_validate(_spec(services=[
        {"id": "api", "build": "./services/api", "port": 3000, "expose": "/api/"},
        {"id": "db", "image": "postgres:16-alpine", "internal": True,
         "env": {"POSTGRES_PASSWORD": "changeme"},
         "volumes": ["pgdata:/var/lib/postgresql/data"]},
    ]))
    brut = spec.to_engine_json()
    db = next(s for s in brut["services"] if s["id"] == "db")
    assert db == {"id": "db", "image": "postgres:16-alpine", "internal": True,
                  "env": {"POSTGRES_PASSWORD": "changeme"},
                  "volumes": ["pgdata:/var/lib/postgresql/data"]}
