<!-- french-ok-file: operator procedure for this fork's VPS, written in French for its maintainer -->

# Build du fork sur ce VPS

## Portée

Linux et systemd en session utilisateur, uniquement. Ce répertoire est un outillage du fork pour le VPS : il ne fait pas partie du produit, ne vise pas Windows ni macOS, et n'est pas proposé en amont.

La règle des trois systèmes dans `AGENTS.md` vise le produit : `node:path` pour les chemins, pas de commande Unix hors de `orchestrator/src/host/`, pas d'hypothèse sur le superviseur. Une exception explicite est prévue : `node scripts/check-portability.mjs` accepte `// portability: <raison>` sur la ligne concernée, ou sur la ligne juste au-dessus. Ce contrôle ne parcourt pas `ops/fork-build/` (seulement le code produit). Chaque appel à systemd, chaque lecture de `/proc` et chaque commande Unix de ces scripts porte quand même `# portability: VPS-only fork tooling (Linux, systemd user unit)`, la forme shell de cette exception.

`/docs` est le clone des notes internes et n'est pas versionné ici. Cette page vit à côté des scripts pour partir avec le fork.

Cette procédure fait tourner un commit de `hestia-projekt/timon` sur le VPS, sans attendre la fusion amont. Elle ne bascule pas le service toute seule : `install.sh` et `rollback.sh` ne le font qu'avec `--apply`, et seulement quand aucune mission ne tourne.

Le service en place est l'unité utilisateur `timon-desktop-<id>`, qui exécute `~/.timon/desktop-runtime/releases/<id>/resources/node/node` sur `resources/orchestrator/dist/host/packaged-runner.js`. Le fichier `desktop-runtime/active-release` nomme le répertoire courant. La release en service au moment de l'écriture de cette page est `0.1.8-40ae30b1feef` (version amont `0.1.8`, le suffixe est le début du SHA-256 de la chaîne de version, pas un commit).

## Ce que le paquet contient

Le répertoire produit a la même forme que `releases/<version>/` : binaire Electron, `resources/node`, `resources/app`, `resources/orchestrator`, `cli/timon`.

Deux origines :

- **Démon**, compilé depuis le commit demandé : `dist`, `bin`, `presets`, `scripts`, plugins intégrés, documentation exportée, lanceur `timon-fence`. Il est signé avec une clé Ed25519 créée pour ce build (`~/timon-fork-prep/keys/<id>/`). La clé publique est écrite dans `dist/boot.js`, donc le paquet vérifie son propre inventaire. Ce n'est pas la clé de publication amont.
- **Coque**, copiée depuis la release officielle du même numéro de version : Electron, Node livré, application web, et `node_modules` du démon (modules natifs déjà compilés pour ce Node). Le script refuse une coque dont la version (`package.json` scellé par `release-manifest.json`, et le nom du répertoire, qui est l'identifiant officiel de cette version) n'est pas celle du commit. Il refuse aussi quand l'arbre résolu des dépendances diffère : l'empreinte de `node_modules` (version, et intégrité quand `node_modules/.package-lock.json` la donne) est comparée à `orchestrator/package-lock.json` du commit, pas seulement à la map `dependencies`.

`fork-build.json` à la racine du paquet dit quel commit et quelle coque ont servi. Le nom du répertoire est `<version-amont>-fork.<sha court de 12 caractères>`.

Le build n'écrit pas dans `~/.timon` et ne lance pas `npm`. Il se prépare dans `~/timon-fork-prep` (ou `TIMON_FORK_PREP`, ou `--prep`). Ce chemin est canonique (les liens sont suivis) avant toute création. `~/.timon` lui-même, ou un chemin qui s'y trouve, est refusé. Un répertoire de préparation déjà présent n'est pas modifié.

## Build

Depuis la racine du dépôt, sous le plafond mémoire du VPS :

```bash
systemd-run --user --wait --collect \
  -p MemoryMax=6G -p MemorySwapMax=0 -p KillMode=control-group -p RuntimeMaxSec=3600 \
  -- ops/fork-build/build.sh --commit <sha>
```

`--commit` accepte un SHA ou une réf. Sans argument, c'est `HEAD`. `--shell` nomme une autre release officielle du même numéro de version ; par défaut c'est le répertoire pointé par `active-release`.

À la fin, le script affiche le chemin du paquet et un SHA-256. Ce condensé est celui de la liste triée des SHA-256 de chaque fichier (`<préparation>/out/<id>.files.sha256`), pas un tar. Le fichier `<id>.sha256` à côté du paquet reprend ce condensé.

## Vérification hors service

```bash
ops/fork-build/verify.sh --package ~/timon-fork-prep/out/<id>
```

Le script démarre le paquet avec un `TIMON_HOME` temporaire sous le répertoire de préparation, un port libre, et `TIMON_APP_ENABLED=0`. Il lit `GET /api/health` et n'accepte que `{ "ok": true, "service": "timon" }` dont `instance` est celle de ce home (les 24 premiers caractères hexadécimaux du SHA-256 du chemin, comme `instanceId` du démon), sans `status: "update_pending"` (un démon qui attend une approbation de migration n'est pas en service). Une autre instance Timon sur le même port est un échec. Si la réponse n'a pas d'`instance`, le processus qui écoute doit appartenir à l'unité lancée. Il importe `PLUGIN_PERMISSIONS` depuis le `dist` produit, exige `approvals:read` et `approvals:resolve`, puis arrête l'unité transitoire. Rien n'est ouvert sous le `~/.timon` réel.

