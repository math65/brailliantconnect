#!/bin/bash
#
# Compile libusb et libmtp en bibliothèques UNIVERSELLES (arm64 + x86_64)
# et les installe dans Vendor/.
#
# Objectif : l'utilisateur final n'a rien à installer — ni Homebrew, ni libmtp.
# Les dylibs embarquées se référencent mutuellement via @loader_path, donc le
# dossier Vendor/ est déplaçable tel quel.
#
# Ce script n'est utile qu'aux mainteneurs : il régénère les binaires livrés.
# Le conserver satisfait aussi l'obligation LGPL de permettre la reconstruction
# et le remplacement des bibliothèques.
#
# Prérequis : Xcode Command Line Tools (clang, make, lipo, install_name_tool).

set -euo pipefail

LIBUSB_VERSION="1.0.30"
LIBMTP_VERSION="1.1.23"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
WORK="${WORK_DIR:-$(mktemp -d)}"

MIN_ARM64="11.0"
MIN_X86_64="10.15"

log() { printf '\n=== %s ===\n' "$*"; }

# --- Récupération des sources -------------------------------------------------
# On réutilise le cache Homebrew s'il est présent, sinon on télécharge en amont.

fetch_sources() {
  mkdir -p "$WORK/src"
  local cache=""
  command -v brew >/dev/null 2>&1 && cache="$(brew --cache 2>/dev/null || true)"

  local usb_tar="$WORK/src/libusb.tar.bz2"
  local mtp_tar="$WORK/src/libmtp.tar.gz"

  if [ -n "$cache" ] && [ -f "$cache/libusb--${LIBUSB_VERSION}.tar.bz2" ]; then
    cp "$cache/libusb--${LIBUSB_VERSION}.tar.bz2" "$usb_tar"
  else
    curl -fsSL -o "$usb_tar" \
      "https://github.com/libusb/libusb/releases/download/v${LIBUSB_VERSION}/libusb-${LIBUSB_VERSION}.tar.bz2"
  fi

  if [ -n "$cache" ] && [ -f "$cache/libmtp--${LIBMTP_VERSION}.tar.gz" ]; then
    cp "$cache/libmtp--${LIBMTP_VERSION}.tar.gz" "$mtp_tar"
  else
    curl -fsSL -o "$mtp_tar" \
      "https://downloads.sourceforge.net/project/libmtp/libmtp/${LIBMTP_VERSION}/libmtp-${LIBMTP_VERSION}.tar.gz"
  fi

  mkdir -p "$WORK/src/libusb" "$WORK/src/libmtp"
  tar xjf "$usb_tar" -C "$WORK/src/libusb" --strip-components=1
  tar xzf "$mtp_tar" -C "$WORK/src/libmtp" --strip-components=1
}

# --- Compilation par architecture --------------------------------------------

build_arch() {
  local arch="$1" min host_opt=""
  if [ "$arch" = "arm64" ]; then
    min="$MIN_ARM64"
  else
    min="$MIN_X86_64"
  fi

  # --host n'est passé qu'en cross-compilation réelle : l'imposer pour
  # l'architecture native ferait basculer configure en mode « devinette »
  # et fausserait la détection des en-têtes.
  local native; native="$(uname -m)"
  if [ "$arch" != "$native" ]; then
    host_opt="--host=${arch}-apple-darwin"
    [ "$arch" = "arm64" ] && host_opt="--host=aarch64-apple-darwin"
  fi

  local prefix="$WORK/out/$arch"
  local flags="-arch $arch -mmacosx-version-min=$min"
  mkdir -p "$prefix" "$WORK/build/$arch"

  # Compilation DANS une copie des sources (in-tree). libmtp livre un
  # gphoto2-endian.h pré-généré pour Linux ; en compilant hors-source, il
  # masquerait celui que configure génère et le build échouerait sur
  # byteswap.h, absent de macOS.
  local usb_build="$WORK/build/$arch/libusb"
  local mtp_build="$WORK/build/$arch/libmtp"
  [ -d "$usb_build" ] || cp -R "$WORK/src/libusb" "$usb_build"
  [ -d "$mtp_build" ] || cp -R "$WORK/src/libmtp" "$mtp_build"

  log "libusb $LIBUSB_VERSION pour $arch"
  ( cd "$usb_build" && ./configure \
      --prefix="$prefix" $host_opt \
      --enable-shared --disable-static --disable-udev \
      CFLAGS="$flags" LDFLAGS="$flags" >/dev/null && \
    make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null )

  log "libmtp $LIBMTP_VERSION pour $arch"
  # --disable-mtpz évite une dépendance à libgcrypt (chiffrement Zune,
  # sans objet pour une plage braille).
  ( cd "$mtp_build" && PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
    ./configure \
      --prefix="$prefix" $host_opt \
      --enable-shared --disable-static --disable-mtpz --with-udev=no \
      CFLAGS="$flags" LDFLAGS="$flags" >/dev/null && \
    make -j"$(sysctl -n hw.ncpu)" -C src >/dev/null && \
    make -C src install >/dev/null )
}

