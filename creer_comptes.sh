#!/bin/bash
# creer_comptes.sh
# Projet XTI302-CYB, contexte A : agence web Pixelia
#
# Crée les groupes et les comptes à partir de comptes.csv, installe les clés
# publiques SSH, puis crée les répertoires de /srv avec leurs droits et ACL.
# Exigences couvertes : C1, C2 (et les répertoires personnels en 700 pour C4).
#
# Le script est idempotent : le relancer ne crée pas de doublon et remet
# simplement les comptes, les clés et les ACL dans l'état décrit par le dépôt.
#
# Usage : sudo ./creer_comptes.sh [fichier.csv]

set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CSV="${1:-$REPO/comptes.csv}"
DOSSIER_CLES="$REPO/config/cles"
ENTETE="login;nom;groupe_principal;groupes_secondaires"

# Groupes créés même s'ils n'ont encore aucun membre (les ACL en ont besoin)
GROUPES_FIXES="admins support acces_ssh dev design commercial freelance"

# Particularité du contexte A : les freelances expirent à la fin du semestre
EXPIRATION_FREELANCE="2027-01-31"

erreur() {
    echo "Erreur : $*" >&2
    exit 1
}

info() {
    echo "[creer_comptes] $*"
}

verifier_prerequis() {
    if [[ $EUID -ne 0 ]]; then
        erreur "ce script doit être lancé en root"
    fi
    if [[ ! -f "$CSV" ]]; then
        erreur "fichier $CSV introuvable"
    fi
    # On compare l'en-tête en retirant un éventuel \r (fichier édité sous Windows)
    if [[ "$(head -n 1 "$CSV" | tr -d '\r')" != "$ENTETE" ]]; then
        erreur "en-tête de $CSV incorrect, attendu : $ENTETE"
    fi
    local cmd
    for cmd in groupadd useradd usermod getent setfacl chage install; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            erreur "commande manquante : $cmd (paquet acl installé ?)"
        fi
    done
}

creer_groupe() {
    if ! getent group "$1" >/dev/null; then
        groupadd "$1"
        info "groupe créé : $1"
    fi
}

# Copie la clé publique du dépôt dans ~/.ssh/authorized_keys.
# Le fichier est réécrit à chaque passage : une clé ajoutée à la main sur le
# serveur disparaît, c'est le dépôt qui fait foi.
installer_cle() {
    local login=$1
    local cle="$DOSSIER_CLES/$login.pub"
    local home groupe
    home="$(getent passwd "$login" | cut -d: -f6)"
    groupe="$(id -gn "$login")"

    if [[ ! -s "$cle" ]]; then
        info "ATTENTION : pas de clé $cle, $login ne pourra pas se connecter en SSH"
        return 0
    fi
    install -d -o "$login" -g "$groupe" -m 0700 "$home/.ssh"
    # tr retire les \r d'une clé copiée depuis Windows, que sshd refuserait
    tr -d '\r' < "$cle" > "$home/.ssh/authorized_keys"
    chown "$login:$groupe" "$home/.ssh/authorized_keys"
    chmod 0600 "$home/.ssh/authorized_keys"
    info "clé SSH installée pour $login"
}

