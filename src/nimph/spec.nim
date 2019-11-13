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
  hubTime* = initTimeFormat "yyyy-MM-dd\'T\'HH:mm:ss\'Z\'"
  shortDate* = initTimeFormat "yyyy-MM-dd"

template withinDirectory*(path: string; body: untyped): untyped =
  if not path.dirExists:
    raise newException(ValueError, path & " is not a directory")
  let cwd = getCurrentDir()
  setCurrentDir(path)
  defer:
    setCurrentDir(cwd)
  body
