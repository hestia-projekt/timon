<!-- french-ok-file: operator procedure for this fork's VPS, written in French for its maintainer -->

# Build du fork sur ce VPS

`/docs` est le clone des notes internes et n'est pas versionné ici. Cette page vit à côté des scripts pour partir avec le fork.

Cette procédure fait tourner un commit de `hestia-projekt/timon` sur le VPS, sans attendre la fusion amont. Elle ne bascule pas le service toute seule : `install.sh` et `rollback.sh` ne le font qu'avec `--apply`, et seulement quand aucune mission ne tourne.

Le service en place est l'unité utilisateur `timon-desktop-<id>`, qui exécute `~/.timon/desktop-runtime/releases/<id>/resources/node/node` sur `resources/orchestrator/dist/host/packaged-runner.js`. Le fichier `desktop-runtime/active-release` nomme le répertoire courant. La release en service au moment de l'écriture de cette page est `0.1.8-40ae30b1feef` (version amont `0.1.8`, le suffixe est le début du SHA-256 de la chaîne de version, pas un commit).

## Ce que le paquet contient

Le répertoire produit a la même forme que `releases/<version>/` : binaire Electron, `resources/node`, `resources/app`, `resources/orchestrator`, `cli/timon`.

Deux origines :

- **Démon**, compilé depuis le commit demandé : `dist`, `bin`, `presets`, `scripts`, plugins intégrés, documentation exportée, lanceur `timon-fence`. Il est signé avec une clé Ed25519 créée pour ce build (`~/timon-fork-prep/keys/<id>/`). La clé publique est écrite dans `dist/boot.js`, donc le paquet vérifie son propre inventaire. Ce n'est pas la clé de publication amont.
- **Coque**, copiée depuis la release officielle du même numéro de version : Electron, Node livré, application web, et `node_modules` du démon (modules natifs déjà compilés pour ce Node). Le script refuse de continuer si les dépendances npm du commit ne sont plus celles de cette coque.

`fork-build.json` à la racine du paquet dit quel commit et quelle coque ont servi. Le nom du répertoire est `<version-amont>-fork.<sha court de 12 caractères>`.

Le build n'écrit pas dans `~/.timon` et ne lance pas `npm`. Il se prépare dans `~/timon-fork-prep` (ou `TIMON_FORK_PREP`).

## Build

Depuis la racine du dépôt, sous le plafond mémoire du VPS :

```bash
systemd-run --user --wait --collect \
  -p MemoryMax=6G -p MemorySwapMax=0 -p KillMode=control-group -p RuntimeMaxSec=3600 \
  -- ops/fork-build/build.sh --commit <sha>
```

`--commit` accepte un SHA ou une réf. Sans argument, c'est `HEAD`. `--shell` nomme une autre release officielle à copier ; par défaut c'est le répertoire pointé par `active-release`.

À la fin, le script affiche le chemin du paquet et un SHA-256. Ce condensé est celui de la liste triée des SHA-256 de chaque fichier (`<préparation>/out/<id>.files.sha256`), pas un tar. Le fichier `<id>.sha256` à côté du paquet reprend ce condensé.

## Vérification hors service

```bash
ops/fork-build/verify.sh --package ~/timon-fork-prep/out/<id>
```

Le script démarre le paquet avec un `TIMON_HOME` temporaire sous le répertoire de préparation, un port libre, et `TIMON_APP_ENABLED=0`. Il lit `GET /api/health` et n'accepte que `{ "ok": true, "service": "timon" }` sans `status: "update_pending"` (un démon qui attend une approbation de migration n'est pas en service). Il importe `PLUGIN_PERMISSIONS` depuis le `dist` produit, exige `approvals:read` et `approvals:resolve`, puis arrête l'unité transitoire. Rien n'est ouvert sous le `~/.timon` réel.

## Installation

À lancer seulement quand aucune mission n'a le statut `running`, et seulement sur ordre. Sans `--apply`, le script interroge l'API et s'arrête.

```bash
ops/fork-build/install.sh --package ~/timon-fork-prep/out/<id>
ops/fork-build/install.sh --package ~/timon-fork-prep/out/<id> --apply
```

Avec `--apply`, dans l'ordre :

