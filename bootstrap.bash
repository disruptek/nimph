#!/bin/bash

if ! test -f src/nimph.nim; then
	git clone --depth 1 git://github.com/disruptek/nimph.git
  cd nimph
fi

mkdir -p deps

export NIMBLE_DIR=`pwd`/deps
export NIMPH=`pwd`/src

nimble --accept refresh
nimble install --depsOnly

echo "--clearNimblePath"                 > nim.cfg
echo '--nimblePath="$config/deps/pkgs"' >> nim.cfg
echo '--path="$config/src"'             >> nim.cfg
echo "--outdir=\"`pwd`\""               >> nim.cfg

nim c src/nimph.nim && realpath nimph
