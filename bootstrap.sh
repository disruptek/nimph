#!/bin/sh

if ! test -f src/nimph.nim; then
  git clone --depth 1 git://github.com/disruptek/nimph.git
  cd nimph
fi

export NIMBLE_DIR="`pwd`/deps"
mkdir --parents "$NIMBLE_DIR"

nimble --accept refresh
nimble install "--passNim:--path:\"`pwd`/src\" --outdir:\"`pwd`\""

realpath nimph
