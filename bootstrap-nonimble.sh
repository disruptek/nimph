#!/bin/sh

cd src
git clone --depth 1 https://github.com/disruptek/bump.git
git clone --depth 1 https://github.com/disruptek/cutelog.git
git clone --depth 1 https://github.com/disruptek/gittyup.git
git clone --depth 1 https://github.com/disruptek/nimgit2.git
git clone --depth 1 https://github.com/genotrance/nimterop.git
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
nim c --path:nim-regex/src --path:nim-unicodedb/src --path:nim-unicodeplus/src --path:nim-segmentation/src --path:cligen nimterop/nimterop/toast.nim
nim c --path:cligen --path:foreach --path:github/src --path:rest --path:npeg/src --path:jsonconvert --path:badresults --path:bump --path:cutelog --path:gittyup --path:nimgit2 --path:nimterop --path:nim-regex/src --path:nim-unicodedb/src --path:nim-unicodeplus/src --path:nim-segmentation/src nimph

realpath nimph
