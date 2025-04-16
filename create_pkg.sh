#!/bin/bash

VERSION="$1"
PKG_NAME="IntuneDialog-v$VERSION.pkg"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]{1,3}$ ]]; then
  echo "❌ Invalid version number: '$VERSION'"
  echo "Usage: $0 <version> (e.g., 1.0 or 0.123)"
  exit 1
fi

pkgbuild \
  --identifier com.ggeg.intunedialog \
  --version "$VERSION" \
  --root ./payload \
  --scripts ./scripts \
  "$PKG_NAME"

echo "✅ .pkg created: $PKG_NAME"
