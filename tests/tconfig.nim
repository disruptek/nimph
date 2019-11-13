import std/os
import std/strutils
import std/options
import std/tables

import unittest2

import bump

import nimph/config
import nimph/project

suite "nimcfg":
  setup:
    const
      fn = "tests/test.cfg"
      testcfg {.used.} = newTarget(fn)
      was {.used.} = staticRead(fn.extractFilename)
    let
      target = findTarget(".")
      project {.used.} = newProject(target.found.get)

  test "load a nim.cfg":
    let
      loaded = loadProjectCfg(fn)
    check loaded.isSome

  test "naive parse":
    let
      parsed = parseProjectCfg(testcfg)
    check parsed.ok
    check "nimblePath" in parsed.table
    checkpoint $parsed.table
    check parsed.table["path"].len > 1
    for find in ["test4", "test3:foo", "test2=foo"]:
      block found:
        for value in parsed.table.values:
          if value == find:
            break found
        check false

  test "add a line to a config":
    check testcfg.appendConfig("--clearNimblePath")
    let
      now = readFile(fn)
    check was.splitLines.len + 1 == now.splitLines.len
    writeFile(fn, was)
