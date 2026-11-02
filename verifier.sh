#!/bin/bash
# verifier.sh
# Projet XTI302-CYB, contexte A : agence web Pixelia
#
# Teste automatiquement chaque exigence du cahier des charges et affiche
# [OK] ou [KO] pour chaque test, puis le bilan.
# Il vérifie ce qui doit marcher (un dev écrit dans /srv/projets) et ce qui
# doit être refusé (un commercial ne lit pas /srv/projets).
#
# Il ne modifie jamais le système : les seuls fichiers créés sont des
# fichiers de test, supprimés à la fin (trap EXIT).
#
# Pas de "set -e" : le rôle du script est justement de lancer des commandes
# qui peuvent échouer, un échec doit donner [KO], pas arrêter le script.
# Pas de "pipefail" : dans "commande | grep -q motif", grep s'arrête à la
# première ligne trouvée, la commande reçoit SIGPIPE et le pipeline serait
# considéré comme raté alors que le motif a été trouvé.
# "set -u" est gardé : une variable mal orthographiée est une vraie erreur.
#
# Code de sortie : 0 si tout est conforme, 1 sinon.
# Usage : sudo ./verifier.sh

set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# Messages des commandes en anglais, pour que les grep restent fiables
export LC_ALL=C

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CSV="$REPO/comptes.csv"
CONFIG="$REPO/config"
SAUV="/sauvegardes/versions"

NB_OK=0
NB_KO=0
FICHIERS_TEST=()

if [[ -t 1 ]]; then
    VERT=$'\e[32m'; ROUGE=$'\e[31m'; NORMAL=$'\e[0m'
else
    VERT=""; ROUGE=""; NORMAL=""
fi

ok() {
    NB_OK=$((NB_OK + 1))
    echo "${VERT}[OK]${NORMAL} $1 $2"
}

ko() {
    NB_KO=$((NB_KO + 1))
    echo "${ROUGE}[KO]${NORMAL} $1 $2"
}

nettoyer() {
    local f
    for f in "${FICHIERS_TEST[@]}"; do
        rm -rf -- "$f"
    done
}
trap nettoyer EXIT

# ---------------------------------------------------------------------------
# Fonctions utilitaires
# ---------------------------------------------------------------------------

# Membres d'un groupe, y compris ceux dont c'est le groupe principal
membres() {
    local gid
    gid="$(getent group "$1" | cut -d: -f3)"
    [[ -z "$gid" ]] && return 0
    {
        getent group "$1" | cut -d: -f4 | tr ',' '\n'
        getent passwd | awk -F: -v gid="$gid" '$4 == gid { print $1 }'
    } | grep -v '^$' | sort -u
}

# Lignes utiles du CSV (sans en-tête, sans \r, sans commentaires)
lignes_csv() {
    tail -n +2 "$CSV" | tr -d '\r' | grep -v -e '^$' -e '^#'
}

# Premier compte du CSV dont le groupe principal est $1
compte_de() {
    lignes_csv | awk -F';' -v g="$1" '$3 == g { print $1; exit }'
}

# Lance une commande en tant qu'un autre utilisateur, sans afficher la sortie
en_tant_que() {
    local qui=$1
    shift
    sudo -u "$qui" -- "$@" >/dev/null 2>&1
}

# Valeur appliquée d'une directive sshd (sshd -T affiche tout en minuscules)
sshd_valeur() {
    sshd -T 2>/dev/null | awk -v cle="$1" '$1 == cle { $1 = ""; sub(/^ /, ""); print; exit }'
}

# Droits en octal et propriétaire:groupe d'un fichier
droits() { stat -c '%a' "$1" 2>/dev/null; }
proprio() { stat -c '%U:%G' "$1" 2>/dev/null; }

