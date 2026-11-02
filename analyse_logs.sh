#!/bin/bash
# analyse_logs.sh
# Projet XTI302-CYB, exigence J4
#
# Rapport des connexions SSH :
#   - échecs d'authentification par adresse IP ;
#   - comptes visés par ces échecs ;
#   - connexions réussies.
#
# Sur Debian 13 minimale il n'y a pas de /var/log/auth.log : les messages de
# SSH sont dans le journal systemd, sous les noms sshd et sshd-session.
#
# Ce qui compte comme un échec :
#   - "Failed <méthode> for <compte> from <IP>" pour un compte existant ;
#   - "Invalid user <compte> from <IP>" (compte inexistant, une fois par
#     connexion ; la ligne "Failed ... for invalid user" qui peut suivre
#     n'est pas recomptée) ;
#   - "User <compte> from <IP> not allowed because ..." (refus AllowGroups).
#
# Codes de sortie :
#   0 : aucune adresse n'atteint le seuil
#   1 : erreur (option invalide, droits insuffisants...)
#   2 : alerte, au moins une adresse atteint le seuil
#
# Le compte support peut lancer ce script en root via sudo (exigence C3).
# Usage : analyse_logs.sh [-s seuil] [-p periode] [-f fichier] [-h]

set -euo pipefail

# Lancé en root : on ne fait confiance ni au PATH ni au pager de l'appelant.
# Un journalctl qui ouvrirait less permettrait d'obtenir un shell root (!sh).
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export SYSTEMD_PAGER="" PAGER=cat

SEUIL=10        # nombre d'échecs par IP à partir duquel on alerte
PERIODE=24h     # période analysée dans le journal
FICHIER=""      # si renseigné, on lit ce fichier au lieu du journal

usage() {
    cat <<EOF
Usage : $(basename "$0") [-s seuil] [-p periode] [-f fichier] [-h]
  -s seuil    nombre d'échecs par adresse IP déclenchant l'alerte (défaut : $SEUIL)
  -p periode  période du journal à analyser : 30min, 24h, 7d... (défaut : $PERIODE)
  -f fichier  analyser un fichier de journal au lieu du journal système
  -h          afficher cette aide
Code de sortie : 0 = rien à signaler, 2 = seuil atteint, 1 = erreur
EOF
}

erreur() {
    echo "Erreur : $*" >&2
    exit 1
}

