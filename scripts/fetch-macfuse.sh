#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Ricardo J. Rodríguez, Universidad de Zaragoza
#
# Download an official macFUSE release and extract its user-space libfuse 2
# (lib/ and include/) into a local directory. Nothing is installed: the
# package is only expanded with pkgutil.
#
#   scripts/fetch-macfuse.sh <version> <destdir>
#   scripts/fetch-macfuse.sh 5.1.3 v513
#
# For 5.1.3 (the affected library used by the PoC) the disk image and the
# extracted libfuse.2.dylib are verified against known SHA-256 digests.
set -euo pipefail

VERSION=${1:?usage: $0 <version> <destdir>}
DEST=${2:?usage: $0 <version> <destdir>}

# Known-good digests (official GitHub release assets).
DMG_SHA256=""
LIB_SHA256=""
case "$VERSION" in
5.1.3)
	DMG_SHA256="e5f80ff8c3df826e997fb786b35125a0c6a672f4bba2770b0def6ba63ca4ef81"
	LIB_SHA256="cc379fdc488c7c899d6fa9d670d0018e00c3c9a7d3264c987405179bc0cee190"
	;;
esac
URL="https://github.com/macfuse/macfuse/releases/download/macfuse-$VERSION/macfuse-$VERSION.dmg"
WORK=$(mktemp -d)
MNT="$WORK/dmg"
cleanup() {
	hdiutil detach "$MNT" >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

sha() { shasum -a 256 "$1" | awk '{print $1}'; }
verify() { # verify <file> <expected|empty> <label>
	local got; got=$(sha "$1")
	if [[ -z "$2" ]]; then
		echo "   $3 sha256 $got (no reference digest for $VERSION, not verified)"
	elif [[ "$got" == "$2" ]]; then
		echo "   $3 sha256 OK"
	else
		echo "   $3 sha256 MISMATCH: got $got, expected $2" >&2
		exit 1
	fi
}

echo "== macFUSE $VERSION -> $DEST"
curl -fsSL -o "$WORK/macfuse.dmg" "$URL"
verify "$WORK/macfuse.dmg" "$DMG_SHA256" "disk image"

mkdir -p "$MNT"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$WORK/macfuse.dmg" >/dev/null
PKG=$(find "$MNT" -maxdepth 2 -name '*.pkg' -print -quit)
[[ -n "$PKG" ]] || { echo "no .pkg found in the disk image" >&2; exit 1; }
pkgutil --expand-full "$PKG" "$WORK/pkg" >/dev/null

PAYLOAD=$(find "$WORK/pkg" -type d -path '*Core.pkg/Payload' -print -quit)
[[ -d "$PAYLOAD/usr/local/lib" ]] || { echo "unexpected package layout" >&2; exit 1; }
verify "$PAYLOAD/usr/local/lib/libfuse.2.dylib" "$LIB_SHA256" "libfuse.2.dylib"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$PAYLOAD/usr/local/lib" "$PAYLOAD/usr/local/include" "$DEST/"
echo "   extracted $(ls "$DEST/lib" | tr '\n' ' ')"
