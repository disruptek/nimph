#!/bin/sh

if ! test -f src/nimph.nim; then
  git clone --depth 1 git://github.com/disruptek/nimph.git
  cd nimph
fi

export NIMBLE_DIR="`pwd`/nimbledeps"
mkdir "$NIMBLE_DIR"

nimble --accept refresh
nimble --accept install unicodedb@0.7.2 nimterop@0.6.11
nimble install "--passNim:--path:\"`pwd`/src\" --outdir:\"`pwd`\""

if test -x nimph; then
  echo "nimph built successfully"
else
  echo "unable to build nimph"
  exit 1
fi
