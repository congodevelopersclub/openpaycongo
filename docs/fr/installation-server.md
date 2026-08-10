# Installation du serveur

Le binaire `walletd` fonctionne avec SQLite par défaut. Exemple d'exécution via Docker :

```bash
docker run -p 8080:8080 -v $(pwd)/data:/data ghcr.io/example/walletd:1.0
```

L'API expose des routes `/api/credits`, `/wallet/{phone}/debit` ainsi que la gestion des parsers (`/parsers`).
# Installation historique: avertissement

> **Avertissement :** l'image `ghcr.io/example/walletd:1.0` ci-dessous est un exemple fictif et il n'existe pas actuellement d'image Docker publiee, de serveur de production, ni de contrat `/v1/sync/*` implemente. Consulter `../openapi.yaml` et `../prd-backend.md` pour la specification planifiee.
