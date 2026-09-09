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
import re
from functools import lru_cache

from cryptography.fernet import Fernet, InvalidToken
from pydantic import ValidationError

from panel.settings import get_settings


class SecretError(RuntimeError):
    """Clé absente/invalide, ou jeton illisible avec la clé courante."""


_MESSAGE_CLE_INVALIDE = (
    "PANEL_SECRET_KEY absente ou invalide : 32 octets encodés en base64 "
    "url-safe attendus, sans espace ni retour à la ligne (Fernet.generate_key())"
)

# Une clé Fernet valide fait exactement 44 caractères : 43 caractères de
# l'alphabet base64 url-safe suivis d'un unique '=' de bourrage (32 octets
# encodés). Le décodeur base64 standard ignore silencieusement les
# caractères hors alphabet (espace, "\n" en tête ou en fin de valeur après
# un copier-coller de .env) : on valide donc nous-mêmes le format exact
# avant de le tendre à Fernet, plutôt que de laisser une clé légèrement
# corrompue « marcher par accident ».
_CLE_VALIDE = re.compile(r"^[A-Za-z0-9_-]{43}=$")


@lru_cache
def _box() -> Fernet:
    """Construit (une seule fois) la boîte Fernet à partir de PANEL_SECRET_KEY.

    Aucun message d'erreur ni aucune trace ne doit jamais faire apparaître la
    valeur de la clé. `raise ... from None` ne suffit pas : il met à `None`
    le `__cause__` explicite et pose `__suppress_context__` (qui ne fait que
    demander au *formateur* de ne pas afficher la chaîne), mais Python
    remplit quand même `__context__` avec l'exception en cours de traitement
    au moment du `raise` — qui, elle, embarque la valeur reçue
    (ValidationError pydantic : `input_value=...`). Un code qui inspecte
    `__context__` directement (agrégateur d'erreurs, gestionnaire de log
    maison, débogueur) verrait donc quand même la clé.

    La seule garantie fiable : ne jamais lever `SecretError` alors qu'une
    exception est activement gérée. On collecte donc un simple drapeau dans
    chaque bloc `except`, et le `raise` final s'exécute une fois tous les
    blocs `try/except` terminés — à ce point, `sys.exc_info()` est vide et
    `SecretError.__context__` vaut `None`, pas seulement masqué à l'affichage.
    """
    cle = ""
    invalide = False

    try:
        cle = get_settings().secret_key.get_secret_value()
    except ValidationError:
        # Clé absente de l'environnement, ou trop courte : pydantic lève ici
        # avant même que ce module ne voie la valeur.
        invalide = True

    if not invalide and not _CLE_VALIDE.fullmatch(cle):
        invalide = True

    boite: Fernet | None = None
    if not invalide:
        try:
            boite = Fernet(cle.encode())
        except (ValueError, TypeError):
            invalide = True

    if invalide:
        raise SecretError(_MESSAGE_CLE_INVALIDE)

    assert boite is not None  # garanti par la construction ci-dessus
    return boite


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
