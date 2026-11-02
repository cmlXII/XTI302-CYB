# Dossier : serveur Pixelia (contexte A)

Projet XTI302-CYB, EFREI Paris, B2 CS2. Groupe : Ilian Boubadra, Ilhan, Camille.

Serveur Debian 13 minimal de l'agence web Pixelia, configuré par `installer.sh` à partir de ce dépôt et contrôlé par `verifier.sh` (78 tests). Les références ANSSI renvoient au guide *Recommandations de configuration d'un système GNU/Linux* (ANSSI-BP-028, v2.0) et au guide *Usage sécurisé d'(Open)SSH*.

## 1. Tableau de conformité

| ID | Ce que nous avons fait | Test dans verifier.sh | ANSSI |
|---|---|---|---|
| C1 | `creer_comptes.sh` lit `comptes.csv` et crée groupes et comptes. Il ne crée un compte que s'il n'existe pas, sinon il remet le groupe principal et le nom du CSV : relancé, il ne crée aucun doublon. Les clés publiques de `config/cles/` sont copiées dans `authorized_keys`. Les freelances expirent le 31/01/2027 (`chage -E`). | `test_C1` : chaque compte du CSV existe avec ses groupes, aucun doublon dans passwd/group, clés installées identiques au dépôt, date d'expiration des freelances | R30, R33 |
| C2 | `/srv/projets`, `/srv/projets/externe`, `/srv/maquettes`, `/srv/clients` en root:root 770, groupe propriétaire et autres sans droit, accès donné uniquement par des ACL nommées, avec la même ACL en ACL par défaut. Les freelances ont seulement `--x` sur `/srv/projets` pour traverser jusqu'à `externe`. | `test_C2` : 13 essais réels avec `sudo -u` (ce qui doit marcher et ce qui doit être refusé), plus un fichier créé par un dev pour vérifier l'héritage | R50 |
| C3 | `config/sudoers.d/admins` (`%admins ALL=(ALL:ALL) ALL`) et `config/sudoers.d/support` (une seule commande, `/usr/local/sbin/analyse_logs.sh`), copiés en 0440 et validés par `visudo -c`. Le groupe `sudo` est vidé. | `test_C3` : `sudo -l -U` pour chaque compte, essai réel de support (le script passe, `sudo id` est refusé), groupe sudo vide, droits des fichiers, script modifiable par root seul | R38, R39, R43 |
| C4 | `passwd -l root`, répertoires personnels en 700, `DIR_MODE` et `HOME_MODE` à 0700 pour les futurs comptes. Chaque administrateur a un mot de passe (sudo et console de secours). | `test_C4` : état de root avec `passwd -S`, droits de chaque `/home/*`, admins avec mot de passe | R33, R50 |
| S1 | `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey` | `test_S1` : valeurs de `sshd -T` et vraie tentative de connexion sans clé | OpenSSH : authentification par clé |
| S2 | `PermitRootLogin no` | `test_S2` | OpenSSH : interdire root, R33 |
| S3 | `AllowGroups acces_ssh` | `test_S3` : valeur appliquée et membres de acces_ssh conformes au CSV | OpenSSH : restreindre les utilisateurs |
| S4 | `MaxAuthTries 3`, `LoginGraceTime 30`, `ClientAliveInterval 300` et `ClientAliveCountMax 2`, `TMOUT=600` en lecture seule | `test_S4` | R32, R63 (fonctions inutiles coupées) |
| S5 | Fichier `/etc/ssh/sshd_config.d/10-hardening.conf`, validé par `sshd -t` avant `systemctl reload ssh`. En cas d'erreur, l'ancien fichier est remis. | `test_S5` : fichier identique au dépôt, `Include` présent, `sshd -t` valide | |
| J1 | Jail `sshd` : backend systemd, 5 échecs en 10 min, bannissement 30 min via nftables | `test_J1` : service actif, valeurs lues avec `fail2ban-client get`, action nftables | R79 |
| J2 | `/etc/nftables.conf` : politique `drop` en entrée, acceptés seulement les connexions établies, la loopback et le port 22. Service nftables activé au démarrage. | `test_J2` : politique, règles, aucun autre port, fichier identique au dépôt, service activé | R79, R80 |
| J3 | `Storage=persistent` dans `/etc/systemd/journald.conf.d/10-persistent.conf` | `test_J3` : valeur appliquée et fichiers présents dans `/var/log/journal` | R71 |
| J4 | `analyse_logs.sh` lit le journal (`sshd`, `sshd-session`) et sort les échecs par IP, les comptes visés et les connexions réussies. Code 2 si une IP atteint le seuil (10 par défaut, option `-s`). | `test_J4` : sur `tests/ssh_exemple_debian13.log`, code 2 au seuil 10 et 0 au seuil 50, contenu du rapport, seuil invalide refusé | R72 |
| B1 | Second disque en ext4 monté par UUID sur `/sauvegardes`. `sauvegarde.sh` crée une version datée par exécution avec `rsync -aAXH --link-dest`, garde les 7 dernières et supprime les plus anciennes. | `test_B1` : montage et fstab, script appartenant à root, nombre de versions, lien dur entre deux versions (incrémental), ACL et propriétaires conservés | pas de recommandation directe (règle 3-2-1 du cours) |
| B2 | `sauvegarde.timer` tous les jours à 2 h 30 avec `Persistent=true`. Chaque exécution écrit dans `/var/log/sauvegarde.log` et dans le journal. | `test_B2` : timer actif, exécutions réussies dans le log | R71 |
| B3 | `/sauvegardes` en root:admins 750 | `test_B3` : droits, un admin y accède, un dev et support non | R50 |
| B4 | Restauration testée et documentée (partie 4) | `test_B4` : restauration réelle de `/srv` et `/etc/hostname` dans un dossier temporaire, comparaison et ACL | |
| D1 | `unattended-upgrades` avec `config/apt/20auto-upgrades` (mise à jour de la liste et installation chaque jour, origine Debian-Security) | `test_D1` | R61 |
| D2 | Installation minimale, aucun service ajouté hormis SSH. `ss -tulpn` ne montre que sshd sur le réseau. | `test_D2` : toute écoute hors loopback autre que sshd est signalée | R62, R80 |
| D3 | Recherche des fichiers modifiables par tous et des SUID. Bit SUID retiré de `fusermount3` (`dpkg-statoverride`), les 11 SUID restants sont listés dans `config/suid_attendus.txt` et expliqués plus bas. | `test_D3` : `find -xdev` sur les vrais systèmes de fichiers, liens symboliques exclus, comparaison avec la liste | R54, R56, R57 |