# Fichier modifiable seulement par root : root:root et pas de w pour g/o
root_seul() {
    [[ -f "$1" ]] || return 1
    [[ "$(stat -c '%U' "$1")" == "root" ]] || return 1
    local m
    m="$(droits "$1")"
    (( (8#$m & 8#022) == 0 ))
}

# Vrais systèmes de fichiers (on exclut /proc, /sys, /dev, /run...)
systemes_de_fichiers() {
    findmnt -rn -o TARGET -t ext2,ext3,ext4,xfs,btrfs,vfat
}

# Versions de sauvegarde, de la plus ancienne à la plus récente
versions_sauvegarde() {
    local v=()
    shopt -s nullglob
    v=("$SAUV"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9])
    shopt -u nullglob
    if (( ${#v[@]} > 0 )); then
        printf '%s\n' "${v[@]}"
    fi
}

# ---------------------------------------------------------------------------
# Comptes et droits
# ---------------------------------------------------------------------------

# C1 : chaque compte du CSV existe avec les bons groupes, pas de doublon,
# clés installées, particularité freelance
test_C1() {
    local login _nom gp gs groupe manque attendu
    if [[ ! -f "$CSV" ]]; then
        ko "C1" "comptes.csv introuvable dans $REPO"
        return
    fi

    while IFS=';' read -r login _nom gp gs; do
        if ! id "$login" >/dev/null 2>&1; then
            ko "C1" "compte $login absent"
            continue
        fi
        manque=""
        if [[ "$(id -gn "$login")" != "$gp" ]]; then
            manque="groupe principal $(id -gn "$login") au lieu de $gp"
        fi
        if [[ -n "$gs" ]]; then
            IFS=',' read -r -a liste <<< "$gs"
            for groupe in "${liste[@]}"; do
                if [[ " $(id -nG "$login") " != *" $groupe "* ]]; then
                    manque="$manque pas dans $groupe"
                fi
            done
        fi
        if [[ -z "$manque" ]]; then
            ok "C1" "compte $login présent, groupes ${gp}${gs:+,$gs}"
        else
            ko "C1" "compte $login : $manque"
        fi
    done < <(lignes_csv)

    # Doublons dans /etc/passwd et /etc/group
    if [[ -z "$(cut -d: -f1 /etc/passwd | sort | uniq -d)" && -z "$(cut -d: -f1 /etc/group | sort | uniq -d)" ]]; then
        ok "C1" "aucun compte ni groupe en double"
    else
        ko "C1" "comptes ou groupes en double dans /etc/passwd ou /etc/group"
    fi

    # Clés : authorized_keys identique à la clé du dépôt
    local home sans_cle="" mauvaise=""
    for login in $(lignes_csv | awk -F';' '$3 == "acces_ssh" || (","$4",") ~ /,acces_ssh,/ { print $1 }'); do
        home="$(getent passwd "$login" | cut -d: -f6)"
        if [[ ! -s "$CONFIG/cles/$login.pub" ]]; then
            sans_cle="$sans_cle $login"
        elif ! cmp -s <(tr -d '\r' < "$CONFIG/cles/$login.pub") "$home/.ssh/authorized_keys"; then
            mauvaise="$mauvaise $login"
        fi
    done
    if [[ -z "$sans_cle$mauvaise" ]]; then
        ok "C1" "clés publiques du dépôt installées pour tous les comptes de acces_ssh"
    else
        ko "C1" "clés : absentes du dépôt :${sans_cle:- aucune} / non installées :${mauvaise:- aucune}"
    fi

    # Particularité du contexte A : expiration des freelances
    local sans_date=""
    for login in $(membres freelance); do
        attendu="$(chage -l "$login" | awk -F': ' '/^Account expires/ { print $2 }')"
        if [[ -z "$attendu" || "$attendu" == "never" ]]; then
            sans_date="$sans_date $login"
        fi
    done
    if [[ -n "$(membres freelance)" && -z "$sans_date" ]]; then
        ok "C1" "comptes freelance avec date d'expiration ($(chage -l "$(membres freelance | head -n1)" | awk -F': ' '/^Account expires/ { print $2 }'))"
    else
        ko "C1" "freelance sans date d'expiration :${sans_date:- aucun membre}"
    fi
}

# C2 : droits sur /srv, testés à la place des utilisateurs
test_C2() {
    local dev design com free
    dev="$(compte_de dev)"; design="$(compte_de design)"
    com="$(compte_de commercial)"; free="$(compte_de freelance)"
    if [[ -z "$dev" || -z "$design" || -z "$com" || -z "$free" ]]; then
        ko "C2" "il manque un compte par groupe métier dans comptes.csv"
        return
    fi

    # peut_ecrire UTILISATEUR REPERTOIRE : crée puis supprime un fichier test
    peut_ecrire() {
        local f="$2/.verifier_$$_$1"
        FICHIERS_TEST+=("$f")
        en_tant_que "$1" touch "$f"
    }
    peut_lire() { en_tant_que "$1" ls "$2"; }

    # attendre TEST ATTENDU MESSAGE   (ATTENDU = oui ou non)
    attendre() {
        local resultat=non
        if eval "$1"; then resultat=oui; fi
        if [[ "$resultat" == "$2" ]]; then ok "C2" "$3"; else ko "C2" "$3 (obtenu : $resultat)"; fi
    }

    attendre "peut_ecrire $dev /srv/projets" oui "dev ($dev) peut écrire dans /srv/projets"
    attendre "peut_lire $design /srv/projets" oui "design ($design) peut lire /srv/projets"
    attendre "peut_ecrire $design /srv/projets" non "design ($design) ne peut pas écrire dans /srv/projets"
    attendre "peut_lire $com /srv/projets" non "commercial ($com) ne peut pas lire /srv/projets"
    attendre "peut_lire $free /srv/projets" non "freelance ($free) ne peut pas lister /srv/projets"
    attendre "peut_ecrire $free /srv/projets/externe" oui "freelance ($free) peut écrire dans /srv/projets/externe"
    attendre "peut_ecrire $design /srv/projets/externe" non "design ($design) ne peut pas écrire dans /srv/projets/externe"
    attendre "peut_ecrire $design /srv/maquettes" oui "design ($design) peut écrire dans /srv/maquettes"
    attendre "peut_lire $com /srv/maquettes" oui "commercial ($com) peut lire /srv/maquettes"
    attendre "peut_ecrire $dev /srv/maquettes" non "dev ($dev) ne peut pas écrire dans /srv/maquettes"
    attendre "peut_lire $free /srv/maquettes" non "freelance ($free) ne peut pas lire /srv/maquettes"
    attendre "peut_ecrire $com /srv/clients" oui "commercial ($com) peut écrire dans /srv/clients"
    attendre "peut_lire $dev /srv/clients" non "dev ($dev) ne peut pas lire /srv/clients"

    # ACL par défaut : un fichier créé plus tard hérite des droits
    local f="/srv/projets/.verifier_heritage_$$"
    FICHIERS_TEST+=("$f")
    if en_tant_que "$dev" sh -c "echo test > '$f'" \
       && en_tant_que "$design" cat "$f" \
       && ! en_tant_que "$com" cat "$f" \
       && ! en_tant_que "$design" sh -c "echo x >> '$f'"; then
        ok "C2" "ACL par défaut : un fichier créé par $dev est lisible par design, pas modifiable, invisible pour commercial"
    else
        ko "C2" "ACL par défaut : le fichier créé dans /srv/projets n'hérite pas des bons droits"
    fi

    local rep sans_defaut=""
    for rep in /srv/projets /srv/projets/externe /srv/maquettes /srv/clients; do
        if ! getfacl -cd "$rep" 2>/dev/null | grep -q '^group:'; then
            sans_defaut="$sans_defaut $rep"
        fi
    done
    if [[ -z "$sans_defaut" ]]; then
        ok "C2" "ACL par défaut présentes sur les 4 répertoires de /srv"
    else
        ko "C2" "ACL par défaut absentes sur :$sans_defaut"
    fi
}

# C3 : sudo pour admins, analyse_logs.sh seul pour support, rien pour les autres
test_C3() {
    local compte sortie admins_ko="" autres_ko="" nb=0
    local admins
    admins="$(membres admins | xargs)"

    for compte in $admins; do
        if ! sudo -l -U "$compte" 2>/dev/null | grep -q '(ALL : ALL) ALL'; then
            admins_ko="$admins_ko $compte"
        fi
    done
    if [[ -n "$admins" && -z "$admins_ko" ]]; then
        ok "C3" "les membres de admins ont sudo ($admins)"
    else
        ko "C3" "admins sans sudo :${admins_ko:- groupe admins vide}"
    fi

    # support : une seule règle, analyse_logs.sh
    sortie="$(sudo -l -U support 2>/dev/null | sed -n '/may run the following/,$p' | grep '^ *(')"
    if [[ "$(echo "$sortie" | grep -c .)" -eq 1 && "$sortie" == *"/usr/local/sbin/analyse_logs.sh" ]]; then
        ok "C3" "support n'a qu'une règle sudo : analyse_logs.sh en root"
    else
        ko "C3" "règles sudo de support inattendues : ${sortie:-aucune}"
    fi

    # Essai réel : support lance le script, mais pas autre chose
    local code
    sudo -u support sudo -n /usr/local/sbin/analyse_logs.sh -s 100000 >/dev/null 2>&1
    code=$?
    if [[ $code -eq 0 || $code -eq 2 ]] && ! en_tant_que support sudo -n /usr/bin/id; then
        ok "C3" "support lance analyse_logs.sh en root et se voit refuser sudo id"
    else
        ko "C3" "essai réel de sudo pour support incorrect (analyse_logs.sh code $code)"
    fi

    # Tous les autres comptes humains (UID >= 1000) : aucun droit sudo
    for compte in $(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 { print $1 }'); do
        [[ " $admins " == *" $compte "* || "$compte" == "support" ]] && continue
        nb=$((nb + 1))
        if ! sudo -l -U "$compte" 2>/dev/null | grep -q 'is not allowed to run sudo'; then
            autres_ko="$autres_ko $compte"
        fi
    done
    if [[ -z "$autres_ko" ]]; then
        ok "C3" "aucun autre compte n'a sudo ($nb comptes contrôlés, freelance compris)"
    else
        ko "C3" "comptes ayant sudo sans être admins :$autres_ko"
    fi

    if [[ -z "$(getent group sudo | cut -d: -f4)" ]]; then
        ok "C3" "groupe sudo vide"
    else
        ko "C3" "groupe sudo non vide : $(getent group sudo | cut -d: -f4)"
    fi

    local f fichiers_ok=1
    for f in "$CONFIG"/sudoers.d/*; do
        f="/etc/sudoers.d/$(basename "$f")"
        if [[ "$(droits "$f")" != "440" || "$(proprio "$f")" != "root:root" ]]; then
            fichiers_ok=0
        fi
    done
    if [[ $fichiers_ok -eq 1 ]] && visudo -c >/dev/null 2>&1; then
        ok "C3" "fichiers sudoers.d en 0440 root:root, visudo -c valide"
    else
        ko "C3" "fichiers sudoers.d absents, mauvais droits, ou visudo -c en erreur"
    fi

    if root_seul /usr/local/sbin/analyse_logs.sh; then
        ok "C3" "analyse_logs.sh appartient à root et n'est modifiable que par lui"
    else
        ko "C3" "analyse_logs.sh absent ou modifiable par un autre que root"
    fi
}

# C4 : root verrouillé, répertoires personnels privés
test_C4() {
    if [[ "$(passwd -S root | awk '{ print $2 }')" == "L" ]]; then
        ok "C4" "compte root verrouillé"
    else
        ko "C4" "compte root non verrouillé (passwd -S root)"
    fi

    local home ouverts=""
    for home in /home/*/; do
        [[ -d "$home" ]] || continue
        if (( (8#$(droits "$home") & 8#077) != 0 )); then
            ouverts="$ouverts $home($(droits "$home"))"
        fi
    done
    if [[ -z "$ouverts" ]]; then
        ok "C4" "répertoires personnels en 700, illisibles par les autres"
    else
        ko "C4" "répertoires personnels accessibles aux autres :$ouverts"
    fi

    local admin avec_mdp=""
    for admin in $(membres admins); do
        if [[ "$(passwd -S "$admin" | awk '{ print $2 }')" == "P" ]]; then
            avec_mdp="$avec_mdp $admin"
        fi
    done
    if [[ -n "$avec_mdp" ]]; then
        ok "C4" "administrateurs avec mot de passe pour sudo et la console de secours :$avec_mdp"
    else
        ko "C4" "aucun administrateur n'a de mot de passe : plus d'accès root possible"
    fi
}

# ---------------------------------------------------------------------------
# Accès SSH
# ---------------------------------------------------------------------------

test_S1() {
    if [[ "$(sshd_valeur passwordauthentication)" == "no" \
       && "$(sshd_valeur kbdinteractiveauthentication)" == "no" \
       && "$(sshd_valeur pubkeyauthentication)" == "yes" ]]; then
        ok "S1" "sshd -T : clé uniquement (password et keyboard-interactive à no)"
    else
        ko "S1" "sshd -T : authentification par mot de passe encore possible"
    fi

    # Essai réel en local : le serveur ne propose que publickey
    local sortie
    sortie="$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no \
        support@127.0.0.1 true 2>&1)"
    if [[ "$sortie" == *"Permission denied (publickey)"* ]]; then
        ok "S1" "essai réel : connexion sans clé refusée, seule la méthode publickey est proposée"
    else
        ko "S1" "essai réel de connexion sans clé : réponse inattendue ($(echo "$sortie" | tail -n1))"
    fi
}

test_S2() {
    if [[ "$(sshd_valeur permitrootlogin)" == "no" ]]; then
        ok "S2" "connexion root refusée (PermitRootLogin no)"
    else
        ko "S2" "PermitRootLogin vaut '$(sshd_valeur permitrootlogin)' (attendu : no)"
    fi
}

test_S3() {
    if [[ "$(sshd_valeur allowgroups)" == "acces_ssh" ]]; then
        ok "S3" "seul le groupe acces_ssh peut se connecter (AllowGroups)"
    else
        ko "S3" "AllowGroups vaut '$(sshd_valeur allowgroups)' (attendu : acces_ssh)"
    fi

    # acces_ssh contient exactement les comptes prévus par le CSV
    local prevus reels
    prevus="$(lignes_csv | awk -F';' '$3 == "acces_ssh" || (","$4",") ~ /,acces_ssh,/ { print $1 }' | sort | xargs)"
    reels="$(membres acces_ssh | xargs)"
    if [[ "$prevus" == "$reels" ]]; then
        ok "S3" "membres de acces_ssh conformes au CSV ($reels)"
    else
        ko "S3" "membres de acces_ssh : $reels (attendus : $prevus)"
    fi
}

test_S4() {
    local essais intervalle nombre
    essais="$(sshd_valeur maxauthtries)"
    intervalle="$(sshd_valeur clientaliveinterval)"
    nombre="$(sshd_valeur clientalivecountmax)"
    if [[ "$essais" =~ ^[0-9]+$ ]] && (( essais >= 1 && essais <= 4 )); then
        ok "S4" "MaxAuthTries = $essais (4 au plus)"
    else
        ko "S4" "MaxAuthTries = ${essais:-?} (attendu : 4 au plus)"
    fi
    if [[ "$intervalle" =~ ^[0-9]+$ && "$nombre" =~ ^[0-9]+$ ]] \
       && (( intervalle > 0 && nombre > 0 && intervalle * nombre <= 900 )); then
        ok "S4" "connexion muette coupée après $((intervalle * nombre)) s (ClientAlive, 900 s au plus)"
    else
        ko "S4" "ClientAliveInterval/CountMax = ${intervalle:-?}/${nombre:-?} (attendu : coupure en 900 s au plus)"
    fi
    if [[ -f /etc/profile.d/tmout.sh ]] && grep -Eq '^\s*TMOUT=([1-9][0-9]{0,2}|900)$' /etc/profile.d/tmout.sh; then
        ok "S4" "shell inactif fermé par TMOUT=$(grep -Eo 'TMOUT=[0-9]+' /etc/profile.d/tmout.sh | cut -d= -f2) s"
    else
        ko "S4" "TMOUT absent ou supérieur à 900 s dans /etc/profile.d/tmout.sh"
    fi
}

test_S5() {
    local conf=/etc/ssh/sshd_config.d/10-hardening.conf
    if cmp -s "$CONFIG/ssh/sshd_config.d/10-hardening.conf" "$conf"; then
        ok "S5" "configuration dans /etc/ssh/sshd_config.d/, identique au dépôt"
    else
        ko "S5" "$conf absent ou différent du dépôt"
    fi
    if grep -Eq '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config && sshd -t 2>/dev/null; then
        ok "S5" "sshd_config inclut sshd_config.d et sshd -t valide la configuration"
    else
        ko "S5" "Include manquant dans sshd_config ou sshd -t en erreur"
    fi
}

# ---------------------------------------------------------------------------
# Journaux et défense
# ---------------------------------------------------------------------------

test_J1() {
    if ! systemctl is-active --quiet fail2ban; then
        ko "J1" "fail2ban n'est pas actif"
        return
    fi
    if fail2ban-client status sshd >/dev/null 2>&1; then
        ok "J1" "fail2ban actif, jail sshd en place"
    else
        ko "J1" "jail sshd absente"
        return
    fi
    local essais duree
    essais="$(fail2ban-client get sshd maxretry 2>/dev/null)"
    duree="$(fail2ban-client get sshd bantime 2>/dev/null)"
    if [[ "$essais" =~ ^[0-9]+$ ]] && (( essais <= 10 )) && [[ "$duree" =~ ^[0-9]+$ ]] && (( duree > 0 )); then
        ok "J1" "bannissement après $essais échecs, pour $((duree / 60)) min"
    else
        ko "J1" "réglages de la jail inattendus (maxretry=$essais, bantime=$duree)"
    fi
    # fail2ban crée sa table nftables au premier bannissement seulement :
    # sans bannissement en cours, l'absence de f2b-table est normale
    local actions
    actions="$(fail2ban-client get sshd actions 2>/dev/null)"
    if [[ "$actions" != *nftables* ]]; then
        ko "J1" "la jail sshd ne bannit pas via nftables (actions : $(echo "$actions" | tail -n1))"
    elif nft list tables 2>/dev/null | grep -q 'f2b-table'; then
        ok "J1" "bannissement via nftables, table f2b-table présente dans le pare-feu"
    else
        ok "J1" "bannissement via nftables (table f2b-table créée au premier bannissement)"
    fi
}

test_J2() {
    local chaine
    chaine="$(nft list chain inet filtre entree 2>/dev/null)"
    if [[ "$chaine" == *"hook input"*"policy drop;"* ]]; then
        ok "J2" "politique par défaut du pare-feu en entrée : drop"
    else
        ko "J2" "politique par défaut du pare-feu : $(echo "$chaine" | grep -o 'policy [a-z]*' || echo 'table absente') (attendu : drop)"
    fi
    if echo "$chaine" | grep -q 'ct state established,related accept' \
       && echo "$chaine" | grep -q 'tcp dport 22.*accept'; then
        ok "J2" "seuls SSH et les connexions établies sont acceptés"
    else
        ko "J2" "règle SSH ou connexions établies absente"
    fi
    # Toute autre ouverture de port en entrée serait suspecte
    local autres
    autres="$(echo "$chaine" | grep -E 'dport' | grep -v 'dport 22 ')"
    if [[ -z "$autres" ]]; then
        ok "J2" "aucun autre port ouvert dans le pare-feu"
    else
        ko "J2" "règles supplémentaires : $autres"
    fi
    if systemctl is-enabled --quiet nftables && cmp -s "$CONFIG/nftables.conf" /etc/nftables.conf; then
        ok "J2" "règles dans /etc/nftables.conf, chargées au démarrage (service nftables activé)"
    else
        ko "J2" "service nftables non activé ou /etc/nftables.conf différent du dépôt"
    fi
}

test_J3() {
    local valeur
    valeur="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -E '^\s*Storage=' | tail -n1 | cut -d= -f2)"
    if [[ "$valeur" == "persistent" ]]; then
        ok "J3" "journal persistant (Storage=persistent)"
    else
        ko "J3" "Storage vaut '${valeur:-auto}' (attendu : persistent)"
    fi
    if compgen -G "/var/log/journal/*/system.journal" >/dev/null; then
        ok "J3" "journal écrit sur disque dans /var/log/journal ($(journalctl --list-boots 2>/dev/null | grep -c .) démarrage(s) conservé(s))"
    else
        ko "J3" "aucun journal dans /var/log/journal"
    fi
}

test_J4() {
    local script=/usr/local/sbin/analyse_logs.sh
    local exemple="$REPO/tests/ssh_exemple_debian13.log"
    if ! root_seul "$script" || [[ ! -x "$script" ]]; then
        ko "J4" "$script absent, non exécutable ou modifiable par un autre que root"
        return
    fi
    if [[ ! -f "$exemple" ]]; then
        ko "J4" "fichier de test $exemple absent"
        return
    fi
    # Le fichier d'exemple contient 10 échecs venant de 203.0.113.45
    local code_alerte code_calme rapport
    rapport="$("$script" -f "$exemple" -s 10 2>&1)"; code_alerte=$?
    "$script" -f "$exemple" -s 50 >/dev/null 2>&1; code_calme=$?
    if [[ $code_alerte -eq 2 && $code_calme -eq 0 ]]; then
        ok "J4" "analyse_logs.sh renvoie 2 si le seuil est atteint, 0 sinon"
    else
        ko "J4" "codes de sortie inattendus (seuil 10 : $code_alerte, seuil 50 : $code_calme)"
    fi
    if [[ "$rapport" == *"203.0.113.45"* && "$rapport" == *"root"* && "$rapport" == *"Connexions réussies"* ]]; then
        ok "J4" "rapport complet : échecs par IP, comptes visés, connexions réussies"
    else
        ko "J4" "rapport incomplet sur le fichier d'exemple"
    fi
    "$script" -s 0 >/dev/null 2>&1
    if [[ $? -eq 1 ]]; then
        ok "J4" "seuil invalide refusé (code 1)"
    else
        ko "J4" "un seuil invalide n'est pas refusé"
    fi
}

# ---------------------------------------------------------------------------
# Sauvegarde
# ---------------------------------------------------------------------------

test_B1() {
    if findmnt -n /sauvegardes >/dev/null 2>&1 && grep -Eq '^UUID=\S+\s+/sauvegardes\s' /etc/fstab; then
        ok "B1" "second disque monté sur /sauvegardes, montage permanent dans /etc/fstab"
    else
        ko "B1" "/sauvegardes non monté ou absent de /etc/fstab"
        return
    fi
    if root_seul /usr/local/sbin/sauvegarde.sh && root_seul "$REPO/sauvegarde.sh"; then
        ok "B1" "sauvegarde.sh appartient à root et n'est modifiable que par lui"
    else
        ko "B1" "sauvegarde.sh absent ou modifiable par un autre que root"
    fi

    local versions nb derniere avant
    mapfile -t versions < <(versions_sauvegarde)
    nb=${#versions[@]}
    if (( nb >= 1 && nb <= 7 )); then
        ok "B1" "$nb version(s) datée(s) dans $SAUV (7 au maximum, les plus anciennes supprimées)"
    elif (( nb > 7 )); then
        ko "B1" "$nb versions : la rotation ne supprime pas les plus anciennes"
    else
        ko "B1" "aucune version de sauvegarde (lancer sauvegarde.sh)"
        return
    fi

    derniere="${versions[-1]}"
    if (( nb >= 2 )); then
        avant="${versions[-2]}"
        if [[ "$(stat -c %i "$derniere/etc/hostname" 2>/dev/null)" == "$(stat -c %i "$avant/etc/hostname" 2>/dev/null)" ]]; then
            ok "B1" "incrémentale : un fichier inchangé est un lien dur vers la version précédente, pas une copie"
        else
            ko "B1" "les fichiers inchangés sont recopiés à chaque version (--link-dest ?)"
        fi
    else
        ko "B1" "une seule version : relancer sauvegarde.sh pour vérifier l'incrémental"
    fi

    if getfacl -c "$derniere/srv/projets" 2>/dev/null | grep -q '^group:dev:rwx' \
       && [[ "$(proprio "$derniere/etc/shadow")" == "$(proprio /etc/shadow)" ]]; then
        ok "B1" "droits, propriétaires et ACL conservés dans la sauvegarde"
    else
        ko "B1" "ACL ou propriétaires perdus dans la sauvegarde"
    fi
}

test_B2() {
    if systemctl is-enabled --quiet sauvegarde.timer && systemctl is-active --quiet sauvegarde.timer; then
        ok "B2" "sauvegarde planifiée (sauvegarde.timer actif)"
    else
        ko "B2" "sauvegarde.timer non activé ou inactif"
    fi
    if [[ -s /var/log/sauvegarde.log ]] && grep -q 'fin : version' /var/log/sauvegarde.log; then
        ok "B2" "exécutions journalisées ($(grep -c 'fin : version' /var/log/sauvegarde.log) dans /var/log/sauvegarde.log)"
    else
        ko "B2" "aucune exécution réussie dans /var/log/sauvegarde.log"
    fi
}

test_B3() {
    local admin metier
    admin="$(membres admins | head -n1)"
    metier="$(compte_de dev)"
    if [[ "$(droits /sauvegardes)" == "750" && "$(proprio /sauvegardes)" == "root:admins" ]]; then
        ok "B3" "/sauvegardes en 750 root:admins"
    else
        ko "B3" "/sauvegardes en $(droits /sauvegardes) $(proprio /sauvegardes) (attendu : 750 root:admins)"
    fi
    if en_tant_que "$admin" ls /sauvegardes && ! en_tant_que "$metier" ls /sauvegardes \
       && ! en_tant_que support ls /sauvegardes; then
        ok "B3" "$admin (admin) accède aux sauvegardes, $metier et support non"
    else
        ko "B3" "accès aux sauvegardes incorrect pour $admin, $metier ou support"
    fi
}

test_B4() {
    local versions ancienne tmp
    mapfile -t versions < <(versions_sauvegarde)
    if (( ${#versions[@]} == 0 )); then
        ko "B4" "pas de version à restaurer"
        return
    fi
    ancienne="${versions[0]}"
    tmp="$(mktemp -d)"
    FICHIERS_TEST+=("$tmp")
    # Restauration vers un dossier de test, jamais sur l'original
    if rsync -aAX "$ancienne/srv/" "$tmp/srv/" >/dev/null 2>&1 \
       && rsync -aAX "$ancienne/etc/hostname" "$tmp/" >/dev/null 2>&1 \
       && cmp -s "$tmp/hostname" /etc/hostname \
       && getfacl -c "$tmp/srv/projets" 2>/dev/null | grep -q '^group:dev:rwx'; then
        ok "B4" "restauration testée depuis $(basename "$ancienne") vers un dossier temporaire, ACL comprises"
    else
        ko "B4" "la restauration depuis $(basename "$ancienne") échoue"
    fi
    if grep -qi 'restauration' "$REPO/DOSSIER.md" 2>/dev/null; then
        ok "B4" "procédure de restauration documentée dans DOSSIER.md"
    else
        ko "B4" "procédure de restauration absente de DOSSIER.md"
    fi
}

# ---------------------------------------------------------------------------
# Système
# ---------------------------------------------------------------------------

test_D1() {
    if [[ "$(dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null)" == "install ok installed" ]] \
       && apt-config dump | grep -q '^APT::Periodic::Unattended-Upgrade "1";'; then
        ok "D1" "unattended-upgrades installé et activé"
    else
        ko "D1" "unattended-upgrades absent ou désactivé"
    fi
    if grep -Eq '^\s*"origin=Debian,codename=\$\{distro_codename\}-security' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null \
       && systemctl is-enabled --quiet apt-daily-upgrade.timer; then
        ok "D1" "mises à jour Debian-Security autorisées, apt-daily-upgrade.timer activé"
    else
        ko "D1" "origine Debian-Security non autorisée ou timer apt-daily-upgrade désactivé"
    fi
}

test_D2() {
    # On garde les écoutes hors loopback qui ne sont ni sshd ni le client DHCP
    local suspects
    suspects="$(ss -Htulpn 2>/dev/null | awk '
        {
            adresse = $5
            if (adresse ~ /^127\./ || adresse ~ /^\[::1\]/ || adresse ~ /^::1/) next
            if ($7 ~ /"sshd"/) next
            if ($1 == "udp" && adresse ~ /:(68|546)$/) next
            print $1 " " $5 " " $7
        }')"
    if [[ -z "$suspects" ]]; then
        ok "D2" "seul SSH écoute sur le réseau (ss -tulpn)"
    else
        ko "D2" "autres services joignables : $(echo "$suspects" | tr '\n' ';')"
    fi
}

test_D3() {
    local fs ecrivables suid inattendus
    fs="$(systemes_de_fichiers | tr '\n' ' ')"
    # -xdev : on ne descend pas dans /proc, /sys ni les autres montages virtuels
    # -type f / -type d : les liens symboliques (toujours en 777) sont ignorés
    # shellcheck disable=SC2086
    ecrivables="$(find $fs -xdev \( -path /tmp -o -path /var/tmp -o -path /dev/shm \) -prune -o \
        \( -type f -perm -0002 -o -type d -perm -0002 ! -perm -1000 \) -print 2>/dev/null)"
    if [[ -z "$ecrivables" ]]; then
        ok "D3" "aucun fichier modifiable par tous hors répertoires temporaires"
    else
        ko "D3" "modifiables par tous : $(echo "$ecrivables" | head -n 5 | tr '\n' ' ')"
    fi

    # shellcheck disable=SC2086
    suid="$(find $fs -xdev -type f -perm -4000 2>/dev/null | sort)"
    inattendus="$(comm -23 <(echo "$suid") <(grep -v '^#' "$CONFIG/suid_attendus.txt" | sort))"
    if [[ -z "$inattendus" ]]; then
        ok "D3" "$(echo "$suid" | grep -c .) fichiers SUID, tous listés et expliqués (config/suid_attendus.txt)"
    else
        ko "D3" "fichiers SUID non prévus : $(echo "$inattendus" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------

main() {
    if [[ "${1:-}" == "-h" ]]; then
        echo "Usage : sudo $0"
        exit 0
    fi
    if [[ $EUID -ne 0 ]]; then
        echo "Erreur : ce script doit être lancé en root (sudo $0)" >&2
        exit 1
    fi

    echo "=== Vérification du serveur Pixelia : $(hostname), $(date '+%F %T') ==="
    test_C1; test_C2; test_C3; test_C4
    test_S1; test_S2; test_S3; test_S4; test_S5
    test_J1; test_J2; test_J3; test_J4
    test_B1; test_B2; test_B3; test_B4
    test_D1; test_D2; test_D3

    echo "--- $NB_OK / $((NB_OK + NB_KO)) tests réussis"
    if [[ $NB_KO -eq 0 ]]; then
        exit 0
    fi
    exit 1
}

main "$@"
