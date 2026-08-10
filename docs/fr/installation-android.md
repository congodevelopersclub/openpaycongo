# Installation Android

Compilez l'application via `flutter build apk` ou récupérez l'APK précompilé.
Au premier lancement l'app demande l'authentification biométrique puis ouvre l'écran d'accueil.

Via le menu "Config" vous pouvez saisir le domaine de votre serveur, la clé API et le secret HMAC.
Les regex de parsing SMS sont configurables depuis la section "Parsers" et synchronisées avec le serveur.
# Installation Android historique: avertissement

> **Avertissement :** ce guide ne constitue pas une procedure de distribution. L'APK actuel n'est pas signe pour une diffusion de production et l'authentification, le stockage securise, le chiffrement, la synchronisation et la recuperation decrits ici ne sont pas implementes. Voir `../prd-mobile.md` et `../../android-client/README.md`.
