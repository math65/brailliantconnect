#!/bin/bash
#
# Builds libusb and libmtp as UNIVERSAL libraries (arm64 + x86_64) and installs
# them into Vendor/.
#
# Purpose: the end user installs nothing — neither Homebrew nor libmtp. The
# embedded dylibs refer to each other through @loader_path, so Vendor/ can be
# moved as it is.
#
# Only maintainers need this script: it regenerates the shipped binaries.
# Keeping it also meets the LGPL's requirement that the libraries can be
# rebuilt and replaced.
#
# Prerequisites: Xcode Command Line Tools (clang, make, lipo, install_name_tool).

set -euo pipefail

LIBUSB_VERSION="1.0.30"
LIBMTP_VERSION="1.1.23"

# SHA-256 of the upstream tarballs for the versions above. Changing a version
# means changing its checksum: a download that does not match is refused, since
# these libraries end up parsing whatever a USB device sends.
# Source: Homebrew's formulae for the same URLs (libusb 1.0.30, libmtp 1.1.23).
LIBUSB_SHA256="fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf"
LIBMTP_SHA256="74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
WORK="${WORK_DIR:-$(mktemp -d)}"

MIN_ARM64="11.0"
MIN_X86_64="10.15"

log() { printf '\n=== %s ===\n' "$*"; }

# configure and make write to log files rather than to the terminal; a failed
# step stops the script and shows the end of its log.
build_failed() {
  echo "ERROR: $1 failed. Last lines of $2:" >&2
  tail -n 30 "$2" >&2
  exit 1
}

# --- Fetching the sources -----------------------------------------------------
# The Homebrew cache is reused when present, otherwise upstream is downloaded.
# Either way the checksum is verified.

verify_sha256() {
  local file="$1" expected="$2" actual
  actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [ "$actual" != "$expected" ]; then
    echo "ERROR: checksum mismatch for $(basename "$file")." >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

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
  verify_sha256 "$usb_tar" "$LIBUSB_SHA256"

  if [ -n "$cache" ] && [ -f "$cache/libmtp--${LIBMTP_VERSION}.tar.gz" ]; then
    cp "$cache/libmtp--${LIBMTP_VERSION}.tar.gz" "$mtp_tar"
  else
    curl -fsSL -o "$mtp_tar" \
      "https://downloads.sourceforge.net/project/libmtp/libmtp/${LIBMTP_VERSION}/libmtp-${LIBMTP_VERSION}.tar.gz"
  fi
  verify_sha256 "$mtp_tar" "$LIBMTP_SHA256"

  mkdir -p "$WORK/src/libusb" "$WORK/src/libmtp"
  tar xjf "$usb_tar" -C "$WORK/src/libusb" --strip-components=1
  tar xzf "$mtp_tar" -C "$WORK/src/libmtp" --strip-components=1
}

# --- Building one architecture -------------------------------------------------

build_arch() {
  local arch="$1" min host_opt=""
  if [ "$arch" = "arm64" ]; then
    min="$MIN_ARM64"
  else
    min="$MIN_X86_64"
  fi

  # --host is passed only when actually cross-compiling: forcing it for the
  # native architecture would put configure into "guessing" mode and skew its
  # header detection.
  local native; native="$(uname -m)"
  if [ "$arch" != "$native" ]; then
    host_opt="--host=${arch}-apple-darwin"
    [ "$arch" = "arm64" ] && host_opt="--host=aarch64-apple-darwin"
  fi

  local prefix="$WORK/out/$arch"
  local flags="-arch $arch -mmacosx-version-min=$min"
  mkdir -p "$prefix" "$WORK/build/$arch"

  # Built IN a copy of the sources (in-tree). libmtp ships a gphoto2-endian.h
  # pre-generated for Linux; in an out-of-tree build it would hide the one
  # configure generates, and the build would fail on byteswap.h, which macOS
  # does not have.
  local usb_build="$WORK/build/$arch/libusb"
  local mtp_build="$WORK/build/$arch/libmtp"
  [ -d "$usb_build" ] || cp -R "$WORK/src/libusb" "$usb_build"
  [ -d "$mtp_build" ] || cp -R "$WORK/src/libmtp" "$mtp_build"

  log "libusb $LIBUSB_VERSION for $arch"
  local usb_log="$WORK/build/$arch/libusb.log"
  ( cd "$usb_build" && ./configure \
      --prefix="$prefix" $host_opt \
      --enable-shared --disable-static --disable-udev \
      CFLAGS="$flags" LDFLAGS="$flags" && \
    make -j"$(sysctl -n hw.ncpu)" && make install ) >"$usb_log" 2>&1 \
    || build_failed "libusb for $arch" "$usb_log"

  log "libmtp $LIBMTP_VERSION for $arch"
  # --disable-mtpz avoids a dependency on libgcrypt (Zune encryption, which a
  # braille display has no use for).
  local mtp_log="$WORK/build/$arch/libmtp.log"
  ( cd "$mtp_build" && PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
    ./configure \
      --prefix="$prefix" $host_opt \
      --enable-shared --disable-static --disable-mtpz --with-udev=no \
      CFLAGS="$flags" LDFLAGS="$flags" && \
    make -j"$(sysctl -n hw.ncpu)" -C src && \
    make -C src install ) >"$mtp_log" 2>&1 \
    || build_failed "libmtp for $arch" "$mtp_log"
}

