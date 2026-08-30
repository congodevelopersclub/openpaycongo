# Installation du serveur

Le serveur canonique est l'application Laravel native dans `server/`. La pile
Docker Compose PostgreSQL, le worker de file, le planificateur et les procedures
de sauvegarde/restauration sont documentes dans
[`../operations.md`](../operations.md). Cette pile n'autorise pas le traitement
de donnees de paiement, SMS, identifiants ou enrollement reels tant que les
limites de securite et de protocole du depot restent incompletes.

Pour verifier le point d'entree Laravel avec Docker depuis la racine du depot :

```bash
docker build --target test -f server/Dockerfile .
```

Consulter `../openapi.yaml` et `../prd-backend.md` pour les contrats planifies.
