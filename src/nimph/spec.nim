import std/strutils
import std/hashes
import std/uri
import std/os
import std/times

import cutelog
export cutelog

const
  dotNimble* {.strdefine.} = "".addFileExt("nimble")
  dotNimbleLink* {.strdefine.} = "".addFileExt("nimble-link")
  dotGit* {.strdefine.} = "".addFileExt("git")
  dotHg* {.strdefine.} = "".addFileExt("hg")
  DepDir* {.strdefine.} = "deps"
  PkgDir* {.strdefine.} = "pkgs"
  NimCfg* {.strdefine.} = "nim".addFileExt("cfg")
  ghTokenFn* {.strdefine.} = "github_api_token"
  ghTokenEnv* {.strdefine.} = "NIMPH_TOKEN"
  hubTokenFn* {.strdefine.} = "".addFileExt("config") / "hub"
  stalePackages* {.intdefine.} = 14
  configFile* {.strdefine.} = "nimph".addFileExt("toml")
  nimbleMeta* {.strdefine.} = "nimblemeta".addFileExt("json")
  officialPackages* {.strdefine.} = "packages_official.json"
  emptyRelease* {.strdefine.} = "#head"
  defaultRemote* {.strdefine.} = "origin"
  excludeMissingPaths* {.booldefine.} = false
  writeNimbleDirPaths* {.booldefine.} = false
  hubTime* = initTimeFormat "yyyy-MM-dd\'T\'HH:mm:ss\'Z\'"
  shortDate* = initTimeFormat "yyyy-MM-dd"

  # when true, try to clamp analysis to project-local directories
  WhatHappensInVegas* = false

template withinDirectory*(path: string; body: untyped): untyped =
  if not path.dirExists:
    raise newException(ValueError, path & " is not a directory")
  let cwd = getCurrentDir()
  setCurrentDir(path)
  defer:
    setCurrentDir(cwd)
  body

template isValid*(url: Uri): bool = url.scheme.len != 0

proc hash*(url: Uri): Hash =
  ## help hash URLs
  var h: Hash = 0
  for field in url.fields:
    when field is string:
      h = h !& field.hash
    elif field is bool:
      h = h !& field.hash
  result = !$h

proc bare*(url: Uri): Uri =
  result = url
  result.anchor = ""

proc bareUrlsAreEqual*(a, b: Uri): bool =
  ## compare two urls without regard to their anchors
  if a.isValid and b.isValid:
    var
      x = a.bare
      y = b.bare
    result = $x == $y

proc pathToImport*(path: string): string =
  ## calculate how a path will be imported by the compiler
  assert path.len > 0
  result = path.lastPathPart.split("-")[0]
  assert result.len > 0