# --- Universal assembly ------------------------------------------------------

fix_paths() {
  # Rewrites the paths of a pair of SINGLE-architecture dylibs.
  # This must happen before lipo: on a universal binary otool lists both
  # architectures, and install_name_tool -change would fix only the first
  # occurrence, leaving the other pointing into the build folder.
  local dir="$1"
  [ -f "$dir/libmtp.9.dylib" ] || return 0

  # @rpath ids: the executable resolves them through its own rpaths.
  # The libmtp -> libusb cross-reference stays @loader_path, since the two
  # libraries always travel together in the same folder.
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
  log "Assembling the universal binaries"
  mkdir -p "$VENDOR"

  for arch in arm64 x86_64; do
    fix_paths "$WORK/out/$arch/lib"
  done

  for lib in libusb-1.0.0.dylib libmtp.9.dylib; do
    local arm="$WORK/out/arm64/lib/$lib"
    local intel="$WORK/out/x86_64/lib/$lib"
    # Both slices or nothing: the app ships as a universal binary, and an
    # arm64-only library would load on no Intel Mac.
    if [ ! -f "$arm" ] || [ ! -f "$intel" ]; then
      echo "ERROR: $lib missing for one architecture after the build." >&2
      exit 1
    fi
    lipo -create "$arm" "$intel" -output "$VENDOR/$lib"
    chmod 755 "$VENDOR/$lib"
    # Ad-hoc signature: on Apple Silicon a dylib whose paths were rewritten has
    # an invalid signature and would refuse to load.
    codesign --force --sign - "$VENDOR/$lib"
  done
}

copy_licenses() {
  log "Copying the licences (LGPL obligation)"
  cp "$WORK/src/libmtp/COPYING" "$VENDOR/LICENSE-libmtp.txt"
  cp "$WORK/src/libusb/COPYING" "$VENDOR/LICENSE-libusb.txt"
  # Vendor/README.txt is written by hand and committed; it is not regenerated
  # here, since that used to overwrite it with older wording. It names the
  # versions, though, so a version change has to reach it.
  local readme="$VENDOR/README.txt"
  if ! grep -q "libusb $LIBUSB_VERSION" "$readme" \
     || ! grep -q "libmtp $LIBMTP_VERSION" "$readme"; then
    echo "WARNING: $readme does not name libusb $LIBUSB_VERSION and" >&2
    echo "libmtp $LIBMTP_VERSION: update it by hand." >&2
  fi
}

verify() {
  log "Verifying"
  for lib in libusb-1.0.0.dylib libmtp.9.dylib; do
    echo "--- $lib"
    lipo -info "$VENDOR/$lib"
    # Keep only the dependency lines (indented): on a fat binary otool inserts
    # headers that contain the path of the file being examined.
    local deps
    deps="$(otool -L "$VENDOR/$lib" | grep '^[[:space:]]')"
    if printf '%s' "$deps" | grep -qE "/opt/homebrew|/usr/local/opt|$WORK"; then
      echo "ERROR: reference to a build path in $lib" >&2
      printf '%s\n' "$deps" >&2
      exit 1
    fi
    printf '%s\n' "$deps" | sed 's/^	/    /'
  done
  echo
  echo "No reference to Homebrew: the libraries are self-contained."
}

main() {
  log "Building the embedded libraries (working folder: $WORK)"
  fetch_sources
  # Called plainly, never after || or inside if: either would switch errexit
  # off for the whole function, and a failed x86_64 build used to end in an
  # arm64-only library and a warning.
  for arch in arm64 x86_64; do
    build_arch "$arch"
  done
  make_universal
  copy_licenses
  verify
  log "Done — libraries installed in $VENDOR"
}

main "$@"
