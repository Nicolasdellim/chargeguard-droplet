# Composants tiers

## batt

- Projet : https://github.com/charlie0129/batt
- Version embarquée : **v0.8.0**
- Distribution : `batt-v0.8.0-darwin-arm64.tar.gz`, release officielle amont.
- Licence : GNU GPL v2 ; copie dans `Assets/Engine/LICENSE-batt`.
- Code source correspondant : `Assets/Engine/batt-v0.8.0-source.tar`, archive du tag `v0.8.0`. L’archive contient le module Go et ses fichiers de dépendances ; elle ne contient pas un cache des dépendances tierces.
- Les dépendances tierces restent soumises à leurs propres licences, disponibles auprès des modules indiqués dans `go.mod` et `go.sum`.
- SHA-256 de l’archive binaire téléchargée : `7c63db14e1063bc087c505a924ac614d7ed3d72dbbbc1f2f6d2e38b682c10f58`, vérifié contre la liste publiée par l’amont.

Charge Guard ne modifie pas le binaire batt embarqué. Son installateur isole le service dans des chemins propres à Charge Guard.

## DroppyKit

- SDK : https://gitlab.com/droppyformac1/droppykit
- Version épinglée : **1.20.1**
- Révision : `3d728a7981975714057650f80639c1e27d512fdb`

Le SDK est une dépendance SwiftPM, récupérée à la compilation. Le bundle de distribution lie le framework fourni par l’hôte et n’embarque pas une seconde copie de ce framework. Consultez les conditions de licence du SDK et de Droppy auprès de leur éditeur.

## Icône

L’icône propre au projet a été générée avec l’outil intégré imagegen. Le prompt est fourni dans `docs/icon-prompt.txt`. Les noms et marques de tiers appartiennent à leurs titulaires respectifs.
