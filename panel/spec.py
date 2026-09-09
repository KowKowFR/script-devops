"""Schéma d'application — contrat C3, côté producteur.

L'engine (engine/lib/config.sh : spec_init, spec_get, spec_is_internal,
spec_is_exposed…) est le CONSOMMATEUR de ce fichier : il lit spec.json avec
jq et meurt en code 2 si le contenu ne lui convient pas — mais seulement
après avoir déjà écrit des fichiers sur la cible (create_project_dir,
generate_microservices...). Tout ce qui est refusé ici en 422 aurait donc été
refusé là-bas, en code 2, mais bien plus tard. On valide au plus tôt, à
l'entrée de l'API, avant qu'aucun octet ne parte vers l'engine.

Le nom de l'application (`AppSpec.name`) mérite une attention particulière :
c'est lui qui, ailleurs dans le panneau (panel/runspace.py, tâche 12), devient
le nom du workspace (`runs/<nom>/`), le sous-répertoire de travail, le nom de
projet Compose et le nom du réseau Docker (`<nom>-net`). Au jalon 1,
`--workspace ../../etc` était accepté par l'engine, qui construisait un
chemin par simple concaténation ; une validation stricte a depuis été ajoutée
côté engine en défense en profondeur, mais c'est ICI, à la première frontière
qui voit une saisie utilisateur, que la vraie barrière doit tenir.
"""
import re
from typing import Annotated, Any, Self

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

# D5 : sous-ensemble STRICT de la regex de workspace de l'engine
# (^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$, cf. docs/ENGINE.md §1) — minuscules
# uniquement, pas de underscore, 2 à 31 caractères. Tout ce que cette regex
# accepte, l'engine l'accepte aussi ; l'inverse n'a pas besoin d'être vrai.
APP_NAME_PATTERN = r"^[a-z][a-z0-9-]{1,30}$"
AppName = Annotated[str, StringConstraints(pattern=APP_NAME_PATTERN)]

# Sous-ensemble strict de la validation d'id de service de spec_init
# (engine/lib/config.sh : ^[A-Za-z0-9_-]+$, sans limite de longueur). La
# limite à 32 caractères ici est une marge de sécurité du panneau, pas une
# exigence de l'engine.
SERVICE_ID_PATTERN = r"^[A-Za-z0-9_-]{1,32}$"
ServiceId = Annotated[str, StringConstraints(pattern=SERVICE_ID_PATTERN)]


class ServiceSpec(BaseModel):
    """Un service de l'application — un bloc de la clé 'services' de spec.json."""

    model_config = ConfigDict(extra="forbid")

    id: ServiceId
    build: str | None = None          # service buildé → durcissement complet
    image: str | None = None          # image tierce → durcissement partiel
    port: int | None = Field(default=None, ge=1, le=65535)   # port CONTENEUR
    health: str | None = None
    expose: str | None = None         # chemin PUBLIC ; un port hôte sera publié
    internal: bool = False            # aucun port publié
    env: dict[str, str] = Field(default_factory=dict)
    volumes: list[str] = Field(default_factory=list)

    @model_validator(mode="after")
    def _coherence(self) -> Self:
        if bool(self.build) == bool(self.image):
            raise ValueError(
                f"service « {self.id} » : indiquez exactement l'un de 'build' "
                "(chemin vers le code source à builder) ou 'image' (image "
                "tierce), jamais les deux ni aucun des deux"
            )
        if self.internal and self.expose:
            raise ValueError(
                f"service « {self.id} » : 'internal' (aucun port publié) et "
                "'expose' (chemin public) s'excluent mutuellement"
            )
        if self.expose and not self.expose.startswith("/"):
            raise ValueError(
                f"service « {self.id} » : 'expose' doit être un chemin "
                "public absolu commençant par '/' (ex. '/api/')"
            )
        if self.expose and self.port is None:
            # Sans port conteneur, la ligne "ports:" générée par
            # engine/lib/gen_compose.sh (bind:port_hôte:port_conteneur) se
            # retrouve avec un port conteneur vide — un service exposé sans
            # 'port' produirait un compose.yml cassé, découvert seulement au
            # déploiement.
            raise ValueError(
                f"service « {self.id} » : un service exposé ('expose' "
                "défini) doit déclarer 'port' (le port sur lequel le "
                "conteneur écoute)"
            )
        if self.build and self.port is None:
            raise ValueError(
                f"service « {self.id} » : un service buildé doit déclarer "
                "'port' (injecté au conteneur via la variable PORT)"
            )
        return self


