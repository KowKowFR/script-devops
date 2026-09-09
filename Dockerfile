# Image commune aux services panel et worker (jalon 2, tâche 20) : mêmes
# dépendances, deux commandes différentes (cf. compose.yml, tâche 21). Une
# seule image à construire, à scanner et à mettre à jour.
#
# Le worker exécute engine/bootstrap.sh, qui a ses propres prérequis : ils
# sont listés ci-dessous avec, en commentaire, la ligne exacte de
# engine/lib/prereqs.sh qui les exige. Si cette image en oublie un, le
# premier run échoue dès check_prereqs — pas à mi-pipeline.
FROM python:3.12-slim AS base

# Correspondance avec engine/lib/prereqs.sh (fonction check_prereqs) :
#   required=("git" "ssh" "scp" "curl" "jq" "docker")   -> toujours vérifiés
#   docker compose (plugin, pas un binaire du PATH)     -> toujours vérifié
#   sshpass                                             -> requis seulement
#     si target.auth_method=password (peut varier d'une cible à l'autre :
#     on l'embarque toujours plutôt que de faire dépendre l'image de la
#     configuration d'une cible particulière)
#   gh, ssh-keygen                                      -> requis seulement
#     si github.enabled=true ; gh est volontairement ABSENT ici, les étapes
#     github_* de l'engine sont neutralisées par requires_flag côté panel
#     tant que ce drapeau est faux (cf. pipeline.py, docs du jalon 2) ;
#     ssh-keygen fait partie du paquet openssh-client et est donc déjà
#     présent, sans coût supplémentaire.
#
# bash : engine/bootstrap.sh et toute sa lib (lib/*.sh) sont écrits pour
# bash, pas sh — l'image slim de base ne l'a pas par défaut.
# ca-certificates : requis pour que curl/git/ssh vérifient les certificats
# TLS (dépôt Docker plus bas, et toute cible HTTPS que l'engine contacte).
# gnupg : nécessaire à l'installation du dépôt apt Docker ci-dessous
#   (vérification de la clé de signature).
# openssh-client : fournit le VRAI binaire ssh, ainsi que scp et
#   ssh-keygen. C'est le binaire que Docker invoque lui-même, sans -i,
#   quand DOCKER_HOST=ssh:// — le wrapper posé par
#   engine/lib/ssh_remote.sh (_docker_ssh_wrapper_bin_dir), qui comble ce
#   trou en injectant l'identité, a besoin d'un ssh réel derrière lui.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash git jq curl ca-certificates openssh-client sshpass gnupg \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg \
      -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*
# docker-ce-cli   : le CLIENT docker (requis["docker"]). Aucun démon n'est
#   installé ici, et /var/run/docker.sock n'est monté nulle part — le
#   worker pilote une cible distante via DOCKER_HOST=ssh://, jamais le
#   socket local. Invariant du projet, pas une omission.
# docker-compose-plugin : le plugin "docker compose" que check_prereqs
#   vérifie par `docker compose version`.

# UID fixe et non-root : le volume runs/ est partagé entre panel et worker,
# les deux doivent lire et écrire les mêmes fichiers en 600. useradd -m crée
# /home/panel et lui en donne la propriété : c'est le HOME inscriptible dont
# a besoin le wrapper ssh ci-dessus (mktemp, et l'écriture de
# ~/.ssh/known_hosts par ssh lui-même en StrictHostKeyChecking=accept-new).
RUN groupadd -g 10001 panel && useradd -u 10001 -g 10001 -m -s /bin/bash panel

WORKDIR /app

# Couche de dépendances séparée du code : pyproject.toml déclare son propre
# backend ([build-system] -> setuptools), pip le récupère lui-même dans un
# environnement de build isolé (PEP 517) — rien à forcer ici. Cette couche
# ne change que si pyproject.toml change, donc ne se reconstruit pas à
# chaque modification de panel/. Le paquet "deploymatic-panel" installé ici
# est vide de code (panel/ n'existe pas encore dans le contexte de cette
# couche, seul pyproject.toml y est copié) : seules les dépendances comptent.
COPY pyproject.toml /app/
RUN pip install --no-cache-dir .

COPY --chown=panel:panel panel/ /app/panel/
COPY --chown=panel:panel engine/ /app/engine/

# runs/ est un volume monté ; le répertoire doit exister et appartenir à
# panel avant le premier run, avec des droits qui n'exposent rien au groupe
# ni au monde (les fichiers qu'il contiendra, env.json en tête, sont en 600).
RUN mkdir -p /app/runs && chown panel:panel /app/runs && chmod 700 /app/runs

# Utilisateur final non-root. no-new-privileges est appliqué côté compose
# (tâche 21) — l'image ne peut pas l'imposer elle-même, seul le runtime le
# peut, mais rien ici ne dépend de privilèges supplémentaires : aucun binaire
# setuid n'est installé, aucun setcap n'est posé.
USER 10001:10001
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
EXPOSE 8000

# Commande par défaut : le panneau (FastAPI/gunicorn). Le worker (rq worker)
# surcharge cette commande dans compose.yml — même image, deux commandes.
#
# panel/ est copié en source sous /app, jamais réinstallé comme paquet après
# le pip install de la couche précédente (qui ne voit encore que
# pyproject.toml). Ça fonctionne sans PYTHONPATH supplémentaire : gunicorn
# insère lui-même son --chdir (par défaut le cwd, ici /app via WORKDIR) en
# tête de sys.path (gunicorn/app/base.py, Application.chdir) — vérifié
# localement par `gunicorn --check-config` depuis un répertoire équivalent.
CMD ["gunicorn", "panel.api.app:app", \
     "--worker-class", "uvicorn.workers.UvicornWorker", \
     "--workers", "2", "--bind", "0.0.0.0:8000", \
     "--timeout", "120", "--graceful-timeout", "30", "--access-logfile", "-"]
