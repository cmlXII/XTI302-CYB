#!/bin/bash
# Projet XTI302-CYB - Contexte A : Agence web Pixelia

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CSV="$SCRIPT_DIR/comptes.csv"

if [[ "$EUID" -ne 0 ]]; then
    echo "Erreur : lancer ce script en root." >&2
    exit 1
fi

if [[ ! -f "$CSV" ]]; then
    echo "Erreur : fichier comptes.csv introuvable." >&2
    exit 1
fi

for commande in groupadd useradd usermod getent setfacl chage; do
    if ! command -v "$commande" >/dev/null 2>&1; then
        echo "Erreur : commande manquante : $commande" >&2
        exit 1
    fi
done

# Groupes métier et groupes de sécurité
for groupe in admins support acces_ssh dev design commercial freelance; do
    getent group "$groupe" >/dev/null || groupadd "$groupe"
done

# Lire le fichier CSV et créer les comptes
while IFS=';' read -r login nom groupe_principal groupes_secondaires; do
    [[ "$login" == "login" || -z "$login" ]] && continue

    if ! getent group "$groupe_principal" >/dev/null; then
        groupadd "$groupe_principal"
    fi

    if [[ -n "$groupes_secondaires" ]]; then
        IFS=',' read -r -a groupes <<< "$groupes_secondaires"
        for groupe in "${groupes[@]}"; do
            getent group "$groupe" >/dev/null || groupadd "$groupe"
        done
    fi

    if id "$login" >/dev/null 2>&1; then
        echo "Compte existant : $login"
    else
        useradd -m -g "$groupe_principal" -s /bin/bash "$login"
        echo "Compte créé : $login"
    fi

    if [[ -n "$groupes_secondaires" ]]; then
        usermod -aG "$groupes_secondaires" "$login"
    fi

    # Les répertoires personnels ne doivent pas être lisibles par les autres
    home_dir="$(getent passwd "$login" | cut -d: -f6)"
    if [[ -n "$home_dir" && -d "$home_dir" ]]; then
        chmod 700 "$home_dir"
    fi
done < "$CSV"

# Répertoires du contexte A
install -d -o root -g root -m 0755 /srv/projets
install -d -o root -g root -m 0755 /srv/projets/externe
install -d -o root -g root -m 0755 /srv/maquettes
install -d -o root -g root -m 0755 /srv/clients

# Retirer les ACL précédentes sur ces répertoires pour repartir proprement
setfacl -b /srv/projets /srv/projets/externe /srv/maquettes /srv/clients
setfacl -k /srv/projets /srv/projets/externe /srv/maquettes /srv/clients

# /srv/projets : dev en écriture, design en lecture
setfacl -m u::rwx,g::r-x,g:dev:rwx,g:design:r-x,m::rwx,o::--- /srv/projets
setfacl -d -m u::rwx,g::r-x,g:dev:rwx,g:design:r-x,m::rwx,o::--- /srv/projets

setfacl -m g:freelance:--x /srv/projets

# /srv/projets/externe : dev et freelance en écriture, design en lecture
setfacl -m u::rwx,g::r-x,g:dev:rwx,g:design:r-x,g:freelance:rwx,m::rwx,o::--- /srv/projets/externe
setfacl -d -m u::rwx,g::r-x,g:dev:rwx,g:design:r-x,g:freelance:rwx,m::rwx,o::--- /srv/projets/externe

# /srv/maquettes : design en écriture, dev et commercial en lecture
setfacl -m u::rwx,g::r-x,g:dev:r-x,g:design:rwx,g:commercial:r-x,m::rwx,o::--- /srv/maquettes
setfacl -d -m u::rwx,g::r-x,g:dev:r-x,g:design:rwx,g:commercial:r-x,m::rwx,o::--- /srv/maquettes

# /srv/clients : commercial en écriture
setfacl -m u::rwx,g::r-x,g:commercial:rwx,m::rwx,o::--- /srv/clients
setfacl -d -m u::rwx,g::r-x,g:commercial:rwx,m::rwx,o::--- /srv/clients

echo "Comptes, répertoires et ACL configurés."
echo "Attention : les clés SSH et les dates d'expiration restent à configurer."
