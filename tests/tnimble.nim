import std/options
import std/strtabs

import unittest2

import bump

import nimph/nimble
import nimph/project

suite "nimble":
  setup:
    let
      target = findTarget(".")
      project {.used.} = newProject(target.found.get)

  test "parse some dump output":
    let
      text = """oneline: "is fine"""" & "\n"
      parsed = parseNimbleDump(text)
    check parsed.isSome

  test "via subprocess capture":
    let
      dumped = fetchNimbleDump(project.nimble.repo)
    check dumped.ok == true
    if dumped.ok:
      check dumped.table["Name"] == "nimph"