lire_options() {
    local opt
    while getopts ":s:p:f:h" opt; do
        case "$opt" in
            s) SEUIL=$OPTARG ;;
            p) PERIODE=$OPTARG ;;
            f) FICHIER=$OPTARG ;;
            h) usage; exit 0 ;;
            :) erreur "l'option -$OPTARG attend une valeur" ;;
            *) erreur "option inconnue : -$OPTARG (voir -h)" ;;
        esac
    done
    shift $((OPTIND - 1))
    if [[ $# -gt 0 ]]; then
        erreur "argument en trop : $1 (voir -h)"
    fi
    if [[ ! "$SEUIL" =~ ^[1-9][0-9]*$ ]]; then
        erreur "le seuil doit être un entier positif"
    fi
    if [[ ! "$PERIODE" =~ ^[1-9][0-9]*(min|h|d)$ ]]; then
        erreur "période invalide : $PERIODE (exemples : 30min, 24h, 7d)"
    fi
}

verifier_droits() {
    if [[ -n "$FICHIER" ]]; then
        # Via sudo, seul un administrateur peut choisir le fichier lu en root.
        # Sinon support pourrait faire lire n'importe quel fichier par root.
        if [[ -n "${SUDO_USER:-}" && " $(id -nG "$SUDO_USER") " != *" admins "* ]]; then
            erreur "l'option -f n'est pas autorisée via sudo pour $SUDO_USER"
        fi
        if [[ ! -f "$FICHIER" || ! -r "$FICHIER" ]]; then
            erreur "fichier illisible : $FICHIER"
        fi
    elif [[ $EUID -ne 0 ]]; then
        erreur "lire le journal système demande les droits root (sudo)"
    fi
}

lire_journal() {
    if [[ -n "$FICHIER" ]]; then
        cat -- "$FICHIER"
    else
        journalctl -t sshd -t sshd-session --since "-$PERIODE" --no-pager -o short-iso
    fi
}

# Le rapport est construit par awk à partir des lignes du journal.
# Format d'une ligne : DATE MACHINE PROGRAMME[PID]: MESSAGE
analyser() {
    awk -v seuil="$SEUIL" -v source="$1" '
    function echec(ip, compte, note) {
        total++
        par_ip[ip]++
        par_compte[compte note]++
    }
    {
        date = $1
        msg = $0
        # on garde seulement le message, après "PROGRAMME[PID]: "
        if (!sub(/^[^ ]+ [^ ]+ [^ ]+: /, "", msg)) next
        split(msg, m, " ")

        if (m[1] == "Failed" && m[3] == "for") {
            # compte inexistant : déjà compté par la ligne "Invalid user"
            if (m[4] == "invalid" && m[5] == "user") next
            if (m[5] == "from") echec(m[6], m[4], "")
        }
        else if (m[1] == "Invalid" && m[2] == "user") {
            if (m[3] == "from") echec(m[4], "(vide)", " (inexistant)")
            else echec(m[5], m[3], " (inexistant)")
        }
        else if (m[1] == "User" && m[3] == "from" && m[5] == "not" && m[6] == "allowed") {
            echec(m[4], m[2], " (refusé, hors AllowGroups)")
        }
        else if (m[1] == "Accepted" && m[3] == "for" && m[5] == "from") {
            nb_ok++
            reussies[nb_ok] = sprintf("  %-26s %-12s %-16s %s", date, m[4], m[6], m[2])
        }
    }
    END {
        print "=== Rapport des connexions SSH ==="
        print "Source : " source
        print "Seuil d'\''alerte : " seuil " échecs ou plus pour une même adresse IP"
        print ""

        print "--- Échecs d'\''authentification par adresse IP ---"
        if (total == 0) print "  aucun échec"
        else {
            printf "  %6s  %s\n", "ÉCHECS", "ADRESSE IP"
            fflush()
            tri = "sort -k1,1nr -k2,2"
            for (ip in par_ip) {
                marque = ""
                if (par_ip[ip] >= seuil) {
                    marque = "   <-- ALERTE"
                    nb_alertes++
                    alertes = alertes " " ip
                }
                printf "  %6d  %s%s\n", par_ip[ip], ip, marque | tri
            }
            close(tri)
        }
        print ""

        print "--- Comptes visés par ces échecs ---"
        if (total == 0) print "  aucun"
        else {
            printf "  %6s  %s\n", "ÉCHECS", "COMPTE"
            fflush()
            tri = "sort -k1,1nr -k2,2"
            for (c in par_compte) printf "  %6d  %s\n", par_compte[c], c | tri
            close(tri)
        }
        print ""

        print "--- Connexions réussies ---"
        if (nb_ok == 0) print "  aucune"
        else {
            printf "  %-26s %-12s %-16s %s\n", "DATE", "COMPTE", "ADRESSE IP", "MÉTHODE"
            for (i = 1; i <= nb_ok; i++) print reussies[i]
        }
        print ""

        print "--- Bilan ---"
        printf "  %d échec(s), %d connexion(s) réussie(s)\n", total, nb_ok
        if (nb_alertes > 0) {
            printf "  ALERTE : %d adresse(s) atteignent le seuil de %d échecs :%s\n", nb_alertes, seuil, alertes
            exit 2
        }
        print "  Aucune adresse n'\''atteint le seuil."
        exit 0
    }'
}

main() {
    lire_options "$@"
    verifier_droits

    local source code
    if [[ -n "$FICHIER" ]]; then
        source="fichier $FICHIER"
    else
        source="journal système, dernières $PERIODE"
    fi

    # Le code de sortie d'awk (0 ou 2) devient celui du script
    if lire_journal | analyser "$source"; then
        code=0
    else
        code=$?
    fi
    exit "$code"
}

main "$@"
