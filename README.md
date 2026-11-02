# XTI302-CYB : durcir un serveur Linux et le prouver

Projet d'Administration systèmes avancées et Scripting, EFREI Paris, B2 CS2.
Groupe : Ilian Boubadra, Ilhan, Camille.

## Contexte choisi

**Contexte A : agence web Pixelia.**

| Répertoire | dev | design | commercial | freelance |
|---|---|---|---|---|
| /srv/projets | lecture/écriture | lecture | - | - |
| /srv/projets/externe | lecture/écriture | lecture | - | lecture/écriture |
| /srv/maquettes | lecture | lecture/écriture | lecture | - |
| /srv/clients | - | - | lecture/écriture | - |

Particularité : les comptes freelance expirent à la fin du semestre (31/01/2027) et n'ont pas sudo.

## Prérequis

- Une VM Debian 13 minimale (sans interface graphique, avec le serveur SSH), créée avec un mot de passe root et un premier compte `installeur`.
- Un second disque virtuel de 1 à 2 Go, vide (il est partitionné et formaté par `installer.sh` seulement s'il est vide).
- Un accès Internet pour les paquets (dépôts Debian officiels uniquement).
- Les clés publiques des comptes autorisés en SSH dans `config/cles/<login>.pub`. Aucune clé privée dans le dépôt (voir `.gitignore`).

## Installation

Depuis la VM vierge, connecté en `installeur` puis passé root avec `su -` :

```bash
apt update && apt install -y git
git clone https://github.com/cmlXII/XTI302-CYB.git /opt/xti302-cyb
cd /opt/xti302-cyb
bash installer.sh
```

Le dépôt est cloné dans `/opt` et appartient à root : ces scripts sont lancés en root, ils ne doivent être modifiables par personne d'autre.

`installer.sh` demande un mot de passe pour chaque administrateur qui n'en a pas encore (il sert pour sudo et pour la console de secours, puisque root est verrouillé). Il peut être relancé sans danger.

**Avant de fermer la session**, vérifier depuis l'hôte, dans une autre fenêtre, qu'un administrateur se connecte bien : `ssh ilian@<IP de la VM>`.

## Vérification

```bash
sudo /opt/xti302-cyb/verifier.sh
```

Chaque exigence est testée par une fonction `test_<ID>` et affiche `[OK]` ou `[KO]`, puis le bilan. Code de sortie 0 si tout est conforme, 1 sinon. Le script ne modifie pas le système (ses fichiers de test sont supprimés à la fin).

Pour que le test incrémental de B1 passe, il faut au moins deux versions de sauvegarde : `sudo /usr/local/sbin/sauvegarde.sh` une seconde fois après l'installation.

## Contenu du dépôt

| Fichier | Rôle | Exigences |
|---|---|---|
| `comptes.csv` | comptes et groupes (format imposé) | C1 |
| `creer_comptes.sh` | comptes, groupes, clés SSH, répertoires et ACL de /srv | C1, C2, C4 |
| `installer.sh` | reconstruit toute la configuration sur la VM vierge | tout |
| `analyse_logs.sh` | rapport des connexions SSH, code 2 si le seuil est atteint | J4 |
| `sauvegarde.sh` | sauvegarde incrémentale versionnée de /etc et /srv | B1 |
| `verifier.sh` | teste chaque exigence | tout |
| `config/sudoers.d/` | sudo des admins, règle unique de support | C3 |
| `config/ssh/sshd_config.d/10-hardening.conf` | durcissement SSH | S1 à S5 |
| `config/profile.d/tmout.sh` | fermeture des shells inactifs | S4 |
| `config/fail2ban/jail.d/sshd-pixelia.conf` | jail fail2ban pour SSH | J1 |
| `config/nftables.conf` | pare-feu, refus par défaut | J2 |
| `config/journald/10-persistent.conf` | journal persistant | J3 |
| `config/apt/20auto-upgrades` | mises à jour automatiques | D1 |
| `config/systemd/` | timer de sauvegarde, lien fail2ban/nftables | B2, J1 |
| `config/suid_attendus.txt` | liste des fichiers SUID expliqués | D3 |
| `config/cles/` | clés publiques des comptes de acces_ssh | C1 |
| `tests/ssh_exemple_debian13.log` | journal d'exemple pour tester analyse_logs.sh | J4 |
| `DOSSIER.md` | conformité, choix techniques, défense, restauration | |

## Commandes utiles

```bash
sudo /usr/local/sbin/analyse_logs.sh -s 10 -p 24h   # rapport SSH (support peut le lancer via sudo)
sudo fail2ban-client status sshd                     # adresses bannies
sudo fail2ban-client set sshd unbanip <IP>           # débannir une adresse
sudo nft list ruleset                                # pare-feu et table de fail2ban
systemctl list-timers sauvegarde.timer               # prochaine sauvegarde
sudo tail /var/log/sauvegarde.log                    # historique des sauvegardes
```
