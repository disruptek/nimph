version = "0.8.3"
author = "disruptek"
description = "nim package handler from the future"
license = "MIT"
requires "nim >= 1.0.4"
requires "github >= 2.0.0 & < 3.0.0"
requires "cligen >= 0.9.41 & < 0.9.48"
requires "bump >= 1.8.18 & < 2.0.0"
requires "npeg >= 0.21.3 & < 0.23.0"
requires "https://github.com/disruptek/jsonconvert < 2.0.0"
requires "https://github.com/disruptek/badresults < 2.0.0"
requires "https://github.com/disruptek/cutelog >= 1.1.0 & < 2.0.0"
requires "https://github.com/disruptek/gittyup >= 2.4.0 & < 3.0.0"

# fixup a dependency: regex 0.10.0 doesn't build with 1.0.4 stdlib
requires "regex >= 0.11.0"

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
