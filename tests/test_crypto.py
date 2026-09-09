"""Le chiffrement des secrets : aller-retour, détection de corruption, clé invalide."""
import pytest

from panel.crypto import SecretError, decrypt, decrypt_optional, encrypt, encrypt_optional


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
