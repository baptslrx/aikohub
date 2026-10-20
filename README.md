# AikoHub

Toute la suite Aiko dans une appli. Tu entres ta clé, AikoHub débloque les outils de ton profil (**Design**, **Monteur**, **Dev** ou **Tout**) ; tu coches ceux que tu veux, il les installe, les ouvre et les met à jour.

## Licences

- Clés `AIKO-XXXX-XXXX-XXXX` créées par l'administrateur (mode admin, protégé par mot de passe)
- Une clé = un profil, 2 Mac maximum (« Désactiver ce Mac » libère la place)
- Vérification en ligne à l'activation, puis 30 jours sans internet entre deux vérifications
- Licences signées (Ed25519) : impossibles à fabriquer ou modifier sans le serveur
- Mode admin : créer une clé (nom, profil, nombre de Mac, date de fin), copier le message à envoyer, libérer les Mac, désactiver, supprimer

## Serveur de licences (Cloudflare Workers, gratuit)

Le dossier `server/` est mis en ligne par le workflow « Mettre en ligne le serveur de licences », avec ces secrets du dépôt :

| Secret | À quoi il sert |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Mettre le serveur en ligne sur ton compte Cloudflare |
| `CLOUDFLARE_ACCOUNT_ID` | Identifiant de ton compte Cloudflare |
| `AIKO_ADMIN_PASSWORD` | Ton mot de passe du mode admin |
| `AIKO_GITHUB_TOKEN` | (facultatif) Jeton GitHub en lecture seule pour que les outils se téléchargent depuis AikoHub |

## Installation (Mac)

Double-clic sur `macos/Installer AikoHub.command`.
