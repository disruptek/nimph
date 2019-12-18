version = "0.4.3"
author = "disruptek"
description = "nim package handler from the future"
license = "MIT"
requires "nim >= 1.0.4"
#requires "compiler >= 1.0.4"
requires "github >= 1.0.2"
requires "cligen >= 0.9.41"
requires "bump >= 1.8.17"
requires "nimgit2 >= 0.1.1"
requires "npeg >= 0.21.3"
requires "https://github.com/disruptek/cutelog#1.1.1"
requires "https://github.com/stefantalpalaru/nim-unittest2 >= 0.0.1"

bin = @["nimph"]
srcDir = "src"

proc execCmd(cmd: string) =
  echo "execCmd:" & cmd
  exec cmd

proc execTest(test: string) =
  execCmd "nim c -f -r " & test
  execCmd "nim cpp -r " & test

task test, "run tests for travis":
  execTest("tests/tpackage.nim")
  execTest("tests/tconfig.nim")
  execTest("tests/tspec.nim")
  execTest("tests/tnimble.nim")
  execTest("tests/tgit.nim")
