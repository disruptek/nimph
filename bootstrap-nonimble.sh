#!/bin/sh

RELEASE="release"
if test "$*" = "test"; then
  # reduce nimterop spam?
  RELEASE="release"
fi

cd src
git clone --depth 1 https://github.com/disruptek/bump.git
git clone --depth 1 https://github.com/disruptek/cutelog.git
git clone --depth 1 https://github.com/disruptek/gittyup.git
git clone --depth 1 https://github.com/disruptek/nimgit2.git
git clone --depth 1 --branch v0.6.11 https://github.com/genotrance/nimterop.git
git clone --depth 1 https://github.com/nitely/nim-regex.git
git clone --depth 1 https://github.com/nitely/nim-unicodedb.git
git clone --depth 1 https://github.com/nitely/nim-unicodeplus.git
git clone --depth 1 https://github.com/nitely/nim-segmentation.git
git clone --depth 1 https://github.com/c-blake/cligen.git
git clone --depth 1 https://github.com/zevv/npeg.git
git clone --depth 1 https://github.com/disruptek/jsonconvert.git
git clone --depth 1 https://github.com/disruptek/badresults.git
git clone --depth 1 https://github.com/disruptek/github.git
git clone --depth 1 https://github.com/disruptek/rest.git
git clone --depth 1 https://github.com/disruptek/foreach.git
nim c --define:release --path:nim-regex/src --path:nim-unicodedb/src --path:nim-unicodeplus/src --path:nim-segmentation/src --path:cligen nimterop/nimterop/toast.nim
nim c --outdir:.. --define:$RELEASE --path:cligen --path:foreach --path:github/src --path:rest --path:npeg/src --path:jsonconvert --path:badresults --path:bump --path:cutelog --path:gittyup --path:nimgit2 --path:nimterop --path:nim-regex/src --path:nim-unicodedb/src --path:nim-unicodeplus/src --path:nim-segmentation/src nimph.nim
cd ..

if test -x nimph; then
  echo "nimph built successfully"
else
  echo "unable to build nimph"
  exit 1
fi