## 2. Choix techniques

**Où est le dépôt.** Il est cloné dans `/opt/xti302-cyb` et `installer.sh` le passe en root:root sans droit d'écriture pour les autres. Ces scripts tournent en root : si un utilisateur pouvait en modifier un, il ajouterait une commande et deviendrait root au lancement suivant. C'est la même raison pour `/usr/local/sbin/analyse_logs.sh` en 0755 root : support le lance en root via sudo, il ne doit surtout pas pouvoir le réécrire.

**Comptes.** Un compte admin nominatif par membre du groupe, pour savoir qui a fait quoi dans les journaux de sudo. Root est verrouillé, mais seulement si au moins un admin a un mot de passe : sinon plus personne ne pourrait passer root, même depuis la console de l'hyperviseur. Le compte `installeur` créé à l'installation de Debian reste présent mais n'a ni sudo ni accès SSH (il n'est pas dans acces_ssh). Il pourrait être supprimé une fois le serveur en production.

**SSH.** 3 essais par connexion (le maximum autorisé est 4) : un admin qui a plusieurs clés dans son agent passe quand même, un robot doit rouvrir une connexion tous les 3 essais, ce qui le ralentit et nourrit fail2ban. `LoginGraceTime 30` coupe les connexions qui restent sans s'authentifier. Pour l'inactivité, nous avons mis deux mécanismes, parce que `ClientAlive` seul ne ferme pas une session inactive : il coupe une connexion dont le client ne répond plus (réseau coupé, PC éteint), ici après 2 sondes de 300 s, soit 10 min. La session vraiment inactive est fermée par `TMOUT=600`, déclaré `readonly` dans `/etc/profile.d/` pour qu'un utilisateur ne puisse pas l'annuler. Nous avons aussi coupé le transfert X11, d'agent et de ports, inutiles ici, et passé `LogLevel VERBOSE` pour avoir l'empreinte de la clé utilisée dans les journaux.

