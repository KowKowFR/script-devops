"""Le chiffrement des secrets : aller-retour, détection de corruption, clé invalide."""
import traceback

import pytest

from panel import crypto
from panel.crypto import SecretError, decrypt, decrypt_optional, encrypt, encrypt_optional
from panel.settings import get_settings


@pytest.fixture(autouse=True)
def _caches_propres():
    """Vide le cache de configuration ET celui de la boîte Fernet.

    `get_settings()` et `_box()` sont chacun mis en cache séparément : une
    fixture qui ne viderait que le premier laisserait un test suivant
    réutiliser une boîte construite avec une clé déjà remplacée — un piège
    silencieux le jour où une suite change de clé en cours d'exécution.
    """
    get_settings.cache_clear()
    crypto._box.cache_clear()
    yield
    get_settings.cache_clear()
    crypto._box.cache_clear()


def _aucune_fuite(exc_info, *fragments: str) -> None:
    """Vérifie qu'aucun des `fragments` (la clé, un extrait) n'apparaît :
    - dans le message de l'exception ;
    - dans sa trace complète formatée (`traceback.format_exception`), celle
      qu'afficherait un gestionnaire de log générique ;
    - dans `__cause__` ET dans `__context__` pris isolément — un code qui
      parcourt la chaîne d'exceptions sans respecter le drapeau
      `__suppress_context__` (agrégateur d'erreurs, débogueur, `f"{e} / cause :
      {e.__context__}"`) verrait sinon encore la clé, `from None` ne
      protégeant que l'affichage par défaut, pas l'objet `__context__` lui-même.

    Exige en plus que `__context__` soit strictement `None`, pas seulement
    dépourvu du fragment : c'est la seule garantie qui tienne quelle que soit
    l'exception d'origine.
    """
    exc = exc_info.value
    message = str(exc)
    trace = "".join(
        traceback.format_exception(exc_info.type, exc, exc_info.tb)
    )
    assert exc.__context__ is None, (
        f"__context__ n'est pas None : {exc.__context__!r} — "
        "la chaîne implicite fuit encore, même si l'affichage la masque"
    )
    cause_texte = str(exc.__cause__)
    contexte_texte = str(exc.__context__)
    for fragment in fragments:
        assert fragment not in message
        assert fragment not in trace
        assert fragment not in cause_texte
        assert fragment not in contexte_texte


def test_aller_retour():
    assert decrypt(encrypt("dckr_pat_secret")) == "dckr_pat_secret"


def test_le_chiffre_ne_contient_pas_le_clair():
    jeton = encrypt("dckr_pat_secret")
    assert "dckr_pat_secret" not in jeton
    assert jeton.startswith("gAAAAA")          # en-tête Fernet v1


def test_deux_chiffrements_du_meme_clair_different():
    # Fernet embarque un IV aléatoire : sans ça, deux cibles au même mot de
    # passe seraient reconnaissables par simple comparaison de colonnes.
    assert encrypt("meme-secret") != encrypt("meme-secret")


def test_jeton_corrompu_est_refuse():
    jeton = encrypt("secret")
    with pytest.raises(SecretError):
        decrypt(jeton[:-4] + "AAAA")


def test_optionnels():
    assert encrypt_optional(None) is None
    assert decrypt_optional(None) is None
    assert decrypt_optional(encrypt_optional("x")) == "x"


def test_chaine_vide_reste_distincte_de_none():
    assert encrypt_optional("") is not None
    assert decrypt_optional(encrypt_optional("")) == ""


# --- Clé invalide : chaque scénario doit échouer clair, immédiat, sans fuite ---


def test_cle_absente_leve_secreterror(monkeypatch):
    monkeypatch.delenv("PANEL_SECRET_KEY", raising=False)
    with pytest.raises(SecretError) as exc_info:
        encrypt("x")
    _aucune_fuite(exc_info)
    assert "PANEL_SECRET_KEY" in str(exc_info.value)


def test_cle_trop_courte_leve_secreterror(monkeypatch):
    cle = "trop-courte-1234"
    monkeypatch.setenv("PANEL_SECRET_KEY", cle)
    with pytest.raises(SecretError) as exc_info:
        encrypt("x")
    _aucune_fuite(exc_info, cle)


def test_cle_non_base64_leve_secreterror(monkeypatch):
    # 44 caractères, longueur correcte, mais hors alphabet base64 url-safe.
    cle = "!" * 43 + "="
    monkeypatch.setenv("PANEL_SECRET_KEY", cle)
    with pytest.raises(SecretError) as exc_info:
        encrypt("x")
    _aucune_fuite(exc_info, cle)


def test_cle_avec_espaces_leve_secreterror(monkeypatch):
    cle_propre = "0" * 43 + "="
    cle = f" {cle_propre} "
    monkeypatch.setenv("PANEL_SECRET_KEY", cle)
    with pytest.raises(SecretError) as exc_info:
        encrypt("x")
    _aucune_fuite(exc_info, cle, cle_propre)


def test_cle_avec_retour_a_la_ligne_leve_secreterror(monkeypatch):
    cle_propre = "0" * 43 + "="
    cle = cle_propre + "\n"
    monkeypatch.setenv("PANEL_SECRET_KEY", cle)
    with pytest.raises(SecretError) as exc_info:
        encrypt("x")
    _aucune_fuite(exc_info, cle, cle_propre)


# --- La spécificité de l'exception attrapée au déchiffrement ---


def test_decrypt_dune_valeur_non_chaine_nest_pas_maquille_en_secreterror():
    # decrypt() attend un jeton str ; passer None doit lever l'AttributeError
    # naturelle de `.encode()`, pas un SecretError trompeur. Un futur
    # `except Exception` avalerait cette vraie erreur de programmation.
    with pytest.raises(AttributeError):
        decrypt(None)  # type: ignore[arg-type]
