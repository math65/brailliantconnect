#!/bin/bash
#
# Assemble un dossier prêt à distribuer : un binaire universel accompagné des
# bibliothèques dont il a besoin. L'utilisateur final n'installe rien.
#
# Usage :
#   ./tools/make-dist.sh
#   CODESIGN_IDENTITY="Developer ID Application: Nom (TEAMID)" ./tools/make-dist.sh
#
# Sans CODESIGN_IDENTITY, le résultat est signé « ad hoc » : utilisable
# localement, mais macOS affichera un avertissement Gatekeeper chez les autres.
# Pour une diffusion publique, fournir une identité « Developer ID Application »
# puis notariser l'archive (voir la fin du script).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
DIST="$ROOT/dist"
NAME="BrailliantConnect"
STAGE="$DIST/$NAME"

log() { printf '\n=== %s ===\n' "$*"; }

cd "$ROOT"

log "Tests"
# Aucun paquet ne doit sortir si un test échoue : les tests couvrent notamment
# le confinement des chemins, qui protège contre l'écriture hors destination.
swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:" | tail -3
if ! swift test >/dev/null 2>&1; then
  echo "ERREUR : la suite de tests échoue, distribution interrompue." >&2
  exit 1
fi

log "Compilation du binaire universel (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64

BINARY="$ROOT/.build/apple/Products/Release/brailliant"
[ -f "$BINARY" ] || { echo "ERREUR : binaire introuvable ($BINARY)" >&2; exit 1; }

log "Assemblage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# Les bibliothèques sont placées À CÔTÉ du binaire : son rpath
# @executable_path les y trouve, où que le dossier soit déplacé.
cp "$BINARY" "$STAGE/brailliant"
cp "$VENDOR/libmtp.9.dylib" "$VENDOR/libusb-1.0.0.dylib" "$STAGE/"
cp "$VENDOR/LICENSE-libmtp.txt" "$VENDOR/LICENSE-libusb.txt" "$STAGE/"
chmod 755 "$STAGE/brailliant" "$STAGE"/*.dylib

cat > "$STAGE/LISEZMOI.txt" <<'EOF'
BrailliantConnect
=================

Accès aux plages braille Brailliant depuis macOS, sans macFUSE ni extension
noyau. Rien à installer : ce dossier se suffit à lui-même.

DÉMARRAGE
---------
1. Branchez la plage en USB et allumez-la.
2. Mettez-la en mode « transfert de fichiers » (et non en mode terminal braille).
3. Dans le Terminal, placez-vous dans ce dossier et lancez :

       ./brailliant doctor

COMMANDES
---------
   ./brailliant info                     état de la plage et espace disponible
   ./brailliant ls /documents            liste un dossier
   ./brailliant put mon-fichier.txt      envoie un fichier (dans /documents)
   ./brailliant get /notes ~/Bureau      récupère un dossier
   ./brailliant --help                   aide complète

POUR TAPER SIMPLEMENT « brailliant » DEPUIS N'IMPORTE OÙ
--------------------------------------------------------
       sudo ln -s "$PWD/brailliant" /usr/local/bin/brailliant

Le lien symbolique fonctionne : le programme retrouve ses bibliothèques
par son propre chemin, pas par le répertoire courant.

CONTENU
-------
   brailliant            le programme (universel : Apple Silicon et Intel)
   libmtp.9.dylib        bibliothèque MTP        (LGPL-2.1)
   libusb-1.0.0.dylib    bibliothèque USB        (LGPL-2.1)
   LICENSE-*.txt         texte des licences

Les deux bibliothèques sont liées dynamiquement et peuvent être remplacées
par une version compatible, conformément à la LGPL.
EOF

log "Réécriture des chemins et signature"
# Le binaire cherche les bibliothèques via @executable_path ; on s'en assure.
if ! otool -l "$STAGE/brailliant" | grep -q "@executable_path"; then
  install_name_tool -add_rpath "@executable_path" "$STAGE/brailliant"
fi

IDENTITY="${CODESIGN_IDENTITY:--}"
# Les bibliothèques d'abord : signer l'exécutable scelle ce dont il dépend.
codesign --force --timestamp --sign "$IDENTITY" "$STAGE/libusb-1.0.0.dylib"
codesign --force --timestamp --sign "$IDENTITY" "$STAGE/libmtp.9.dylib"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$STAGE/brailliant"
else
  # --options runtime : le « hardened runtime », exigé pour la notarisation.
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$STAGE/brailliant"
fi

log "Vérification"
lipo -info "$STAGE/brailliant"
echo "Dépendances :"
otool -L "$STAGE/brailliant" | grep '^[[:space:]]' | sed 's/^	/    /'
if otool -L "$STAGE/brailliant" | grep -qE "/opt/homebrew|/usr/local/opt|$ROOT/\.build"; then
  echo "ERREUR : le binaire référence un chemin de compilation." >&2
  exit 1
fi
codesign --verify --verbose=1 "$STAGE/brailliant" 2>&1 | sed 's/^/    /'

log "Archive"
cd "$DIST"
rm -f "$NAME.zip"
# ditto préserve les signatures et les attributs étendus, contrairement à zip.
ditto -c -k --keepParent "$NAME" "$NAME.zip"
echo "Archive : $DIST/$NAME.zip ($(du -h "$NAME.zip" | cut -f1))"

if [ "$IDENTITY" = "-" ]; then
  cat <<'EOF'

REMARQUE — signature ad hoc
Ce paquet fonctionne sur cette machine, mais macOS avertira les autres
utilisateurs (« développeur non identifié »). Pour une diffusion publique :

  CODESIGN_IDENTITY="Developer ID Application: VOTRE NOM (TEAMID)" \
      ./tools/make-dist.sh
  xcrun notarytool submit dist/BrailliantConnect.zip \
      --apple-id VOTRE@EMAIL --team-id TEAMID --wait

La notarisation d'un outil en ligne de commande ne permet pas d'agrafer le
ticket au binaire lui-même ; distribuez l'archive notarisée, ou placez le
binaire dans un .app ou un .pkg si vous voulez agrafer le ticket.
EOF
fi