creer_compte() {
    local login=$1 nom=$2 groupe_principal=$3 groupes_secondaires=$4
    local groupe home

    if [[ ! "$login" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        info "ATTENTION : login invalide ignoré : '$login'"
        return 0
    fi

    creer_groupe "$groupe_principal"
    if [[ -n "$groupes_secondaires" ]]; then
        IFS=',' read -r -a liste <<< "$groupes_secondaires"
        for groupe in "${liste[@]}"; do
            creer_groupe "$groupe"
        done
    fi

    if id "$login" >/dev/null 2>&1; then
        # Le compte existe : on remet le groupe principal et le nom du CSV
        usermod -g "$groupe_principal" -c "$nom" "$login"
        info "compte déjà présent, mis à jour : $login"
    else
        useradd -m -g "$groupe_principal" -c "$nom" -s /bin/bash "$login"
        info "compte créé : $login"
    fi

    # -a : ajoute aux groupes sans retirer les autres, donc sans doublon
    if [[ -n "$groupes_secondaires" ]]; then
        usermod -aG "$groupes_secondaires" "$login"
    fi

    # C4 : répertoire personnel lisible par son seul propriétaire
    home="$(getent passwd "$login" | cut -d: -f6)"
    if [[ -n "$home" && -d "$home" ]]; then
        chmod 0700 "$home"
    fi

    # Clé SSH pour les comptes autorisés à se connecter
    if [[ ",$groupes_secondaires," == *",acces_ssh,"* || "$groupe_principal" == "acces_ssh" ]]; then
        installer_cle "$login"
    fi

    # Particularité du contexte A : date d'expiration des freelances
    if [[ "$groupe_principal" == "freelance" || ",$groupes_secondaires," == *",freelance,"* ]]; then
        chage -E "$EXPIRATION_FREELANCE" "$login"
        info "expiration de $login fixée au $EXPIRATION_FREELANCE"
    fi
}

lire_csv() {
    local login nom groupe_principal groupes_secondaires
    # tail saute l'en-tête, tr retire les \r ; le "|| [[ -n $login ]]" traite
    # aussi une dernière ligne sans retour à la ligne
    while IFS=';' read -r login nom groupe_principal groupes_secondaires || [[ -n "$login" ]]; do
        [[ -z "$login" || "$login" == \#* ]] && continue
        creer_compte "$login" "$nom" "$groupe_principal" "$groupes_secondaires"
    done < <(tail -n +2 "$CSV" | tr -d '\r')
}

# appliquer_acl REPERTOIRE ACL_ACCES ACL_DEFAUT
# Repart de zéro à chaque passage (setfacl -b -k), puis pose :
#  - l'ACL d'accès : qui peut entrer dans le répertoire ;
#  - l'ACL par défaut : héritée par les fichiers et dossiers créés plus tard.
# Propriétaire root, groupe propriétaire et autres sans aucun droit : seules
# les entrées nommées donnent accès.
appliquer_acl() {
    local rep=$1 acces=$2 defaut=$3
    install -d -o root -g root -m 0770 "$rep"
    setfacl -b -k "$rep"
    setfacl -m "u::rwx,g::---,o::---,$acces" "$rep"
    setfacl -d -m "u::rwx,g::---,o::---,$defaut" "$rep"
    info "ACL appliquées sur $rep"
}

creer_repertoires() {
    install -d -o root -g root -m 0755 /srv

    # /srv/projets : dev rw, design r.
    # freelance a seulement --x (traverser sans lister) pour atteindre externe.
    # Ce --x n'est pas dans l'ACL par défaut : un nouveau sous-dossier de
    # projets ne doit pas être accessible aux freelances.
    appliquer_acl /srv/projets \
        "g:dev:rwx,g:design:r-x,g:freelance:--x" \
        "g:dev:rwx,g:design:r-x"

    # /srv/projets/externe : dev rw, design r, freelance rw
    appliquer_acl /srv/projets/externe \
        "g:dev:rwx,g:design:r-x,g:freelance:rwx" \
        "g:dev:rwx,g:design:r-x,g:freelance:rwx"

    # /srv/maquettes : dev r, design rw, commercial r
    appliquer_acl /srv/maquettes \
        "g:dev:r-x,g:design:rwx,g:commercial:r-x" \
        "g:dev:r-x,g:design:rwx,g:commercial:r-x"

    # /srv/clients : commercial rw
    appliquer_acl /srv/clients \
        "g:commercial:rwx" \
        "g:commercial:rwx"
}

main() {
    if [[ $# -gt 1 ]]; then
        erreur "usage : $0 [fichier.csv]"
    fi
    verifier_prerequis

    local groupe
    for groupe in $GROUPES_FIXES; do
        creer_groupe "$groupe"
    done

    lire_csv
    creer_repertoires
    info "terminé : comptes, clés, répertoires et ACL en place"
}

main "$@"
