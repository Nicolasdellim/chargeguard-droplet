# Développer et contribuer

## Préparer l’environnement

Il faut macOS, les outils Xcode avec Swift 6.2 ou plus récent, ainsi qu’un checkout du SDK DroppyKit. Le package épingle la version 1.20.1.

```sh
git clone https://github.com/Nicolasdellim/chargeguard-droplet.git
git clone --branch 1.20.1 --depth 1 https://gitlab.com/droppyformac1/droppykit.git
export PATH="$PWD/droppykit/Scripts:$PATH"
cd chargeguard-droplet
```

## Prévisualiser et tester

```sh
swift test
droppykit run
```

Le harness utilise des données de démonstration. Il permet de vérifier les vues sans installer le moteur ni changer la charge du Mac.

Pour produire les captures et le rapport :

```sh
droppykit run -- --shots ./shots --report ./shots/report.json
```

Le rapport doit avoir une liste `problems` vide, une activation sans erreur et la valeur `provided` pour chaque surface déclarée. Regardez les captures, y compris la composition solo et la composition étroite.

## Construire le dropplet

```sh
droppykit build
droppykit validate --no-submission
codesign --force --sign - .build/Chargeguard.droplet
codesign --verify --strict .build/Chargeguard.droplet
```

**N’utilisez pas un simple `swift build` pour fabriquer le bundle à distribuer.** Le script DroppyKit lie le framework résilient fourni par l’hôte. Un second exemplaire du SDK lié statiquement au dropplet peut compiler et échouer au chargement dans Droppy.

`--no-submission` valide le build local. Cette distribution utilise une icône personnalisée demandée pour le projet ; elle ne constitue pas une soumission au Store officiel Droppy. Une soumission devra respecter les règles de ce Store, notamment celles de l’iconographie.

Essayez ensuite `.build/Chargeguard.droplet` dans [Droppy Playground](https://getdroppy.app/docs/droppykit/playground) et confirmez son chargement effectif. L’installation dans Droppy peut demander votre accord pour l’exécution de code local.

## Moteur embarqué

Le moteur fourni est la release officielle batt **v0.8.0**, arm64. Son code source correspondant est dans `Assets/Engine/batt-v0.8.0-source.tar`, avec les fichiers `go.mod` et `go.sum` de l’amont. Pour reconstruire le moteur, extrayez l’archive dans un dossier séparé et suivez son README ; Go, les outils C et les dépendances décrites par le module sont nécessaires.

Ne remplacez pas le moteur sans vérifier les commandes utilisées, le schéma JSON, les modes legacy/firmware, les conditions de licence et les sommes des téléchargements. Ne lancez pas les scripts administrateur pour un simple test d’interface.

## Signaler un problème

Indiquez :

- Le modèle de Mac et la version de macOS, sans numéro de série.
- Les versions de Droppy et de Charge Guard.
- Les seuils sélectionnés, le statut affiché, et si le chargeur était branché.
- Les étapes pour reproduire et les messages d’erreur pertinents.

Les journaux du moteur sont dans `/Library/Application Support/ChargeGuard/engine.log`. Relisez les extraits avant de les publier. Un retour sur une autre génération Apple Silicon est utile, mais ne vaut pas validation de tous les modèles ou firmwares.

## Proposer un changement

Ouvrez une issue ou une pull request en expliquant le problème, le comportement attendu et les vérifications effectuées. Séparez les changements d’interface des changements de contrôle matériel lorsque cela rend la revue plus claire. Toute modification de la politique de charge doit conserver des tests des seuils et préciser ses effets sur le service existant.
