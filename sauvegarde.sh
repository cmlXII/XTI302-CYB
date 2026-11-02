#!/bin/bash
# sauvegarde.sh
# Projet XTI302-CYB, exigences B1 et B2
#
# Sauvegarde /etc et /srv sur le second disque, monté sur /sauvegardes.
# Chaque exécution crée une version datée : /sauvegardes/versions/AAAA-MM-JJ_HHMMSS
#
# Sauvegarde incrémentale avec rsync --link-dest : un fichier qui n'a pas
# changé depuis la version précédente n'est pas recopié, rsync crée un lien
# dur vers la copie existante. Chaque version paraît complète (on peut y
# restaurer n'importe quel fichier) mais seuls les fichiers modifiés prennent
# de la place.
# -A et -X conservent les ACL et les attributs étendus, -H les liens durs,
# --numeric-ids garde les UID/GID tels quels.
#
# Les GARDER dernières versions sont conservées, les plus anciennes supprimées.
# Chaque exécution est journalisée dans /var/log/sauvegarde.log (et dans le
# journal systemd quand le script est lancé par sauvegarde.timer).
#
# Usage : sudo ./sauvegarde.sh [-n versions_a_garder] [-h]

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 027

POINT_MONTAGE=/sauvegardes
DEST="$POINT_MONTAGE/versions"
SOURCES=(/etc /srv)
GARDER=7
JOURNAL=/var/log/sauvegarde.log
VERROU=/run/sauvegarde.lock

usage() {
    echo "Usage : $(basename "$0") [-n versions_a_garder] [-h]"
    echo "  -n N  nombre de versions conservées, au moins 7 (défaut : $GARDER)"
}

log() {
    local ligne
    ligne="$(date '+%F %T') [sauvegarde] $*"
    echo "$ligne"
    echo "$ligne" >> "$JOURNAL"
}

erreur() {
    echo "Erreur : $*" >&2
    if [[ -w "$(dirname "$JOURNAL")" ]]; then
        echo "$(date '+%F %T') [sauvegarde] ERREUR : $*" >> "$JOURNAL"
    fi
    exit 1
}

lire_options() {
    local opt
    while getopts ":n:h" opt; do
        case "$opt" in
            n) GARDER=$OPTARG ;;
            h) usage; exit 0 ;;
            :) erreur "l'option -$OPTARG attend une valeur" ;;
            *) erreur "option inconnue : -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))
    if [[ $# -gt 0 ]]; then
        erreur "argument en trop : $1"
    fi
    if [[ ! "$GARDER" =~ ^[0-9]+$ ]] || (( GARDER < 7 )); then
        erreur "il faut garder au moins 7 versions"
    fi
}

verifier_prerequis() {
    if [[ $EUID -ne 0 ]]; then
        erreur "ce script doit être lancé en root"
    fi
    if ! command -v rsync >/dev/null 2>&1; then
        erreur "rsync n'est pas installé"
    fi
    # Si le disque n'est pas monté, /sauvegardes est un simple dossier du
    # disque système : on refuse plutôt que de remplir le mauvais disque.
    if ! mountpoint -q "$POINT_MONTAGE"; then
        erreur "$POINT_MONTAGE n'est pas monté, sauvegarde annulée"
    fi
}

# Affiche le chemin de la version la plus récente (vide s'il n'y en a pas).
# Le motif AAAA-MM-JJ_HHMMSS se trie dans l'ordre chronologique.
derniere_version() {
    local versions=()
    shopt -s nullglob
    versions=("$DEST"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9])
    shopt -u nullglob
    if (( ${#versions[@]} > 0 )); then
        echo "${versions[-1]}"
    fi
}

sauvegarder() {
    local horodatage cible en_cours precedente code stats
    horodatage="$(date +%Y-%m-%d_%H%M%S)"
    cible="$DEST/$horodatage"
    en_cours="$cible.en_cours"
    precedente="$(derniere_version)"

    if [[ -e "$cible" ]]; then
        erreur "la version $horodatage existe déjà"
    fi

    install -d -o root -g admins -m 0750 "$DEST"
    # Restes d'une exécution interrompue : jamais utilisés comme base
    rm -rf -- "$DEST"/*.en_cours

    local options=(-aAXH --numeric-ids --stats)
    if [[ -n "$precedente" ]]; then
        options+=("--link-dest=$precedente")
        log "début : ${SOURCES[*]} vers $horodatage (incrémentale, base $(basename "$precedente"))"
    else
        log "début : ${SOURCES[*]} vers $horodatage (première sauvegarde, complète)"
    fi

    # On écrit dans un dossier .en_cours, renommé seulement si rsync réussit :
    # une sauvegarde ratée ne servira jamais de base à la suivante.
    stats="$(mktemp)"
    set +e
    rsync "${options[@]}" "${SOURCES[@]}" "$en_cours/" > "$stats" 2>&1
    code=$?
    set -e

    # 24 = des fichiers ont disparu pendant la copie (fichiers temporaires) :
    # la sauvegarde reste utilisable
    if [[ $code -ne 0 && $code -ne 24 ]]; then
        tail -n 5 "$stats" >&2
        rm -f "$stats"
        rm -rf -- "$en_cours"
        erreur "rsync a échoué (code $code), version $horodatage abandonnée"
    fi

    mv -- "$en_cours" "$cible"
    ln -sfn "$horodatage" "$DEST/derniere"

    local copies total
    copies="$(awk -F': ' '/^Number of regular files transferred/ {gsub(/,/, "", $2); print $2}' "$stats")"
    total="$(awk -F': ' '/^Number of files:/ {split($2, a, " "); gsub(/,/, "", a[1]); print a[1]}' "$stats")"
    rm -f "$stats"
    if [[ -n "$precedente" ]]; then
        log "fin : version $horodatage créée, ${copies:-?} fichier(s) copié(s) sur ${total:-?}, les autres sont des liens vers la version précédente"
    else
        log "fin : version $horodatage créée, ${copies:-?} fichier(s) copié(s)"
    fi
}

rotation() {
    local versions=() nb a_supprimer v
    shopt -s nullglob
    versions=("$DEST"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9])
    shopt -u nullglob
    nb=${#versions[@]}
    if (( nb > GARDER )); then
        a_supprimer=$(( nb - GARDER ))
        for v in "${versions[@]:0:a_supprimer}"; do
            rm -rf -- "$v"
            log "rotation : ancienne version $(basename "$v") supprimée"
        done
    fi
    log "versions conservées : $(( nb > GARDER ? GARDER : nb )) (maximum $GARDER)"
}

main() {
    lire_options "$@"
    verifier_prerequis

    # Une seule sauvegarde à la fois (timer et lancement manuel simultanés)
    exec 9> "$VERROU"
    if ! flock -n 9; then
        erreur "une sauvegarde est déjà en cours"
    fi

    sauvegarder
    rotation
}

main "$@"