## Installation

À lancer seulement quand aucune mission n'a le statut `running`, et seulement sur ordre. Sans `--apply`, le script interroge l'API et s'arrête.

```bash
ops/fork-build/install.sh --package ~/timon-fork-prep/out/<id>
ops/fork-build/install.sh --package ~/timon-fork-prep/out/<id> --apply
```

Avec `--apply`, dans l'ordre :

1. Il refuse si `GET /api/missions?status=running` n'est pas vide, ou s'il ne peut pas le lire. Le jeton du démon est lu dans le fichier, jamais affiché. Une page pleine (1000 lignes) est aussi un refus : la liste serait tronquée. Sans `--apply`, le script s'arrête ici.
2. Il prépare le dossier racine de sauvegarde, hors de `~/.timon`. Le chemin (`--backup-root` ou `TIMON_FORK_BACKUP_ROOT`) est canonique. `~/.timon` lui-même est refusé. S'il n'existe pas, le script le crée en `0700` ; les parents déjà présents ne sont pas modifiés. S'il existe, le script ne change pas ses droits : il l'accepte seulement s'il appartient à l'utilisateur courant et est déjà en `0700`, sinon il s'arrête.
3. Il relit la liste des missions, et c'est la dernière action avant l'arrêt. Une mission apparue depuis le premier contrôle, ou une liste illisible, est un refus : l'unité en marche n'est pas arrêtée.
4. Il arrête l'unité. La copie qui suit ne bouge plus. Si une étape échoue avant la bascule, l'unité précédente est relancée. Après la bascule, un échec déclenche le retour arrière.
5. Il écrit une sauvegarde horodatée dans `~/timon-fork-backups/<date>/` (ou sous `TIMON_FORK_BACKUP_ROOT`). Ce sous-dossier est créé en `0700` par le script. La racine, si elle existait déjà, garde ses droits. Les fichiers sont en `0600` ; un exécutable copié reste exécutable par le propriétaire seul (`0700`), pour que le retour arrière puisse lancer le binaire. Le script vérifie ces droits après la copie :
   - `timon.db` et `integrations.db` par `sqlite3 .backup`, puis `PRAGMA integrity_check` ;
   - le reste du dossier, sauf le runtime, les worktrees, les caches et les bases (une copie à chaud du fichier SQLite n'est pas utilisée) ; un second `rsync` à blanc doit être vide ;
   - une copie de la release officielle courante, vérifiée par le SHA-256 de `release-manifest.json` et le nombre de fichiers ;
   - l'unité systemd et le pointeur `active-release` tels qu'ils étaient.
6. Il copie le paquet dans `desktop-runtime/releases/<id>/`, réécrit les chemins de l'unité (les drop-ins, dont le port de l'application, ne sont pas touchés), pose le pointeur, recharge systemd et redémarre l'unité.
7. Il attend `/api/health` (`instance` est celle du home visé, `service` vaut `timon`, pas d'attente d'approbation). Une autre instance sur le port est un échec. Si le redémarrage ou la santé échoue, il exécute le retour arrière décrit plus bas, puis retire la copie du paquet. Si ce retour arrière échoue à son tour, l'unité dont les fichiers viennent d'être remis est tout de même relancée.

