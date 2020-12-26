version = "1.0.6"
author = "disruptek"
description = "nim package handler from the future"
license = "MIT"
requires "github >= 2.0.3 & < 3.0.0"
requires "cligen >= 0.9.46 & < 2.0.0"
requires "bump >= 1.8.18 & < 2.0.0"
requires "npeg >= 0.21.3 & < 0.26.0"
requires "https://github.com/disruptek/jsonconvert < 2.0.0"
requires "https://github.com/disruptek/badresults < 2.0.0"
requires "https://github.com/disruptek/cutelog >= 1.1.0 & < 2.0.0"
requires "https://github.com/disruptek/gittyup >= 2.5.0 & < 3.0.0"
requires "https://github.com/narimiran/sorta"

bin = @["nimph"]
srcDir = "src"

# this breaks tests
#installDirs = @["docs", "tests", "src"]

backend = "c"

proc execCmd(cmd: string) =
  echo "execCmd:" & cmd
  exec cmd

proc execTest(test: string) =
  execCmd "nim c -r " & test
  execCmd "nim c -d:release -r " & test
  execCmd "nim c -d:danger -r " & test
  when false:
    when NimMajor >= 1 and NimMinor >= 1:
      execCmd "nim c --gc:arc -r " & test
      execCmd "nim c --gc:arc -d:danger -r " & test

# cpp is broken
#  execCmd "nim cpp -r " & test

task test, "run tests for travis":
  execTest("tests/tpackage.nim")
  execTest("tests/tconfig.nim")
  execTest("tests/tspec.nim")
  execTest("tests/tnimble.nim")
  execTest("tests/tgit.nim")
  execTest("tests/ttags.nim")
