#!/bin/bash
# installer.sh
# Projet XTI302-CYB, contexte A : agence web Pixelia
#
# Reconstruit toute la configuration du serveur à partir du dépôt, sur une
# Debian 13 fraîchement installée (snapshot "vierge") :
#   paquets, comptes et ACL, sudo, root, SSH, journal, pare-feu, fail2ban,
#   mises à jour automatiques, second disque, sauvegarde planifiée.
#
# Le script peut être relancé sans danger : chaque étape vérifie l'état
# avant d'agir. En particulier le second disque n'est formaté que s'il est
# vide : les sauvegardes existantes ne sont jamais effacées.
#
# Usage : sudo ./installer.sh   (depuis le dossier du dépôt, ex. /opt/xti302-cyb)

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$REPO/config"
LABEL_DISQUE="SAUVEGARDES"
POINT_MONTAGE="/sauvegardes"
# Programmes SUID dont le serveur n'a pas besoin (D3)
SUID_INUTILES="/usr/bin/fusermount3"
PAQUETS=(sudo acl openssh-server rsync nftables fail2ban python3-systemd unattended-upgrades parted e2fsprogs)

etape() {
    echo
    echo "=== $* ==="
}

info() {
    echo "[installer] $*"
}

erreur() {
    echo "Erreur : $*" >&2
    exit 1
}

# copier SOURCE DESTINATION MODE : copie un fichier du dépôt, propriété de root
copier() {
    install -D -o root -g root -m "$3" "$1" "$2"
    info "copié : $2"
}

# Liste les membres d'un groupe, y compris ceux dont c'est le groupe principal
# (getent group ne montre que les membres secondaires)
membres() {
    local gid
    gid="$(getent group "$1" | cut -d: -f3)"
    [[ -z "$gid" ]] && return 0
    {
        getent group "$1" | cut -d: -f4 | tr ',' '\n'
        getent passwd | awk -F: -v gid="$gid" '$4 == gid { print $1 }'
    } | grep -v '^$' | sort -u
}