**fail2ban.** `backend = systemd` parce que Debian 13 minimale n'a pas de `/var/log/auth.log`. `mode = aggressive` pour compter aussi les refus `AllowGroups` et les tentatives sur un serveur qui n'accepte que les clés (sans ce mode, une tentative sans clé ne laisse pas toujours de ligne « Failed »). 5 échecs en 10 minutes laissent de la marge à un admin qui se trompe, 30 minutes de bannissement découragent un robot sans nous bloquer trop longtemps : depuis la VM, toutes nos connexions arrivent de 192.168.108.1 (la carte VMware de l'hôte), donc c'est nous qui sommes bannis pendant les tests. On débannit depuis la console avec `fail2ban-client set sshd unbanip 192.168.108.1`.

**nftables.** Pas de `flush ruleset` dans `/etc/nftables.conf` : il effacerait aussi la table `f2b-table` de fail2ban à chaque rechargement. Le fichier déclare puis supprime seulement notre table `inet filtre` avant de la recréer, donc `nft -f` ou `systemctl reload nftables` laissent les bannissements en place. En revanche, `systemctl restart nftables` lance `nft flush ruleset` (ExecStop du service) : nous avons ajouté `PartOf=nftables.service` à fail2ban pour qu'il redémarre avec le pare-feu, recrée sa table et reprenne ses bannissements dans sa base. La loopback est acceptée parce que des programmes locaux s'en servent. Le ping n'est pas autorisé : le cahier des charges demande de tout refuser sauf SSH, et les messages ICMP utiles (erreurs liées à une connexion) passent avec `related`. Le serveur est joint en IPv4, l'IPv6 n'est pas utilisé.

**Journal.** 200 Mo au maximum sur disque, ce qui représente plusieurs mois pour un petit serveur et ne remplit pas le disque système.

**analyse_logs.sh.** Un échec, c'est une ligne `Failed ... for <compte>`, une ligne `Invalid user` (une seule fois par connexion vers un compte inexistant) ou un refus `AllowGroups`. Le seuil par défaut est de 10 échecs par IP sur 24 heures : avec 3 essais par connexion et un bannissement à 5 échecs, un humain qui se trompe n'y arrive pas, alors qu'un robot y arrive avant ou après son bannissement. Le script tourne en root pour support, donc il fixe son `PATH`, désactive tout pager (depuis `less` on peut ouvrir un shell, voir GTFOBins) et refuse l'option `-f` quand il est lancé via sudo par quelqu'un qui n'est pas admin : support ne choisit pas le fichier que root va lire.

**Sauvegarde.** `rsync --link-dest` : chaque version paraît complète, mais un fichier inchangé est un lien dur vers la version précédente, donc ni recopié ni stocké deux fois. La version est écrite dans un dossier `.en_cours` renommé seulement si rsync réussit : une sauvegarde ratée ne sert jamais de base à la suivante. Un verrou (`flock`) empêche deux sauvegardes en même temps. Le script refuse de tourner si `/sauvegardes` n'est pas monté, pour ne pas remplir le disque système à la place. 7 versions quotidiennes permettent de revenir une semaine en arrière, ce qui suffit pour une suppression ou un chiffrement remarqué quelques jours après. Nous avons choisi un timer systemd plutôt que cron pour `Persistent=true` : si la machine était éteinte à 2 h 30, la sauvegarde part au démarrage suivant. Le disque est monté par UUID (son nom sda/sdb a changé d'un démarrage à l'autre sur notre VM) avec `nodev,nosuid,noexec` et `nofail` pour que le serveur démarre même sans lui. `installer.sh` ne formate que s'il trouve un unique disque vide de 0,5 à 4 Go, et rien s'il trouve déjà le label `SAUVEGARDES` : on peut le relancer sans perdre les sauvegardes.

**verifier.sh.** Pas de `set -e` : le script lance volontairement des commandes qui échouent, chaque échec doit donner `[KO]` et non arrêter le script. Pas de `pipefail` : dans `commande | grep -q motif`, grep s'arrête à la première ligne trouvée, la commande reçoit SIGPIPE et le pipeline serait vu comme raté alors que le motif est là. `set -u` est gardé car une variable mal écrite est une vraie erreur. Les tests regardent l'état réel (`sshd -T`, `sudo -l -U`, essais avec `sudo -u`) plutôt que de relire nos fichiers, et les fichiers de test sont supprimés par un `trap` à la fin.

**D2.** Sur notre VM, `ss -tulpn` ne montre que sshd sur 0.0.0.0:22 et [::]:22. Le test tolère le client DHCP (ports UDP 68 et 546) s'il apparaît, car c'est lui qui obtient l'adresse IP du serveur.

**D3, fichiers SUID.** Un fichier SUID s'exécute avec les droits de son propriétaire, ici root.

| Fichier | Rôle |
|---|---|
| `/usr/bin/passwd` | changer son mot de passe (écrit `/etc/shadow`) |
| `/usr/bin/chfn`, `/usr/bin/chsh` | changer ses informations et son shell (écrit `/etc/passwd`) |
| `/usr/bin/gpasswd`, `/usr/bin/newgrp` | administrer un groupe, changer de groupe courant |
| `/usr/bin/su` | changer d'utilisateur, inutilisable vers root puisque root est verrouillé |
| `/usr/bin/sudo` | élévation contrôlée par sudoers |
| `/usr/bin/mount`, `/usr/bin/umount` | monter les supports marqués `user` dans fstab (aucun ici) |
| `/usr/lib/dbus-1.0/dbus-daemon-launch-helper` | lancer les services D-Bus système |
| `/usr/lib/openssh/ssh-keysign` | authentification « hostbased » de SSH, désactivée par défaut |

`fusermount3` (montage FUSE par un utilisateur) ne sert à rien ici : son bit SUID est retiré avec `dpkg-statoverride`, qui tient même après une mise à jour du paquet. `chfn` et `chsh` pourraient suivre le même chemin, nous les avons gardés car ce sont des outils Debian standard sans usage dangereux connu.

## 3. Défense

**Force brute SSH.** Testé depuis l'hôte : `root` et `alice` reçoivent `Permission denied (publickey)`, et après 5 échecs avec des comptes inventés fail2ban ajoute l'IP dans `f2b-table` et la connexion suivante expire. Même sans fail2ban, deviner une clé ed25519 n'est pas réaliste. Limite : un attaquant qui change d'adresse IP à chaque essai (botnet) n'est jamais banni, il reste seulement bloqué par l'obligation d'avoir une clé.

**Vol du mot de passe d'un admin.** Le mot de passe ne permet pas d'entrer en SSH : il faut la clé privée. Il ne sert qu'à sudo, une fois connecté, et à la console. Limite : si la clé privée est volée en même temps, l'attaquant entre. Nos clés de test n'ont pas de phrase de passe, en production il en faudrait une, voire un second facteur (TOTP).

**Utilisateur curieux.** Un dev ne lit ni `/srv/clients` ni le répertoire d'un collègue (700), un commercial ne voit pas `/srv/projets`, et personne hors admins n'accède aux sauvegardes. Les ACL par défaut gardent ces règles pour les fichiers créés plus tard. Limite : un admin voit tout, et rien n'est chiffré sur le disque.

**Compte freelance ou support compromis.** Un freelance n'a pas d'accès SSH, pas de sudo, n'atteint que `/srv/projets/externe` et son compte expire seul à la fin du semestre. Support a une seule commande en sudo, dans un script qu'il ne peut pas modifier, sans pager et sans choix du fichier lu. Limite : support peut se connecter en SSH et lire les fichiers lisibles par tous.

**Suppression accidentelle ou rançongiciel.** Les versions datées permettent de revenir jusqu'à 7 jours en arrière, contrairement à un miroir qui recopierait la suppression. Limite importante : la sauvegarde est sur la même machine. Un attaquant devenu root, une panne de l'hyperviseur ou un vol l'emportent avec le serveur. La règle 3-2-1 demanderait une copie sur une autre machine, hors site.

**Ce que la configuration ne couvre pas.** L'accès physique à la console (GRUB sans mot de passe, démarrage en mode secours), une faille inconnue dans OpenSSH, un administrateur malveillant, l'absence de journalisation détaillée (auditd) et de copie des journaux sur une autre machine.

## 4. Procédure de restauration d'une sauvegarde

Les sauvegardes sont sur le second disque, dans `/sauvegardes/versions/`, une version par exécution, nommée `AAAA-MM-JJ_HHMMSS`. Le lien `derniere` pointe vers la plus récente. Chaque version contient une copie complète de `etc/` et `srv/` (les fichiers inchangés sont des liens durs, ils ne prennent pas de place en plus). Seuls les administrateurs y ont accès.

Exemple : un fichier `/srv/projets/site/index.html` a été supprimé ou abîmé, on veut la version d'avant-hier.

1. Lister les versions disponibles :
   ```bash
   sudo ls /sauvegardes/versions/
   ```
2. Retrouver le fichier dans la version voulue :
   ```bash
   sudo ls -l /sauvegardes/versions/2026-11-01_023000/srv/projets/site/
   ```
3. Restaurer d'abord vers un dossier de test, jamais directement sur l'original :
   ```bash
   sudo mkdir -p /root/restauration
   sudo rsync -aAX /sauvegardes/versions/2026-11-01_023000/srv/projets/site/index.html /root/restauration/
   ```
4. Contrôler le fichier restauré (contenu, droits, ACL) :
   ```bash
   sudo diff /root/restauration/index.html /srv/projets/site/index.html
   sudo getfacl /root/restauration/index.html
   ```
5. Remettre le fichier à sa place, en gardant droits et ACL :
   ```bash
   sudo rsync -aAX /root/restauration/index.html /srv/projets/site/index.html
   sudo rm -rf /root/restauration
   ```

Pour un dossier entier, même principe avec un `/` final sur la source (on copie le contenu du dossier) : `rsync -aAX <version>/srv/projets/ /root/restauration/projets/`.

Le test de restauration est automatisé dans `verifier.sh` (test B4) : il restaure `/srv` et `/etc/hostname` depuis la plus ancienne version vers un dossier temporaire, compare avec l'original et contrôle que les ACL sont revenues, puis supprime le dossier.
