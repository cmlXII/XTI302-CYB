# S4 : un shell interactif inactif depuis 10 minutes est fermé.
# readonly empêche un utilisateur de désactiver la variable dans sa session.
# Le test évite l'erreur "readonly variable" si le fichier est lu deux fois.
if ! readonly -p | grep -q ' TMOUT='; then
    TMOUT=600
    readonly TMOUT
    export TMOUT
fi
