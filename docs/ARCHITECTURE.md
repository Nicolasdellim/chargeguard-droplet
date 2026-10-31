# Architecture de Charge Guard

## Composants

| Élément | Responsabilité |
| --- | --- |
| `Sources/Chargeguard/ChargeguardDroplet.swift` | Modèle observable, cycle de vie DroppyKit, client asynchrone du moteur, widget, réglages et activité compacte |
| `Sources/Chargeguard/ChargePolicy.swift` | Validation de la plage et conversion du seuil inférieur legacy |
| `Sources/ChargeguardHarness/` | Application de prévisualisation utilisant DroppyKitHarness |
| `Tests/ChargeguardTests/` | Tests de la politique, du protocole et des arguments de commande |
| `Assets/Engine/batt` | Client et daemon batt v0.8.0 pour Apple Silicon |
| `Assets/Engine/setup.sh` | Installation et désinstallation du service système |
| `Chargeguard.icon/` | Document Icon Composer et image de l’icône locale |
| `droplet.json` | Identité, version, compatibilité, surfaces et capacité `shelf-write` |

## Deux états pour les seuils

`lower` et `upper` représentent la sélection dans le formulaire. `appliedLower` et `appliedUpper` représentent les seuils affichés comme appliqués. Déplacer les curseurs n’écrit pas dans le moteur. **Appliquer** déclenche les commandes, puis relit le statut pour confirmer les deux valeurs. Les préférences de Droppy sont enregistrées après cette confirmation.

Les curseurs de la notch déplacent automatiquement l’autre borne si nécessaire pour conserver un écart minimal de deux points. Les champs des réglages peuvent sélectionner une plage invalide ; le bouton d’application est alors désactivé.

## Application des seuils

En mode legacy, pour une sélection utilisateur 20–80 %, le client demande :

```text
lower-limit-delta 1
limit 80
lower-limit-delta 59
status --json
```

Le delta temporaire de 1 évite qu’une réduction du plafond ne laisse un seuil inférieur intermédiaire invalide dans l’API batt. La dernière commande fixe la borne interne à 21 %. batt reprend strictement sous cette borne : 20 % autorise ainsi la recharge.

Ces écritures sont successives, pas transactionnelles. En cas d’échec, le dropplet affiche une erreur ; une écriture précédente peut déjà avoir modifié le moteur. Le statut réel doit être vérifié avant de considérer la plage demandée comme appliquée.

En mode firmware, le seuil inférieur demandé est transmis sans l’ajustement legacy. Les propriétés du contrôle dépendent alors du firmware et du backend batt.

## Communication et privilèges

Le client exécute le binaire avec des arguments structurés, sans shell pour les opérations quotidiennes :

```text
/Library/PrivilegedHelperTools/local.chargeguard.batt
  --config /Library/Application Support/ChargeGuard/batt.json
  --daemon-socket /var/run/chargeguard-batt.sock
  status --json
```

`Process` tourne dans une tâche détachée de priorité utilitaire. Une limite de 15 secondes est prévue pour les commandes ordinaires. Le JSON expose le niveau, l’état de charge, la configuration et les capacités détectées par batt.

Seule l’installation ou la désinstallation utilise `osascript` avec une autorisation administrateur macOS. Le dropplet copie les deux fichiers fixes de l’installateur dans un répertoire temporaire unique : un assistant privilégié ne peut pas nécessairement lire directement un script situé dans Documents, sous les protections macOS. Les chemins sont échappés comme arguments shell. La copie temporaire est supprimée après l’opération.

Le binaire installé et le répertoire de configuration appartiennent à `root`. Le service est configuré avec `--always-allow-non-root-access` pour permettre au widget d’envoyer des commandes sans demander un mot de passe à chaque réglage. C’est un service accessible aux clients locaux, pas une authentification exclusive du widget.

## Fichiers système

| Emplacement | Usage |
| --- | --- |
| `/Library/PrivilegedHelperTools/local.chargeguard.batt` | Exécutable installé, mode 755, propriétaire root |
| `/Library/LaunchDaemons/local.chargeguard.batt.plist` | Service `launchd`, label `local.chargeguard.batt` |
| `/Library/Application Support/ChargeGuard/batt.json` | Configuration persistante, mode 600 |
| `/Library/Application Support/ChargeGuard/engine.log` | Sortie standard et erreurs du service |
| `/var/run/chargeguard-batt.sock` | Socket Unix entre clients et service |

Le service utilise `RunAtLoad` et `KeepAlive`. Le fichier initial configure une charge libre à 100 %, puis l’utilisateur applique sa plage. L’installation désactive la prévention de veille inactive, conserve la suspension de charge avant veille en mode legacy et n’active ni décharge forcée ni gestion de la LED.

## Cycle de vie du widget et du service

L’activation du dropplet charge les préférences, lit la batterie et lance le rafraîchissement d’affichage toutes les 15 secondes. Le mode harness utilise des données de démonstration et n’installe pas le moteur.

La désactivation arrête le timer, annule la tâche suivie, libère le maintien d’ouverture de la shelf et retire l’activité compacte. Elle ne désinstalle pas le service explicitement installé par l’utilisateur. Les tâches système déjà lancées ne sont pas une transaction annulable avec la vue.

La charge libre temporaire utilise `batt disable --for=2h`. La restauration est gérée par batt et ne dépend pas du timer du widget. La désinstallation demande d’abord `disable`, puis retire le service et son exécutable. Elle s’arrête si cette première étape échoue.