class AppSpec(BaseModel):
    """La description complète d'une application — la forme exacte de spec.json."""

    model_config = ConfigDict(extra="forbid")

    name: AppName
    services: list[ServiceSpec] = Field(min_length=1)

    @model_validator(mode="after")
    def _coherence(self) -> Self:
        ids = [s.id for s in self.services]
        doublons = {i for i in ids if ids.count(i) > 1}
        if doublons:
            raise ValueError(
                f"ids de service dupliqués : {', '.join(sorted(doublons))} "
                "— chaque id doit être unique (spec_init de l'engine refuse "
                "aussi ce cas)"
            )
        if not any(s.expose for s in self.services):
            raise ValueError(
                "au moins un service doit porter 'expose' : sans chemin "
                "public, l'application n'est joignable par personne"
            )
        chemins = [s.expose for s in self.services if s.expose]
        if len(set(chemins)) != len(chemins):
            raise ValueError(
                "deux services ne peuvent pas exposer le même chemin public"
            )
        return self

    def to_engine_json(self) -> dict[str, Any]:
        """La forme exacte écrite dans runs/<nom>/spec.json (contrat C3).

        exclude_none : spec_get (engine/lib/config.sh) traite un champ absent
        et un champ null de façon identique (retour du défaut), mais un
        `"image": null` explicite dans le fichier est un piège pour un
        lecteur humain — autant ne jamais l'écrire. exclude_defaults n'est
        PAS utilisé : `internal: false` explicite serait plus lisible qu'un
        champ manquant, mais gonflerait le fichier pour chaque service —
        d'où le filtrage manuel, ci-dessous, des collections vides et de
        'internal' quand il vaut son défaut.
        """
        services = []
        for s in self.services:
            d = s.model_dump(exclude_none=True)
            if not d.get("env"):
                d.pop("env", None)
            if not d.get("volumes"):
                d.pop("volumes", None)
            if d.get("internal") is False:
                d.pop("internal", None)
            services.append(d)
        return {"name": self.name, "services": services}


def valider_nom_application(nom: str) -> str:
    """Garde de dernier recours.

    Appelée par panel/runspace.py (tâche 12) juste avant de construire un
    chemin à partir d'un nom d'application. AppSpec.name est déjà validé par
    Pydantic à l'entrée de l'API ; cette fonction tient encore le jour où un
    chemin se construirait depuis une source qui n'est pas passée par
    AppSpec (une valeur relue en base, par exemple).
    """
    # re.fullmatch, pas re.match : `$` (comme `\Z` en apparence) matche en
    # réalité juste AVANT un '\n' final en Python — `re.match(pattern, "x\n")`
    # avec un motif ancré en `$` renvoie un match. re.fullmatch exige que le
    # motif consomme la chaîne ENTIÈRE, donc rejette bien ce cas. Vérifié
    # empiriquement avant d'écrire ce commentaire : c'est le même piège que
    # celui documenté pour la regex de service id de spec_init.
    if not re.fullmatch(APP_NAME_PATTERN, nom):
        raise ValueError(
            f"nom d'application invalide : {nom!r} — attendu : lettres "
            "minuscules, chiffres et tirets, doit commencer par une lettre, "
            "2 à 31 caractères (motif " + APP_NAME_PATTERN + ")"
        )
    return nom
