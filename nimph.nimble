version = "2.0.0"
author = "disruptek"
description = "nim package handler from the future"
license = "MIT"
requires "https://github.com/disruptek/testes >= 0.7.6 & < 1.0.0"
requires "https://github.com/disruptek/github >= 2.0.3 & < 3.0.0"
requires "https://github.com/c-blake/cligen >= 0.9.46 & < 2.0.0"
requires "https://github.com/disruptek/bump >= 1.8.18 & < 2.0.0"
requires "https://github.com/disruptek/ups < 2.0.0"
requires "https://github.com/zevv/npeg >= 0.21.3 & < 1.0.0"
requires "https://github.com/disruptek/jsonconvert < 2.0.0"
requires "https://github.com/disruptek/badresults < 2.0.0"
requires "https://github.com/disruptek/frosty < 2.0.0"
requires "https://github.com/disruptek/cutelog >= 1.1.0 & < 2.0.0"
requires "https://github.com/disruptek/gittyup >= 2.5.0 & < 3.0.0"
requires "https://github.com/narimiran/sorta"

bin = @["nimph"]
srcDir = "src"

# this breaks tests
#installDirs = @["docs", "tests", "src"]

task test, "run unit tests":
  exec findExe"testes"
