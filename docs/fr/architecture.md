# Fonctionnalités du produit :

## Extension pour site web/système
Le site web du developpeur doit avoir un endpoint qui attend cette requête quand un paiement est fait.

## Application mobile

![plant-uml-libre-paie](https://user-images.githubusercontent.com/4486484/218331700-e40ab959-0b6f-412d-99e3-bb50187c74b5.png)

### Couche d'interface utilisateur (UI)
La couche d'interface utilisateur est responsable de fournir à l'utilisateur une interface simple et intuitive pour effectuer des opérations de suivi de paiements et de vérification de solde. Cette couche communique avec la couche de logique métier pour récupérer les informations nécessaires à l'affichage.

### Couche de logique métier
La couche de logique métier est responsable de la gestion des opérations liées à la logique métier de l'application, telles que le suivi des paiements, la mise à jour du solde de l'utilisateur et la gestion des erreurs de réseau. 
Elle comporte un composant "Balance Updater" qui se charge de mettre à jour le solde de l'utilisateur. 
Elle comporte également un composant "Retry Manager" qui se charge de gérer les tentatives de mise à jour en cas d'erreur. 
Cette couche communique avec la couche d'accès aux données pour récupérer et mettre à jour les informations relatives aux paiements. 
Elle utilise également un composant "UI Store" pour stocker les informations nécessaires à l'affichage.

### Couche d'accès aux données
La couche d'accès aux données est responsable de l'accès et du stockage des données de paiement de l'utilisateur. Elle comporte un composant "Data Encrypter" qui se charge de crypter les données avant de les stocker dans la base de données SQLite.

### Couche de réseau
La couche de réseau est responsable de l'envoi et de la réception des données avec l'API du site web du développeur. Elle comporte un composant "API Client" qui gère les communications avec l'API du site web.

### Composant "SMS Listener"
Le composant "SMS Parser" est responsable d'écouter les messages SMS entrants et d'extraire les détails de paiement. 
Il communique avec le composant "Balance Updater" pour mettre à jour le solde de l'utilisateur.

# Consideration supplementaire
## Securité
En plus de l'utilisation du protocole HTTPS pour la communication sécurisée, d'autres mesures de sécurité ont été prises pour garantir la sécurité des données et des transactions de l'application mobile.

- API Key : Tout les appels de l’application vers le serveur seront authentifiés.
- Cryptage des données : Les données de paiement de l'utilisateur sont cryptées avant d'être stockées dans la base de données SQLite. Ce cryptage garantit que les données sensibles ne peuvent pas être lues ou modifiées par des tiers non autorisés.
- Authentification de l'utilisateur : L'application mobile utilise une méthode d'authentification forte pour s'assurer que seul l'utilisateur autorisé peut accéder à ses données de paiement. Cela peut inclure la saisie d'un mot de passe ou l'utilisation d'une empreinte digitale pour l'authentification.
- Gestion des erreurs de réseau : La couche de logique métier comporte un composant "Retry Manager" qui gère les tentatives de mise à jour en cas d'erreur de réseau. Cela garantit que les transactions sont effectuées de manière fiable même en cas d'interruptions temporaires du réseau.
# Documentation historique — ne pas utiliser comme specification actuelle

> **Avertissement :** ce document decrit des intentions historiques. L'authentification par cle API, le chiffrement local, les retries, la synchronisation et les ecrans de paiement ne sont pas des fonctionnalites implementees ou pretes pour la production dans ce depot. La specification canonique planifiee est dans `../architecture.md`, `../reliability.md`, `../interoperability.md` et `../openapi.yaml`.
