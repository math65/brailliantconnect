# BrailliantConnect

Accès aux plages braille **Brailliant** (HumanWare) depuis macOS —
**sans macFUSE, sans extension noyau, sans rien à installer**.

Écrit en Swift. Testé sur Brailliant BI 40X (firmware 2.6.0), macOS 26,
Apple Silicon. Binaire universel : Apple Silicon et Intel.

## Le problème

La Brailliant s'expose en **MTP** (Media Transfer Protocol), le protocole
d'Android. macOS ne sait pas monter un volume MTP : rien n'apparaît dans le
Finder quand on branche la plage.

L'utilitaire officiel empile donc deux couches : un pilote pour atteindre le
matériel, puis **macFUSE** pour présenter la plage comme un volume montable.
macFUSE est un bon logiciel, activement maintenu (5.3.3, juillet 2026), et son
backend FSKit lui évite même l'extension noyau sur macOS 26. Le problème n'est
pas macFUSE : c'est l'empilement. En pratique, plusieurs utilisateurs se
retrouvent avec un dossier vide et aucun volume monté, et HumanWare a annoncé
en avril 2026 ne plus pouvoir en assurer le support.

## Le contournement

Ces couches sont **supprimées plutôt que remplacées**. Transférer un fichier
en MTP ne demande pas de monter un volume : le protocole passe entièrement par
USB en espace utilisateur, et `libmtp` (au-dessus de `libusb`) sait lui parler
directement.

Il n'y a donc rien à installer — ni pilote, ni couche de montage — et rien qui
puisse se désynchroniser d'une mise à jour de macOS. En contrepartie, la plage
n'apparaît pas dans le Finder : c'est un outil en ligne de commande.

## Installation

Aucune. Téléchargez l'archive, décompressez-la, et lancez :

```bash
./brailliant doctor
```

Le dossier contient le programme et les deux bibliothèques dont il a besoin :
600 Ko à télécharger, 1,9 Mo une fois décompressé. Ni Homebrew, ni libmtp, ni
Python, ni runtime à installer.

Pour taper simplement `brailliant` depuis n'importe où :

```bash
sudo ln -s "$PWD/brailliant" /usr/local/bin/brailliant
```

Le lien symbolique fonctionne : le programme retrouve ses bibliothèques par
son propre chemin (`@executable_path`), pas par le répertoire courant.

## Utilisation

Brancher la plage en USB et la mettre en mode **transfert de fichiers**
(pas en mode terminal braille).

| Commande | Effet |
|---|---|
| `brailliant info` | modèle, numéro de série, espace disponible |
| `brailliant ls [chemin]` | liste un dossier (`-l` avec les tailles) |
| `brailliant tree [chemin]` | affiche l'arborescence (`-d` pour limiter la profondeur) |
| `brailliant get <distant> [local]` | copie de la plage vers le Mac (fichier ou dossier) |
| `brailliant put <local> [distant]` | copie du Mac vers la plage (fichier ou dossier) |
| `brailliant rm <chemin>` | supprime (`-r` pour un dossier avec son contenu) |
| `brailliant mkdir <chemin>` | crée un dossier |
| `brailliant clean` | retire les fichiers parasites macOS (`.DS_Store`…) |
| `brailliant doctor` | vérifie que tout fonctionne |

Une plage expose souvent **plusieurs stockages** : mémoire interne, et clé USB
ou carte mémoire quand il y en a une. Les opérations portent sur le premier
(la mémoire interne) sauf indication contraire :

```bash
brailliant -s usb ls /
```

`-s` accepte le numéro affiché par `brailliant info` ou un fragment du nom, sans tenir
compte de la casse ni des accents (`-s 2`, `-s usb`, `-s memoire`). Sans cette
option, `ls /` rappelle quels autres stockages existent.

```bash
brailliant put ~/Documents/roman.txt /documents
```

```bash
brailliant get /notes ~/Bureau
```

