"""Chiffrement symétrique des secrets stockés en base.

Ce qui est chiffré : mot de passe SSH d'une cible, token Docker Hub, token
GitHub — et, plus tard, mot de passe de l'API BunkerWeb (jalon 4) et clé API
du LLM (jalon 5).

Ce qui ne l'est pas : hôtes, utilisateurs, ports, CHEMINS de clés SSH (un
chemin n'est pas un secret ; la clé, elle, est un secret Docker monté en
lecture seule dans le worker), spec.json, statuts, logs.

Le déchiffrement n'a lieu que dans le processus WORKER, au moment d'écrire
runs/<slug>/env.json (cf. panel/runspace.py). Le processus panel chiffre à
l'entrée et ne déchiffre jamais : aucun endpoint ne renvoie un secret.
"""
from functools import lru_cache

from cryptography.fernet import Fernet, InvalidToken

from panel.settings import get_settings


class SecretError(RuntimeError):
    """Clé absente/invalide, ou jeton illisible avec la clé courante."""


@lru_cache
def _box() -> Fernet:
    key = get_settings().secret_key
    try:
        return Fernet(key.encode())
    except (ValueError, TypeError) as exc:
        raise SecretError(
            "PANEL_SECRET_KEY invalide : 32 octets encodés en base64 url-safe "
            "attendus (Fernet.generate_key())"
        ) from exc


def encrypt(clair: str) -> str:
    """Chiffre une chaîne en clair et renvoie le jeton Fernet à stocker tel quel."""
    return _box().encrypt(clair.encode()).decode()


def decrypt(jeton: str) -> str:
    """Déchiffre un jeton Fernet et renvoie la chaîne en clair d'origine."""
    try:
        return _box().decrypt(jeton.encode()).decode()
    except InvalidToken as exc:
        raise SecretError(
            "secret illisible : jeton corrompu, ou chiffré avec une autre "
            "PANEL_SECRET_KEY"
        ) from exc


def encrypt_optional(clair: str | None) -> str | None:
    """Variante de encrypt() qui laisse passer None (champ facultatif en base)."""
    return None if clair is None else encrypt(clair)


def decrypt_optional(jeton: str | None) -> str | None:
    """Variante de decrypt() qui laisse passer None (champ facultatif en base)."""
    return None if jeton is None else decrypt(jeton)