## Bascule

La bascule ne passe pas par `timon update apply`.

Ni ce fork, ni la release en service `0.1.8-40ae30b1feef`, n'ont de moyen de suspendre tous les nouveaux lancements. Le relevé (code du dépôt, et `dist` plus `bin/timon` de cette release, en lecture seule) :

- aucune sous-commande `timon`, aucune route HTTP, pour mettre en pause le dispatcher Kanban, les déclencheurs ou les routines ;
- `TIMON_MAX_LIVE_MISSIONS` ne borne que le dispatcher et le réveil, et le profil de jour a un plancher de 1 (`profileLimits` dans `orchestrator/src/resources.ts`, `Math.max(1, …)`). Le chat ne consulte pas ce plafond (`TIMON_MAX_LIVE_MISSIONS` dans `orchestrator/src/settings.ts`) ;
- `TIMON_HARD_MAX_LIVE_MISSIONS` à 0 veut dire « automatique » (deux fois le plafond souple), ce qui laisse passer un premier lancement (`spawnAgent` dans `orchestrator/src/agent.ts`) ;
- déclencheurs et routines s'arment un par un. Les éteindre tous réécrirait la configuration de l'opérateur, et un chat, un workflow ou un lancement déjà admis démarrerait quand même.

`install.sh --apply` et `rollback.sh --apply` relisent donc la liste juste avant `systemctl --user stop`. Si une mission tourne, ou si la liste est illisible alors que le port répond, le script s'arrête et l'unité continue. `rollback.sh` continue l'arrêt seulement quand le port ne répond plus.

Il reste une fenêtre : entre la réponse de ce second contrôle et la désactivation par systemd, un client, un déclencheur, une routine ou le dispatcher peut lancer une mission, que l'arrêt tue. Rien hors du démon ne ferme cette fenêtre.

Avant `--apply`, sur cette machine :

- couper les déclencheurs et les routines ;
- aucune mission planifiée dans la fenêtre, aucune tâche Kanban sur le point d'être prise, aucun message envoyé au démon ;
- rester devant la machine jusqu'à la fin de la bascule.

## Retour arrière

```bash
ops/fork-build/rollback.sh --backup ~/timon-fork-backups/<date>
ops/fork-build/rollback.sh --backup ~/timon-fork-backups/<date> --apply
```

`--backup` est canonique. Le dossier est refusé s'il est `~/.timon`, s'il s'y trouve, s'il n'appartient pas à l'utilisateur courant, ou s'il n'est pas déjà en `0700`. Le script ne change pas ses droits.