# --- Assemblage universel -----------------------------------------------------

fix_paths() {
  # Réécrit les chemins d'une paire de dylibs MONO-architecture.
  # À faire impérativement avant lipo : sur un binaire universel, otool liste
  # les deux architectures et install_name_tool -change ne corrigerait que la
  # première occurrence, laissant l'autre pointer vers le dossier de build.
  local dir="$1"
  [ -f "$dir/libmtp.9.dylib" ] || return 0

  # id en @rpath : l'exécutable les résout via ses propres rpath.
  # La référence croisée libmtp -> libusb reste en @loader_path car les deux
  # bibliothèques voyagent toujours ensemble dans le même dossier.
  install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$dir/libusb-1.0.0.dylib"
  install_name_tool -id "@rpath/libmtp.9.dylib" "$dir/libmtp.9.dylib"

  local usb_ref
  usb_ref="$(otool -L "$dir/libmtp.9.dylib" \
             | awk '/libusb-1\.0\.0\.dylib/ {print $1; exit}')"
  if [ -n "$usb_ref" ] && [ "$usb_ref" != "@loader_path/libusb-1.0.0.dylib" ]; then
    install_name_tool -change "$usb_ref" "@loader_path/libusb-1.0.0.dylib" \
      "$dir/libmtp.9.dylib"
  fi
}

make_universal() {
  log "Assemblage des binaires universels"
  mkdir -p "$VENDOR"

  for arch in arm64 x86_64; do
    fix_paths "$WORK/out/$arch/lib"
  done

  for lib in libusb-1.0.0.dylib libmtp.9.dylib; do
    local arm="$WORK/out/arm64/lib/$lib"
    local intel="$WORK/out/x86_64/lib/$lib"
    if [ -f "$arm" ] && [ -f "$intel" ]; then
      lipo -create "$arm" "$intel" -output "$VENDOR/$lib"
    elif [ -f "$arm" ]; then
      echo "AVERTISSEMENT : $lib compilée pour arm64 uniquement." >&2
      cp "$arm" "$VENDOR/$lib"
    else
      echo "ERREUR : $lib introuvable après compilation." >&2
      exit 1
    fi
    chmod 755 "$VENDOR/$lib"
    # Signature ad hoc : sur Apple Silicon, une dylib dont les chemins ont été
    # réécrits a une signature invalide et refuserait de se charger.
    codesign --force --sign - "$VENDOR/$lib"
  done
}

copy_licenses() {
  log "Copie des licences (obligation LGPL)"
  cp "$WORK/src/libmtp/COPYING" "$VENDOR/LICENSE-libmtp.txt" 2>/dev/null || true
  cp "$WORK/src/libusb/COPYING" "$VENDOR/LICENSE-libusb.txt" 2>/dev/null || true
  cat > "$VENDOR/README.txt" <<EOF
Bibliothèques tierces embarquées par BrailliantConnect
======================================================

  libusb $LIBUSB_VERSION   — https://libusb.info/
  libmtp $LIBMTP_VERSION   — https://libmtp.sourceforge.net/

Toutes deux sont distribuées sous licence GNU LGPL version 2.1 ou ultérieure.
Le texte des licences se trouve dans LICENSE-libusb.txt et LICENSE-libmtp.txt.

Conformément à la LGPL, ces bibliothèques sont liées DYNAMIQUEMENT : elles sont
chargées à l'exécution et peuvent être remplacées par une autre version
compatible en substituant simplement les fichiers .dylib de ce dossier.

Elles ont été compilées sans modification du code source amont, par le script
tools/build-vendor.sh fourni avec ce projet, qui permet de les reconstruire.
EOF
}

verify() {
  log "Vérification"
  for lib in libusb-1.0.0.dylib libmtp.9.dylib; do
    echo "--- $lib"
    lipo -info "$VENDOR/$lib"
    # Ne garder que les lignes de dépendance (indentées) : sur un binaire fat,
    # otool intercale des en-têtes contenant le chemin du fichier examiné.
    local deps
    deps="$(otool -L "$VENDOR/$lib" | grep '^[[:space:]]')"
    if printf '%s' "$deps" | grep -qE "/opt/homebrew|/usr/local/opt|$WORK"; then
      echo "ERREUR : référence à un chemin de compilation dans $lib" >&2
      printf '%s\n' "$deps" >&2
      exit 1
    fi
    printf '%s\n' "$deps" | sed 's/^	/    /'
  done
  echo
  echo "Aucune référence à Homebrew : les bibliothèques sont autonomes."
}

main() {
  log "Compilation des bibliothèques embarquées (dossier de travail : $WORK)"
  fetch_sources
  for arch in arm64 x86_64; do
    build_arch "$arch" || {
      echo "AVERTISSEMENT : échec de la compilation pour $arch." >&2
      [ "$arch" = "arm64" ] && exit 1
    }
  done
  make_universal
  copy_licenses
  verify
  log "Terminé — bibliothèques installées dans $VENDOR"
}

main "$@"