Le dossier distant par défaut pour `put` est `/documents`. Les dossiers
manquants sont créés automatiquement. Les fichiers parasites de macOS
(`.DS_Store`, `._*`) sont exclus des transferts et masqués à l'affichage
(option `-a` pour les voir).

## Accessibilité

L'interface est pensée pour un lecteur d'écran : une information par ligne,
pas de tableaux ASCII, aucune couleur porteuse de sens, et une progression
affichée par paliers de 10 % plutôt qu'en rafraîchissement continu — désactivée
automatiquement hors terminal interactif.

## Sécurité

Les données venant de la plage sont traitées comme **non fiables** : MTP
n'impose aucune contrainte sur les noms de fichiers, et un périphérique peut
renvoyer ce qu'il veut.

- **Confinement des chemins.** Un nom contenant `..` ou `/` permettrait, une
  fois concaténé au dossier de destination, d'écrire n'importe où — jusqu'à
  déposer un fichier dans `~/Library/LaunchAgents`. Deux barrières
  indépendantes l'empêchent : rejet des noms non conformes à la lecture, et
  vérification que la cible finale reste sous le dossier demandé
  (`LocalPath.confine`). Les éléments concernés sont signalés dans `ls` et
  ignorés à la copie, avec un avertissement.
- **Affichage assaini.** Les noms peuvent contenir des séquences ANSI capables
  d'effacer l'écran ou de masquer des lignes déjà affichées, donc de dissimuler
  ce qu'une commande a réellement fait. Les caractères de contrôle sont
  neutralisés avant affichage.
- **Écrasement atomique.** MTP ne remplace pas un fichier en place. Plutôt que
  de supprimer l'ancien avant le transfert — ce qui détruirait les données en
  cas de coupure —, le nouveau fichier est envoyé sous un nom temporaire ;
  l'ancien n'est retiré qu'une fois le transfert terminé, puis le temporaire est
  renommé. L'espace disponible est vérifié au préalable. Si le renommage échoue,
  le message indique sous quel nom les données se trouvent.
- **Pas d'exécution externe.** Le programme n'appelle jamais `system`, `exec`
  ni aucun processus tiers : il n'y a pas de surface d'injection de commande.
- **Pas de privilèges.** Aucun setuid, aucun entitlement, aucun accès réseau.
  PIE et protections de pile actives.
- **Filtrage du fabricant.** Un téléphone Android est un appareil MTP comme un
  autre : sans filtre, `brailliant rm` pourrait s'appliquer à lui. Seuls les appareils
  HumanWare (`0x1C71`) sont retenus par défaut, et le message d'erreur nomme
  les appareils écartés. `--any-device` lève la restriction.
- **Validation de bibliothèque.** Signé avec une identité Developer ID, le
  binaire active le *hardened runtime*, qui interdit le chargement d'une
  bibliothèque non signée par la même équipe — sans quoi remplacer un `.dylib`
  voisin permettrait d'exécuter du code arbitraire dans le processus.

Le comportement mémoire a été vérifié sous **AddressSanitizer** sur l'ensemble
des opérations : aucune erreur détectée.

## Compilation

```bash
swift build -c release
```

```bash
swift test
```

La suite couvre le confinement des chemins, la neutralisation des séquences
d'affichage, la normalisation des chemins distants et le formatage. Elle est
exécutée automatiquement par `tools/make-dist.sh`, qui refuse de produire un
paquet si un test échoue.

Aucune dépendance externe : ni paquet Swift à télécharger, ni bibliothèque à
installer. Xcode n'est pas requis, seulement les Command Line Tools.

Pour produire le paquet distribuable (binaire universel + bibliothèques +
licences, archivé) :

```bash
./tools/make-dist.sh
```

Pour une diffusion publique, fournir une identité de signature :

```bash
CODESIGN_IDENTITY="Developer ID Application: NOM (TEAMID)" ./tools/make-dist.sh
```