verifier_prerequis() {
    if [[ $EUID -ne 0 ]]; then
        erreur "ce script doit être lancé en root"
    fi
    if [[ $# -gt 0 ]]; then
        erreur "ce script ne prend pas d'argument"
    fi
    if [[ ! -f /etc/debian_version ]]; then
        erreur "ce script est prévu pour Debian"
    fi
    local f
    for f in creer_comptes.sh analyse_logs.sh sauvegarde.sh verifier.sh comptes.csv; do
        [[ -f "$REPO/$f" ]] || erreur "fichier manquant dans le dépôt : $f"
    done
}

# Les scripts du dépôt sont lancés par root : ils doivent appartenir à root
# et n'être modifiables que par lui, sinon l'utilisateur qui pourrait les
# modifier deviendrait root à la prochaine exécution.
proteger_depot() {
    etape "Droits du dépôt"
    chown -R root:root "$REPO"
    chmod -R go-w "$REPO"
    chmod 0755 "$REPO"/*.sh
    info "$REPO appartient à root, non modifiable par les autres"
}

installer_paquets() {
    etape "Paquets (dépôts Debian officiels)"
    apt-get update -q
    apt-get install -y -q "${PAQUETS[@]}"
}

# C3 : une Debian fraîche peut avoir un compte dans le groupe sudo
# (si aucun mot de passe root n'a été donné à l'installation)
vider_groupe_sudo() {
    etape "Comptes ayant déjà sudo"
    local compte
    for compte in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
        gpasswd -d "$compte" sudo >/dev/null
        info "$compte retiré du groupe sudo"
    done
    info "groupe sudo vide"
}

creer_comptes() {
    etape "Comptes, groupes, clés et ACL (C1, C2)"
    "$REPO/creer_comptes.sh"
}

configurer_sudo() {
    etape "sudo (C3)"
    local f nom
    for f in "$CONFIG"/sudoers.d/*; do
        nom="$(basename "$f")"
        copier "$f" "/etc/sudoers.d/$nom" 0440
    done
    # visudo -c contrôle toute la configuration ; en cas d'erreur on retire
    # nos fichiers pour ne pas casser sudo pour tout le monde
    if ! visudo -c >/dev/null; then
        for f in "$CONFIG"/sudoers.d/*; do
            rm -f "/etc/sudoers.d/$(basename "$f")"
        done
        erreur "configuration sudo invalide, fichiers retirés"
    fi
    info "visudo -c : configuration valide"

    # Script lancé en root par support : root:root 0755
    copier "$REPO/analyse_logs.sh" /usr/local/sbin/analyse_logs.sh 0755
    copier "$REPO/sauvegarde.sh" /usr/local/sbin/sauvegarde.sh 0755
}

# Les admins ont besoin d'un mot de passe : sudo le demande, et c'est lui qui
# permet d'entrer par la console de l'hyperviseur une fois root verrouillé.
mots_de_passe_admins() {
    etape "Mots de passe des administrateurs"
    local admin etat
    for admin in $(membres admins); do
        etat="$(passwd -S "$admin" | awk '{ print $2 }')"
        if [[ "$etat" == "P" ]]; then
            info "$admin a déjà un mot de passe"
        elif [[ -t 0 ]]; then
            echo "Choisissez le mot de passe de $admin (sudo et console de secours) :"
            until passwd "$admin"; do
                echo "Recommencez."
            done
        else
            info "ATTENTION : $admin n'a pas de mot de passe (lancez : passwd $admin)"
        fi
    done
}

# C4 : root verrouillé, répertoires personnels en 700
durcir_comptes() {
    etape "Compte root et répertoires personnels (C4)"
    local admin admin_ok=0
    for admin in $(membres admins); do
        if [[ "$(passwd -S "$admin" | awk '{ print $2 }')" == "P" ]]; then
            admin_ok=1
        fi
    done
    # Sans administrateur ayant un mot de passe, verrouiller root couperait
    # tout accès administrateur : on refuse.
    if [[ $admin_ok -eq 1 ]]; then
        passwd -l root >/dev/null
        info "compte root verrouillé"
    else
        info "ATTENTION : root NON verrouillé, aucun administrateur n'a de mot de passe"
    fi

    local home
    for home in /home/*/; do
        [[ -d "$home" ]] || continue
        chmod 0700 "$home"
    done
    # Les comptes créés plus tard auront aussi un répertoire en 700
    sed -i 's/^#\?DIR_MODE=.*/DIR_MODE=0700/' /etc/adduser.conf
    if grep -q '^#\?HOME_MODE' /etc/login.defs; then
        sed -i 's/^#\?HOME_MODE.*/HOME_MODE\t0700/' /etc/login.defs
    else
        printf 'HOME_MODE\t0700\n' >> /etc/login.defs
    fi
    info "répertoires personnels en 700, y compris pour les futurs comptes"
}

configurer_ssh() {
    etape "SSH (S1 à S5)"
    # Garde-fou : au moins un membre de acces_ssh doit avoir une clé installée,
    # sinon plus personne ne pourrait se connecter après le rechargement
    local compte home avec_cle=0
    for compte in $(membres acces_ssh); do
        home="$(getent passwd "$compte" | cut -d: -f6)"
        if [[ -s "$home/.ssh/authorized_keys" ]]; then
            avec_cle=1
        fi
    done
    if [[ $avec_cle -eq 0 ]]; then
        erreur "aucun compte de acces_ssh n'a de clé : SSH non durci pour ne pas vous enfermer dehors"
    fi

    local conf=/etc/ssh/sshd_config.d/10-hardening.conf
    local sauvegarde_conf=""
    if [[ -f "$conf" ]]; then
        sauvegarde_conf="$(mktemp)"
        cp -p "$conf" "$sauvegarde_conf"
    fi
    copier "$CONFIG/ssh/sshd_config.d/10-hardening.conf" "$conf" 0644
    copier "$CONFIG/profile.d/tmout.sh" /etc/profile.d/tmout.sh 0644

    # S5 : on valide avant d'appliquer ; en cas d'erreur on remet l'ancien fichier
    if ! sshd -t; then
        if [[ -n "$sauvegarde_conf" ]]; then
            cp -p "$sauvegarde_conf" "$conf"
        else
            rm -f "$conf"
        fi
        erreur "sshd -t a détecté une erreur, configuration SSH non appliquée"
    fi
    rm -f "$sauvegarde_conf"
    info "sshd -t : configuration valide"
    # reload : applique la configuration sans couper les sessions ouvertes
    systemctl reload ssh
    info "SSH rechargé"
}

configurer_journal() {
    etape "Journal persistant (J3)"
    copier "$CONFIG/journald/10-persistent.conf" /etc/systemd/journald.conf.d/10-persistent.conf 0644
    install -d -m 2755 -g systemd-journal /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald
    journalctl --flush
    info "journal écrit dans /var/log/journal"
}

configurer_parefeu() {
    etape "Pare-feu nftables (J2)"
    # nft -c : vérifie le fichier sans rien appliquer
    nft -c -f "$CONFIG/nftables.conf" || erreur "nftables.conf invalide"
    copier "$CONFIG/nftables.conf" /etc/nftables.conf 0755
    systemctl enable --now nftables >/dev/null 2>&1
    # reload relit /etc/nftables.conf sans tout vider ; un restart lancerait
    # "nft flush ruleset" (ExecStop du service) et effacerait la table de fail2ban
    systemctl reload nftables
    info "pare-feu actif et chargé au démarrage"
}

configurer_fail2ban() {
    etape "fail2ban (J1)"
    copier "$CONFIG/fail2ban/jail.d/sshd-pixelia.conf" /etc/fail2ban/jail.d/sshd-pixelia.conf 0644
    # Si nftables est redémarré (donc vidé), fail2ban redémarre avec lui et
    # remet sa table : les bannissements sont repris de sa base de données
    copier "$CONFIG/systemd/fail2ban-nftables.conf" /etc/systemd/system/fail2ban.service.d/nftables.conf 0644
    systemctl daemon-reload
    fail2ban-client -t >/dev/null || erreur "configuration fail2ban invalide"
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
    info "fail2ban actif (jail sshd)"
}

configurer_mises_a_jour() {
    etape "Mises à jour automatiques (D1)"
    copier "$CONFIG/apt/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades 0644
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
    info "unattended-upgrades activé"
}

# D3 : un fichier SUID s'exécute avec les droits de son propriétaire (root).
# On retire le bit SUID des programmes dont le serveur n'a pas besoin.
# dpkg-statoverride rend le changement durable : une mise à jour du paquet
# ne remettra pas le bit SUID.
retirer_suid_inutiles() {
    etape "Fichiers SUID inutiles (D3)"
    local f
    # fusermount3 : montage de systèmes de fichiers FUSE par un utilisateur,
    # inutile sur ce serveur
    for f in $SUID_INUTILES; do
        [[ -e "$f" ]] || continue
        if ! dpkg-statoverride --list "$f" >/dev/null; then
            dpkg-statoverride --update --add root root 0755 "$f"
        fi
        info "bit SUID retiré : $f"
    done
}

# Cherche le second disque : un disque entier, sans partition ni système de
# fichiers, entre 512 Mo et 4 Go. On exige un seul candidat pour ne jamais
# formater le mauvais disque.
trouver_disque_vide() {
    local nom type taille candidats=()
    while read -r nom type taille; do
        [[ "$type" == "disk" ]] || continue
        (( taille >= 536870912 && taille <= 4294967296 )) || continue
        # une seule ligne = pas de partition ; FSTYPE vide = pas formaté
        [[ "$(lsblk -n "$nom" | wc -l)" -eq 1 ]] || continue
        [[ -z "$(lsblk -dno FSTYPE "$nom")" ]] || continue
        candidats+=("$nom")
    done < <(lsblk -dpnb -o NAME,TYPE,SIZE)

    if [[ ${#candidats[@]} -ne 1 ]]; then
        return 1
    fi
    echo "${candidats[0]}"
}

preparer_disque() {
    etape "Second disque pour les sauvegardes (B1, B3)"
    local partition disque uuid
    partition="$(blkid -L "$LABEL_DISQUE" 2>/dev/null || true)"

    if [[ -n "$partition" ]]; then
        info "disque déjà préparé ($partition), rien n'est formaté"
    else
        disque="$(trouver_disque_vide)" || erreur "second disque introuvable ou ambigu (lsblk pour vérifier)"
        info "disque vide trouvé : $disque, création d'une partition ext4"
        parted -s "$disque" mklabel gpt mkpart sauvegardes ext4 1MiB 100%
        udevadm settle
        partition="$(lsblk -lnpo NAME,TYPE "$disque" | awk '$2 == "part" { print $1; exit }')"
        mkfs.ext4 -q -L "$LABEL_DISQUE" "$partition"
    fi

    # Montage permanent par UUID ; nofail : la machine démarre même sans le disque
    uuid="$(blkid -s UUID -o value "$partition")"
    install -d -m 0750 "$POINT_MONTAGE"
    if ! grep -q "UUID=$uuid" /etc/fstab; then
        echo "UUID=$uuid $POINT_MONTAGE ext4 defaults,nodev,nosuid,noexec,nofail 0 2" >> /etc/fstab
        info "montage ajouté à /etc/fstab"
    fi
    systemctl daemon-reload
    if ! mountpoint -q "$POINT_MONTAGE"; then
        mount "$POINT_MONTAGE"
    fi

    # B3 : accessible aux seuls administrateurs
    chown root:admins "$POINT_MONTAGE"
    chmod 0750 "$POINT_MONTAGE"
    install -d -o root -g admins -m 0750 "$POINT_MONTAGE/versions"
    info "$POINT_MONTAGE monté, root:admins 750"
}

planifier_sauvegarde() {
    etape "Planification de la sauvegarde (B2)"
    copier "$CONFIG/systemd/sauvegarde.service" /etc/systemd/system/sauvegarde.service 0644
    copier "$CONFIG/systemd/sauvegarde.timer" /etc/systemd/system/sauvegarde.timer 0644
    touch /var/log/sauvegarde.log
    chmod 0640 /var/log/sauvegarde.log
    chown root:adm /var/log/sauvegarde.log
    systemctl daemon-reload
    systemctl enable --now sauvegarde.timer >/dev/null 2>&1
    info "sauvegarde.timer actif : $(systemctl show -p NextElapseUSecRealtime --value sauvegarde.timer)"

    # Une première version, pour que la restauration soit testable tout de suite
    /usr/local/sbin/sauvegarde.sh
}

main() {
    verifier_prerequis "$@"
    proteger_depot
    installer_paquets
    vider_groupe_sudo
    creer_comptes
    configurer_sudo
    mots_de_passe_admins
    durcir_comptes
    configurer_ssh
    configurer_journal
    configurer_parefeu
    configurer_fail2ban
    configurer_mises_a_jour
    retirer_suid_inutiles
    preparer_disque
    planifier_sauvegarde

    etape "Terminé"
    info "Avant de fermer cette session, testez dans une autre fenêtre : ssh <admin>@<IP>"
    info "Puis lancez : sudo $REPO/verifier.sh"
}

main "$@"