1. Il refuse si `GET /api/missions?status=running` n'est pas vide, ou s'il ne peut pas le lire. Le jeton du démon est lu dans le fichier, jamais affiché. Une page pleine (1000 lignes) est aussi un refus : la liste serait tronquée.
2. Il arrête l'unité. La copie qui suit ne bouge plus. Si une étape échoue avant la bascule, l'unité précédente est relancée. Après la bascule, un échec déclenche le retour arrière.
3. Il écrit une sauvegarde horodatée dans `~/timon-fork-backups/<date>/` (ou `TIMON_FORK_BACKUP_ROOT`), hors de `~/.timon` :
   - `timon.db` et `integrations.db` par `sqlite3 .backup`, puis `PRAGMA integrity_check` ;
   - le reste du dossier, sauf le runtime, les worktrees, les caches et les bases (une copie à chaud du fichier SQLite n'est pas utilisée) ; un second `rsync` à blanc doit être vide ;
   - une copie de la release officielle courante, vérifiée par le SHA-256 de `release-manifest.json` et le nombre de fichiers ;
   - l'unité systemd et le pointeur `active-release` tels qu'ils étaient.
4. Il copie le paquet dans `desktop-runtime/releases/<id>/`, réécrit les chemins de l'unité (les drop-ins, dont le port de l'application, ne sont pas touchés), pose le pointeur, recharge systemd et redémarre l'unité.
5. Il attend `/api/health` (`service` vaut `timon`, pas d'attente d'approbation). Si le redémarrage ou la santé échoue, il exécute le retour arrière décrit plus bas, puis retire la copie du paquet. Si ce retour arrière échoue à son tour, l'unité dont les fichiers viennent d'être remis est tout de même relancée.

La bascule ne passe pas par `timon update apply`.

## Retour arrière

```bash
ops/fork-build/rollback.sh --backup ~/timon-fork-backups/<date>
ops/fork-build/rollback.sh --backup ~/timon-fork-backups/<date> --apply
```

Avec `--apply` : si le démon répond, le script refuse tant qu'une mission tourne. La restauration suit cet ordre :

1. Arrêt de l'unité.
2. Remise du fichier d'unité et du pointeur `active-release` sauvegardés.
3. Lecture de `activeRelease` dans `manifest.json`. Si `desktop-runtime/releases/<activeRelease>/resources/orchestrator/dist/host/packaged-runner.js` est absent, copie de `official-release` vers ce répertoire (un répertoire incomplet est retiré avant, pour que la copie porte le nom de la release), puis vérification du SHA-256 de `release-manifest.json`.
4. Rechargement de systemd (`daemon-reload`).
5. Restauration de `timon.db` ou `integrations.db` seulement si l'empreinte du schéma diffère de celle de la sauvegarde.
6. Redémarrage de l'unité et attente de `/api/health`.

En cas d'échec, `fork_restore_backup` rend la main au lieu de quitter le shell. `install.sh` relance alors l'unité. `rollback.sh` s'arrête sur la même erreur.

Remettre la base remplace aussi les écritures faites après la bascule. Si le schéma n'a pas bougé, la base en service est laissée telle quelle.

## Recaler le fork sur une release amont

Les commits propres au fork sont ceux que `upstream/main` n'a pas :

```bash
git fetch upstream
git log --oneline upstream/main..origin/main
```

Pour chaque release amont :

1. `git fetch upstream` et partir de `upstream/main` (ou de l'étiquette de la release).
2. Rejouer les commits propres au fork (`git rebase --onto upstream/main <ancienne-base> <branche-du-fork>`). Les fichiers de `ops/fork-build/` ne touchent pas le code amont : ils se rejouent tels quels. Un conflit dans le démon se résout avant le build, jamais en forçant.
3. Relancer le build sur le nouveau SHA, avec `--shell` pointant la release officielle qui correspond au numéro de version, une fois qu'elle est installée dans `desktop-runtime/releases/`. Si `orchestrator/package.json` a de nouvelles dépendances, le build s'arrête : les modules natifs de l'ancienne coque ne conviennent plus.
4. `verify.sh`, puis `install.sh --apply` quand aucune mission ne tourne. L'install prend une nouvelle sauvegarde.

## Mises à jour signées une fois le fork en service

Le démon du fork garde le trousseau amont (`RELEASE_PUBLIC_KEYS`). Il fera donc confiance à un manifeste d'update signé par l'amont.

Le service ne suit pas `/opt/Timon` tout seul : il exécute la copie sous `desktop-runtime/releases/`. Installer un `.deb` amont remplace le programme dans `/opt/Timon` et laisse le fork en service. En revanche, `timon update apply` lancé avec le `timon` du paquet officiel réécrit l'unité vers cette release officielle. Le numéro dans `package.json` reste `0.1.8` des deux côtés, et le pointeur `active-release` du fork n'est pas l'identifiant que l'outil officiel calcule pour `0.1.8`, donc l'outil considère que le service n'est pas déjà sur ce paquet et le déplace. Ça ne restaure pas la base.

Tant que le fork doit rester en service : ne pas lancer `timon update apply`, et ne pas ouvrir l'application de bureau officielle pour qu'elle fasse la même bascule au démarrage. Le retour arrière de cette page est le chemin qui remet la release sauvegardée et, si besoin, la base.
