# Installation du serveur

Le serveur canonique est l'application Laravel native dans `server/`.

L'image de production, Compose PostgreSQL, le worker de file, le planificateur,
les sauvegardes et la restauration restent des travaux distincts. Aucun binaire
historique, image publiee, ni serveur de production n'est fourni actuellement.

Pour verifier le point d'entree Laravel avec Docker depuis la racine du depot :

```bash
docker build --target test -f server/Dockerfile .
```

Consulter `../openapi.yaml` et `../prd-backend.md` pour les contrats planifies.
