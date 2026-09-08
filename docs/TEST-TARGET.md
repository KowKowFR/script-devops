# Cible SSH de test locale

`engine/tools/test-target.sh` fournit une VM Ubuntu 24.04 locale, avec systemd, pour
exercer réellement l'engine (`prepare_server.sh`, `enable_sudo_nopasswd`, `validate_ssh`,
etc.) sans dépendre d'un serveur OVH réel. Elle se crée et se détruit en une commande.

## Pourquoi une VM et pas un conteneur

`prepare_server.sh` appelle `systemctl enable --now`, installe `docker-ce` depuis le
dépôt officiel Docker, configure `ufw` et `fail2ban`. Un conteneur sans systemd ne peut
pas jouer ce rôle fidèlement (pas de `systemctl`, souvent pas de vrai `apt` isolé) — on
obtiendrait des faux positifs qui ne prouveraient rien sur un vrai serveur. Une VM Ubuntu
24.04 avec systemd est le bon niveau de fidélité, sans aller jusqu'à un vrai serveur OVH.

## Prérequis

- macOS (testé sur Apple Silicon, `vz` fonctionne aussi sur Intel avec macOS 13+).
- [Homebrew](https://brew.sh). `up` installe Lima tout seul via `brew install lima` si
  besoin — **aucun mot de passe administrateur requis** pour cette installation.
- `jq` (déjà requis par l'engine).
- Rien d'autre. Pas de vagrant, pas de virtualbox, pas de compte cloud.

## Les quatre commandes (en fait cinq)

```bash
engine/tools/test-target.sh up       # crée/redémarre la cible — idempotent
engine/tools/test-target.sh down     # détruit la VM
engine/tools/test-target.sh status   # état + coordonnées
engine/tools/test-target.sh env      # env.json sur stdout, prêt pour runs/<ws>/env.json
engine/tools/test-target.sh ssh      # session interactive sur la cible (debug)
```

### `up`

- Installe Lima si absent (≈5 s, bottle Homebrew).
- Crée la VM si elle n'existe pas : télécharge l'image cloud Ubuntu 24.04 officielle
  (catalogue tenu à jour par Lima lui-même, pas d'URL codée en dur ici), la démarre avec
  `vz` (le driver de virtualisation natif macOS, pas de kvm/qemu à configurer).
- Provisionne en root (`mode: system`, ré-exécuté à chaque démarrage, mais idempotent) :
  - crée l'utilisateur `devops` ;
  - installe la clé publique dédiée dans `~devops/.ssh/authorized_keys` ;
  - écrit `/etc/sudoers.d/90-devops-test-target` (`NOPASSWD:ALL`), validé par `visudo -c` ;
  - **retire Docker s'il est présent dans l'image de base** — `prepare_server.sh` doit
    avoir un vrai travail à faire, sinon le jalon 1 ne teste rien.
- Enregistre un alias dans `~/.ssh/config` (voir plus bas *pourquoi*).
- Relancer `up` sur une VM déjà démarrée est un no-op immédiat (idempotent).

**Temps mesuré** (Apple Silicon, fibre) :
- Premier `up` absolu (Lima pas installé, image jamais téléchargée) : Lima ≈ 4 s,
  téléchargement de l'image + création + provisioning ≈ 85 s. **Total ≈ 90 s.**
- `up` avec image déjà en cache, VM détruite puis recréée : **11 s.**
- `up` sur une VM déjà démarrée : < 1 s (idempotent, aucun appel réseau).

Le containerd/nerdctl embarqué par défaut par Lima pour son utilisateur interne est
désactivé (`containerd: {system: false, user: false}`) : sans ça, le boot reste bloqué
plusieurs minutes sur `containerd-rootless-setuptool.sh install`, observé en pratique —
et c'est un composant dont l'engine n'a aucun usage ici.

### `down`

Détruit la VM (`limactl delete --force`). Conserve la clé SSH et l'alias
`~/.ssh/config` : un `up` suivant recrée une VM fraîche avec la même identité.

### `status`

Affiche `Running` / `Stopped` / `absente` sur stdout, et le host/user/clé sur stderr.

### `env`

Imprime sur **stdout uniquement** un `env.json` valide (voir format ci-dessous). Exige
que la VM soit démarrée (sinon erreur explicite). C'est la commande à rediriger vers
`runs/<workspace>/env.json`.

### `ssh`

Ouvre une session interactive (`ssh -i <clé> devops@127.0.0.1 -p <port>`), pratique pour
inspecter la VM à la main pendant un débogage.

## Brancher la cible sur un workspace de l'engine

```bash
engine/tools/test-target.sh up
mkdir -p runs/testvm
engine/tools/test-target.sh env > runs/testvm/env.json
cp engine/templates/spec.demo.json runs/testvm/spec.json
bash engine/bootstrap.sh --workspace testvm --step validate_ssh
```

Le nom d'application dans `env.json` (`app.name`) est lu dynamiquement depuis
`engine/templates/spec.demo.json` — s'il change un jour, `env` suit sans modification.

## Pourquoi un alias SSH plutôt qu'une IP:port dans `target.host`

`lib/ssh_remote.sh` construit toujours `ssh -i "$OVH_SSH_KEY_PATH" ... "user@host"`, sans
jamais passer `-p` : le champ `target.host` d'`env.json` n'a pas de place pour un port
non standard. Or Lima expose la VM via un port localhost choisi automatiquement (ici fixé
à `60122` à la création) : se lier au port 22 directement sur l'hôte macOS échoue avec
`EACCES` sans droits root (vérifié — macOS interdit toujours le bind de ports < 1024 aux
processus non privilégiés, même sur `127.0.0.1`), et configurer le réseau *vmnet* de Lima
pour obtenir une vraie IP routable exige une entrée `sudoers` posée une fois de façon
interactive (`limactl sudoers`) — exactement ce que la consigne interdit ici (pas de TTY).

La solution : `up` déclare un bloc `Host deploymatic-test-target` dans un fichier propre
au projet (`.test-target/ssh_config`), et ajoute un `Include` **en tête** de
`~/.ssh/config` (dans un bloc marqué, réversible) pour qu'OpenSSH le charge en premier —
sinon un `Host *` déjà présent plus haut dans le fichier de l'utilisateur gagnerait
(OpenSSH retient la première valeur vue par mot-clé). `target.host` vaut alors
`deploymatic-test-target` : `ssh user@deploymatic-test-target` résout tout seul l'IP, le
port et la clé, exactement comme `ssh_remote()` s'y attend.

## Repartir de zéro

```bash
engine/tools/test-target.sh down          # détruit la VM
rm -rf .test-target                        # supprime clé + configs générées
# Retirer à la main le bloc marqué dans ~/.ssh/config :
#   # BEGIN deploymatic-test-target (…)
#   Include …
#   # END deploymatic-test-target
```

Un `up` après ce nettoyage régénère tout : nouvelle clé, nouvelle VM, nouvel alias.

## Pièges rencontrés (et pourquoi le script les évite déjà)

- **Bind du port 22 sur l'hôte : `EACCES`.** Testé directement en Python avant d'écrire
  le script — confirmé que macOS interdit le bind de ports < 1024 sans root, même en
  loopback. D'où l'alias SSH plutôt qu'un port forcé à 22.
- **`limactl sudoers` pour le réseau vmnet/bridge** donnerait une vraie IP routable, mais
  exige une saisie de mot de passe sudo interactive une première fois — interdit ici (pas
  de TTY). D'où le choix du réseau *usermode* par défaut de Lima (aucun setup admin).
- **Host key SSH périmée après recréation de la VM.** Si la VM est détruite puis
  recréée, sa clé d'hôte change, mais l'ancienne reste dans le `known_hosts` dédié du
  projet pour ce même `127.0.0.1:<port>` — `StrictHostKeyChecking=accept-new` refuse
  alors la connexion (conflit, pas une simple absence). Le script purge systématiquement
  l'entrée correspondante avant chaque connexion (`ssh-keygen -R`) : ce `known_hosts` ne
  sert qu'à cette VM jetable, la contrainte de sécurité normale ne s'applique pas ici.
- **`_probe`, `testvm`, etc. comme nom de workspace** : `bootstrap.sh` valide
  `^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$` — un nom commençant par `_` est rejeté (code 2).
- **Le containerd rootless par défaut de Lima bloque le boot plusieurs minutes.** Constaté
  en pratique : `limactl start` restait bloqué sur `Waiting for the final requirement 1 of
  1: boot scripts must have finished` pendant que `containerd-rootless-setuptool.sh
  install` tournait côté invité, sans rapport avec notre provisioning. `containerd:
  {system: false, user: false}` dans `lima.yaml` supprime cette étape : le boot passe de
  plusieurs minutes (parfois davantage) à ~11 s.

## Limite connue, hors périmètre de ce script

Au moment de la rédaction de ce document, `bash engine/bootstrap.sh --workspace testvm
--step validate_ssh` **échoue encore**, même avec un `env.json` correct produit par cette
cible — pour deux raisons situées dans `engine/lib/` (pas dans ce script, pas touché ici
car d'autres agents y travaillent en parallèle) :

1. `engine/bootstrap.sh` ne traduit jamais `target.host` / `target.user` /
   `target.ssh_key_path` / `target.auth_method` d'`env.json` vers les variables
   `OVH_HOST` / `OVH_USER` / `OVH_SSH_KEY_PATH` / `OVH_AUTH_METHOD` que `lib/steps.sh` et
   `lib/ssh_remote.sh` utilisent partout. Sans ce pont, `step_validate_ssh` échoue
   immédiatement avec `OVH_USER: unbound variable`.
2. Même ces variables exportées à la main pour vérifier la cible, `step_validate_ssh`
   (comme toutes les autres étapes de `lib/steps.sh`) ne se termine jamais par un appel à
   `emit_ok` (`lib/runtime.sh`) : le filet de sécurité `_exit_guard` transforme alors tout
   succès en `{"ok":false,"error":"l'engine est sorti sans émettre de résultat"}`, alors
   même que la connexion SSH a réellement réussi (`ui_ok "Connexion SSH réussie"` apparaît
   bien sur stderr juste avant).

La cible elle-même est validée de bout en bout (SSH, `sudo -n`, absence de Docker) — c'est
le pont `env.json` → variables `OVH_*` et l'appel `emit_ok` manquant côté étapes qui
restent à câbler ailleurs dans l'engine pour que cette preuve passe complètement.

## Format `env.json` produit

```json
{
  "app":    { "name": "tp-app", "author": "Test" },
  "target": { "host": "deploymatic-test-target", "user": "devops", "auth_method": "key",
              "ssh_key_path": "/chemin/vers/.test-target/id_ed25519", "password": "",
              "bind_addr": "0.0.0.0" },
  "registry": { "user": "", "token": "" },
  "github": { "enabled": false, "user": "", "repo": "", "token": "" },
  "ports":  { "api": 10001, "web": 10002 },
  "limits": { "cpu": "200m", "memory": "128Mi" },
  "options": { "reuse_existing_dir": true, "allow_existing_repo": true }
}
```

`app.name` est lu depuis `engine/templates/spec.demo.json` au moment de l'exécution de
`env`, pas codé en dur.
