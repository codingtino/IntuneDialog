#!/bin/bash

VERSION=$(<./version)
((VERSION++))
echo $VERSION > ./version
PKG_NAME="IntuneDialog-v0.$VERSION.pkg"

pkgbuild \
  --identifier com.ggeg.intunedialog \
  --version "0.$VERSION" \
  --root ./payload \
  --scripts ./scripts \
  "./builds/$PKG_NAME"

echo "✅ .pkg created: $PKG_NAME"