`tools/build-vendor.sh` recompile `libmtp` et `libusb` depuis les sources amont
en binaires universels — utile pour changer de version ou vérifier la chaîne
de construction.

## Détails techniques

- La Brailliant (VID `0x1C71`, PID `0xC131`) n'est pas répertoriée dans
  libmtp 1.1.23. Peu importe : la détection **générique** prend le relais, car
  l'interface USB déclare la chaîne `MTP`. L'appareil est identifié comme
  Android — la plage tourne sur un socle Android.
- Les noms de fichiers accentués imposent une locale UTF-8 dans le processus :
  libmtp convertit les noms via `iconv` en s'appuyant sur `nl_langinfo(CODESET)`.
  Un binaire lancé hors d'un shell de connexion n'hérite pas forcément de
  `$LANG` ; `Brailliant.swift` force donc une locale UTF-8, sans quoi tous les
  accents seraient perdus.
- libmtp écrit des messages bénins directement sur les descripteurs 1 et 2
  depuis le code C. `Console.swift` les capture et les filtre — indispensable
  pour une sortie propre au lecteur d'écran ou redirigée (`--debug` pour tout voir).
- MTP ne remplace pas un fichier en place : sans suppression préalable, la plage
  se retrouve avec deux fichiers de même nom. `upload` s'en charge.
- `LIBMTP_destroy_file_t` ne libère **qu'un maillon** de la liste chaînée
  renvoyée par `LIBMTP_Get_Files_And_Folders` : il faut mémoriser le suivant
  avant de libérer l'actuel.
- Débit mesuré : **~17,5 Mo/s** en lecture (29,5 Mo en 1,7 s).
- Latences mesurées sur BI 40X (`brailliant bench`), déterminantes pour une
  future intégration au Finder :
  - énumération d'un dossier : **~0,2 ms par élément**, coût **linéaire**
    jusqu'à 400 fichiers (200 fichiers en 34 ms) ;
  - cycle complet connexion, listage, déconnexion : **~130 ms** ;
  - premier octet d'un fichier : **2 à 5 ms**.
  Autrement dit MTP n'est pas le goulot d'étranglement : une énumération à la
  demande reste fluide, sans cache élaboré.

## Bibliothèques embarquées

`Vendor/` contient `libmtp` 1.1.23 et `libusb` 1.0.30, compilées en binaires
universels **arm64 + x86_64** sans modification du code amont.

Elles ne dépendent que de bibliothèques fournies par macOS (`libSystem`,
`libiconv`, `IOKit`, `CoreFoundation`, `Security`) et ne contiennent **aucune
référence à Homebrew** — vérification intégrée aux scripts de build.

Les deux sont sous **LGPL-2.1**. Leur redistribution est permise ici parce que
le lien reste **dynamique**, que l'utilisateur peut **remplacer** les
bibliothèques en substituant les `.dylib` livrés, et que le texte des licences
ainsi que le script de reconstruction sont fournis.

## Suite envisagée

Faire apparaître la plage **dans le Finder**, via une **File Provider
Extension** — l'API Apple officielle utilisée par iCloud Drive, Dropbox ou
Google Drive. Elle fonctionne en espace utilisateur, sans extension noyau, et
constitue le remplaçant moderne et pérenne de macFUSE.

`BrailliantKit` est déjà une bibliothèque Swift indépendante du CLI :
l'extension pourra l'utiliser telle quelle. Cette étape nécessitera un projet
Xcode (une extension exige un bundle d'app, des entitlements et un App Group),
ainsi qu'un compte Apple Developer pour la signature.

## Historique

Un prototype Python a servi à démontrer la faisabilité avant ce portage. Il a
été retiré : il dépendait de Python — dont la présence n'est pas garantie sur
un Mac sans outils développeur — et portait deux défauts corrigés ici, une
traversée de chemin et une fuite mémoire sur les listes chaînées de libmtp.
