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

MESSAGES D'ERREUR EN FRANÇAIS — CHOIX D'IMPLÉMENTATION.
Les contraintes déclaratives de Pydantic (`StringConstraints(pattern=...)`,
`Field(ge=..., le=...)`, `Field(min_length=...)`, `model_config =
ConfigDict(extra="forbid")`) sont validées par le cœur Rust de pydantic-core
et produisent des messages automatiques FIGÉS EN ANGLAIS ("String should
match pattern…", "Extra inputs are not permitted…") qu'aucune configuration
ne permet de traduire. Deux options existaient pour respecter l'exigence de
messages en français : (a) une traduction centralisée, après coup, du champ
`type`/`ctx` de chaque erreur pydantic-core (fragile : suppose de reproduire
la table des types d'erreur internes de pydantic-core et de reconstruire un
ValidationError à coups d'API privée) ; (b) ne PLUS déléguer ces contraintes
au cœur Rust et les vérifier soi-même dans des `field_validator`/
`model_validator` Python, qui lèvent directement le message voulu. Cette
dernière est retenue : elle reste dans l'API publique de Pydantic, colocalise
chaque message avec la règle qu'il décrit (pas de table de traduction à tenir
synchronisée à part), et c'est exactement le même mécanisme que celui déjà
utilisé pour les règles de cohérence métier (build XOR image, expose
exclusif d'internal…) plus bas dans ce fichier.
"""
import re
from typing import Any, Self

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

# D5 : sous-ensemble STRICT de la regex de workspace de l'engine
# (^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$, cf. docs/ENGINE.md §1) — minuscules
# uniquement, pas de underscore, 2 à 31 caractères. Tout ce que cette regex
# accepte, l'engine l'accepte aussi ; l'inverse n'a pas besoin d'être vrai.
#
# Le type reste un simple alias `str` : la contrainte n'est PAS portée par le
# type (StringConstraints produirait le message anglais figé décrit plus
# haut) mais par un field_validator, dans AppSpec, qui délègue à
# valider_nom_application() — source unique du message.
APP_NAME_PATTERN = r"^[a-z][a-z0-9-]{1,30}$"
AppName = str

# Sous-ensemble strict de la validation d'id de service de spec_init
# (engine/lib/config.sh : ^[A-Za-z0-9_-]+$, sans limite de longueur). La
# limite à 32 caractères ici est une marge de sécurité du panneau, pas une
# exigence de l'engine — voir test_id_de_service_trop_long dans
# tests/test_spec.py, qui couvre spécifiquement cette limite par mutation.
SERVICE_ID_PATTERN = r"^[A-Za-z0-9_-]{1,32}$"
ServiceId = str


class ServiceSpec(BaseModel):
    """Un service de l'application — un bloc de la clé 'services' de spec.json."""

    # extra="allow" + rejet manuel dans _coherence (pas extra="forbid") :
    # même raison que pour AppName ci-dessus, voir le message du module.
    model_config = ConfigDict(extra="allow")

    id: ServiceId
    build: str | None = None          # service buildé → durcissement complet
    image: str | None = None          # image tierce → durcissement partiel
    port: int | None = None           # port CONTENEUR — bornes vérifiées ci-dessous
    health: str | None = None
    expose: str | None = None         # chemin PUBLIC ; un port hôte sera publié
    internal: bool = False            # aucun port publié
    env: dict[str, str] = Field(default_factory=dict)
    volumes: list[str] = Field(default_factory=list)

    @field_validator("id", mode="after")
    @classmethod
    def _valider_id(cls, v: str) -> str:
        if not re.fullmatch(SERVICE_ID_PATTERN, v):
            raise ValueError(
                f"id de service invalide ({v!r}) : attendu des lettres, des "
                "chiffres, '_' et '-' uniquement, entre 1 et 32 caractères "
                "(exemple : 'api', 'web-front')"
            )
        return v

    @field_validator("port", mode="after")
    @classmethod
    def _valider_port(cls, v: int | None) -> int | None:
        if v is not None and not (1 <= v <= 65535):
            raise ValueError(
                f"port invalide ({v}) : attendu un entier entre 1 et 65535 "
                "(c'est le port sur lequel le conteneur écoute)"
            )
        return v

    @model_validator(mode="after")
    def _coherence(self) -> Self:
        if self.model_extra:
            inconnus = ", ".join(sorted(self.model_extra))
            attendus = ", ".join(sorted(type(self).model_fields))
            raise ValueError(
                f"service « {self.id} » : champ(s) inconnu(s) — {inconnus}. "
                f"Champs acceptés : {attendus}"
            )
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

    model_config = ConfigDict(extra="allow")   # cf. message du module : rejet manuel ci-dessous

    name: AppName
    services: list[ServiceSpec]

    @field_validator("name", mode="after")
    @classmethod
    def _valider_nom(cls, v: str) -> str:
        # Source unique du message : voir valider_nom_application ci-dessous,
        # aussi utilisée par panel/runspace.py (tâche 12) comme garde de
        # dernier recours. Un seul endroit à faire évoluer si la règle change.
        return valider_nom_application(v)

    @model_validator(mode="after")
    def _coherence(self) -> Self:
        if self.model_extra:
            inconnus = ", ".join(sorted(self.model_extra))
            attendus = ", ".join(sorted(type(self).model_fields))
            raise ValueError(
                f"champ(s) inconnu(s) dans la description de l'application : "
                f"{inconnus}. Champs acceptés : {attendus}"
            )
        if not self.services:
            raise ValueError(
                "'services' doit contenir au moins un service : une "
                "application sans aucun service n'a rien à déployer"
            )
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
    """Garde de dernier recours — et source unique du message d'erreur.

    Appelée par AppSpec._valider_nom (au-dessus, chemin normal de l'API) ET
    par panel/runspace.py (tâche 12) juste avant de construire un chemin à
    partir d'un nom d'application déjà validé ailleurs (une valeur relue en
    base, par exemple, qui n'est pas repassée par AppSpec).
    """
    # re.fullmatch, pas re.match : `$` matche en réalité juste AVANT un '\n'
    # final en Python — `re.match(pattern, "x\n")` avec un motif ancré en `$`
    # renvoie un match. re.fullmatch exige que le motif consomme la chaîne
    # ENTIÈRE, donc rejette bien ce cas. Vérifié empiriquement, et couvert
    # par mutation dans tests/test_spec.py.
    if not isinstance(nom, str) or not re.fullmatch(APP_NAME_PATTERN, nom):
        raise ValueError(
            f"nom d'application invalide : {nom!r} — attendu des lettres "
            "minuscules, des chiffres et des tirets, commençant par une "
            "lettre, entre 2 et 31 caractères (exemple : 'mon-app')"
        )
    return nom
