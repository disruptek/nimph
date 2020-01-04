version = "0.6.9"
author = "disruptek"
description = "nim package handler from the future"
license = "MIT"
requires "nim >= 1.0.4"
requires "github >= 1.0.2"
requires "cligen >= 0.9.41"
requires "bump >= 1.8.18"
requires "npeg >= 0.21.3"
requires "https://github.com/disruptek/cutelog >= 1.1.0"
requires "https://github.com/disruptek/gittyup >= 2.0.5"
requires "https://github.com/stefantalpalaru/nim-unittest2 >= 0.0.1"

# fixup a dependency: regex 0.10.0 doesn't build with 1.0.4 stdlib
requires "regex >= 0.11.0"

bin = @["nimph"]
srcDir = "src"

backend = "c"

proc execCmd(cmd: string) =
  echo "execCmd:" & cmd
  exec cmd

proc execTest(test: string) =
  execCmd "nim c -f -r " & test
  execCmd "nim c -d:release -r " & test
  execCmd "nim c -d:danger -r " & test

# cpp is broken
#  execCmd "nim cpp -r " & test

task test, "run tests for travis":
  execTest("tests/tpackage.nim")
  execTest("tests/tconfig.nim")
  execTest("tests/tspec.nim")
  execTest("tests/tnimble.nim")
  execTest("tests/tgit.nim")
  execTest("tests/ttags.nim")