Avec `--apply` : si le démon répond, le script refuse tant qu'une mission tourne. Il relit la liste une seconde fois, juste avant l'arrêt (voir [Bascule](#bascule)). La restauration suit cet ordre :

1. Arrêt de l'unité, après ce second contrôle quand le port répond encore.
2. Remise du fichier d'unité et du pointeur `active-release` sauvegardés.
3. Lecture de `activeRelease` dans `manifest.json`. Si `desktop-runtime/releases/<activeRelease>/resources/orchestrator/dist/host/packaged-runner.js` est absent, un répertoire incomplet à ce chemin est déplacé à côté (`<id>.incomplete`), pas supprimé : le script ne fait de suppression récursive que sur un répertoire qu'il vient de créer. La copie de `official-release` prend ensuite ce nom, puis le SHA-256 de `release-manifest.json` est vérifié. Un lien symbolique à la place de la release est un refus.
4. Rechargement de systemd (`daemon-reload`).
5. Restauration de `timon.db`, puis de `integrations.db`. Pour une base qui existait à la sauvegarde, la copie sauvegardée est toujours remise. L'empreinte du schéma ne décide plus de garder le fichier vivant : une migration de données sans changement de DDL laisse `sqlite_master` identique, et l'ancien démon recevrait des lignes qu'il ne sait pas traiter.
   - La base vivante n'est pas supprimée. Elle est déplacée dans `<sauvegarde>/post-fork/<nom>`, avec ses `-wal` et `-shm`, en `0600`. Les écritures faites pendant que le fork tournait sont conservées dans ce dossier, pour une récupération manuelle. Elles ne sont pas réinjectées.
   - Empreinte `absent` : le fichier n'existait pas avant la bascule, donc aucune copie n'est remise. Un fichier apparu depuis, ainsi que ses `-wal` et `-shm`, est mis de côté de la même façon, y compris quand il ne reste que le journal. Il n'est pas supprimé.
   - La copie remise est contrôlée avant de prendre le nom du fichier vivant : mode `0600`, `PRAGMA integrity_check` répond `ok`, empreinte égale à celle de la sauvegarde. Un contrôle en échec laisse le fichier vivant à sa place. Le journal n'est écarté qu'après ces contrôles, pour que SQLite ne le rejoue pas sur la copie.
6. Redémarrage de l'unité et attente de `/api/health`.

Si la restauration échoue après que `rollback.sh` a arrêté l'unité, le script ne laisse pas le service arrêté. Un `trap` sur `EXIT` relance l'unité, contrôle `/api/health`, et quitte avec le code d'origine. Le message dit ce qui a été remis (fichier d'unité, pointeur, release, bases) et ce qui ne l'a pas été. `fork_restore_backup` rend la main au lieu de quitter le shell : `install.sh`, qui l'appelle dans un sous-shell, relance alors l'unité de son côté. La seconde base n'est pas touchée si la première restauration a échoué.

`ops/fork-build/restore-db.test.sh` rejoue ces cas dans un répertoire temporaire (`TIMON_HOME` et `TIMON_FORK_DATA_HOME`). Il n'écrit pas dans `~/.timon`. Le `systemctl` qu'il met sur le `PATH` est un faux : il n'arrête pas l'unité de la machine.

## Recaler le fork sur une release amont

Les commits propres au fork sont ceux que `upstream/main` n'a pas :

```bash
git fetch upstream
git log --oneline upstream/main..origin/main
```

Pour chaque release amont :

1. `git fetch upstream` et partir de `upstream/main` (ou de l'étiquette de la release).
2. Rejouer les commits propres au fork (`git rebase --onto upstream/main <ancienne-base> <branche-du-fork>`). Les fichiers de `ops/fork-build/` ne touchent pas le code amont : ils se rejouent tels quels. Un conflit dans le démon se résout avant le build, jamais en forçant.
3. Relancer le build sur le nouveau SHA, avec `--shell` pointant la release officielle qui correspond au numéro de version, une fois qu'elle est installée dans `desktop-runtime/releases/`. Si la version, la map `dependencies` ou l'arbre résolu du lock diffère de cette coque, le build s'arrête : les modules natifs de l'ancienne coque ne conviennent plus.
4. `verify.sh`, puis `install.sh --apply` quand aucune mission ne tourne. L'install prend une nouvelle sauvegarde.

## Mises à jour signées une fois le fork en service

Le démon du fork garde le trousseau amont (`RELEASE_PUBLIC_KEYS`). Il fera donc confiance à un manifeste d'update signé par l'amont.

Le service ne suit pas `/opt/Timon` tout seul : il exécute la copie sous `desktop-runtime/releases/`. Installer un `.deb` amont remplace le programme dans `/opt/Timon` et laisse le fork en service. En revanche, `timon update apply` lancé avec le `timon` du paquet officiel réécrit l'unité vers cette release officielle. Le numéro dans `package.json` reste `0.1.8` des deux côtés, et le pointeur `active-release` du fork n'est pas l'identifiant que l'outil officiel calcule pour `0.1.8`, donc l'outil considère que le service n'est pas déjà sur ce paquet et le déplace. Ça ne restaure pas la base.

Tant que le fork doit rester en service : ne pas lancer `timon update apply`, et ne pas ouvrir l'application de bureau officielle pour qu'elle fasse la même bascule au démarrage. Le retour arrière de cette page est le chemin qui remet la release sauvegardée et, si besoin, la base.
