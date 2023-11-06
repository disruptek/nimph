#!/bin/sh

PASSES=""
if [ "$GITHUB_ACTIONS" = "true" ]; then
  if [ $(uname -s) = "Linux" ]; then
    LGEXT="so"
  else
    LGEXT="dylib"
  fi
  SO="$(pwd)/libgit2/build/libgit2.$LGEXT"
  ls -ld "$SO"
  PASSES="--define:libgit2Lib=$SO --passC:\"-I$(pwd)/libgit2/include\" --define:nimDebugDlOpen"
fi

mkdir -p temporary
cd temporary

git clone --depth 1 --branch 1.8.31 https://github.com/disruptek/bump.git
git clone --depth 1 --branch 2.0.1 https://github.com/disruptek/cutelog.git
git clone --depth 1 --branch 3.2.2 https://github.com/disruptek/gittyup.git
git clone --depth 1 --branch 2.0.3 https://github.com/disruptek/cligen.git
git clone --depth 1 --branch 0.26.0 https://github.com/zevv/npeg.git
git clone --depth 1 --branch 1.0.2 https://github.com/disruptek/jsonconvert.git
git clone --depth 1 --branch 2.1.3 https://github.com/disruptek/badresults.git
git clone --depth 1 --branch 3.0.0 https://github.com/disruptek/github.git
git clone --depth 1 --branch 0.0.7 https://github.com/disruptek/ups.git
git clone --depth 1 --branch 0.1.7 https://github.com/alaviss/hlibgit2.git
git clone --depth 1 --branch 0.1.5 https://github.com/haxscramper/hlibssh2.git

nim c --outdir:.. --define:release --path:../src --path:hlibgit2/src --path:hlibssh2/src --path:ups --path:cligen --path:github --path:npeg/src --path:jsonconvert --path:badresults --path:bump --path:cutelog --path:gittyup $PASSES ../src/nimph.nim
cd ..

if test -x nimph; then
  echo "nimph built successfully"
  echo "you can safely remove the 'temporary' subdirectory"
else
  echo "unable to build nimph"
  exit 1
fi
