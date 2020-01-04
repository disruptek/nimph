import std/strformat
import std/options
import std/strutils
import std/hashes
import std/uri
import std/os
import std/times

import cutelog
export cutelog

import nimph/sanitize

type
  Flag* {.pure.} = enum
    Quiet
    Strict
    Force
    Dry
    Safe
    Network

  RollGoal* = enum
    Upgrade = "upgrade"
    Downgrade = "downgrade"
    Specific = "roll"

  ForkTargetResult* = object
    ok*: bool
    why*: string
    owner*: string
    repo*: string
    url*: Uri

const
  dotNimble* {.strdefine.} = "".addFileExt("nimble")
  dotNimbleLink* {.strdefine.} = "".addFileExt("nimble-link")
  dotGit* {.strdefine.} = "".addFileExt("git")
  dotHg* {.strdefine.} = "".addFileExt("hg")
  DepDir* {.strdefine.} = "" / "deps" / ""
  PkgDir* {.strdefine.} = "" / "pkgs" / ""
  NimCfg* {.strdefine.} = "nim".addFileExt("cfg")
  ghTokenFn* {.strdefine.} = "github_api_token"
  ghTokenEnv* {.strdefine.} = "NIMPH_TOKEN"
  hubTokenFn* {.strdefine.} = "".addFileExt("config") / "hub"
  stalePackages* {.intdefine.} = 14
  configFile* {.strdefine.} = "nimph".addFileExt("json")
  nimbleMeta* {.strdefine.} = "nimblemeta".addFileExt("json")
  officialPackages* {.strdefine.} = "packages_official".addFileExt("json")
  emptyRelease* {.strdefine.} = "#head"
  defaultRemote* {.strdefine.} = "origin"
  upstreamRemote* {.strdefine.} = "upstream"
  excludeMissingSearchPaths* {.booldefine.} = false
  excludeMissingLazyPaths* {.booldefine.} = true
  writeNimbleDirPaths* {.booldefine.} = false
  shortDate* = initTimeFormat "yyyy-MM-dd"
  # add Safe to defaultFlags to, uh, default to Safe mode
  defaultFlags*: set[Flag] = {Quiet, Strict}

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

proc normalizeUrl*(uri: Uri): Uri =
  result = uri
  if result.scheme == "" and result.path.startsWith("git@github.com:"):
    result.path = result.path["git@github.com:".len .. ^1]
    result.username = "git"
    result.hostname = "github.com"
    result.scheme = "ssh"

proc convertToGit*(uri: Uri): Uri =
  result = uri.normalizeUrl
  if not result.path.endsWith(".git"):
    result.path &= ".git"
  result.scheme = "git"
  result.username = ""

proc convertToSsh*(uri: Uri): Uri =
  result = uri.convertToGit
  if result.path.startsWith("/"):
    result.path = result.path[1..^1]
  if result.username == "":
    result.username = "git"
  result.path = result.username & "@" & result.hostname & ":" & result.path
  result.username = ""
  result.hostname = ""
  result.scheme = ""

proc packageName*(name: string): string =
  ## return a string that is plausible as a package name
  when true:
    result = name
  else:
    const capsOkay =
      when FilesystemCaseSensitive:
        true
      else:
        false
    let
      sane = name.sanitizeIdentifier(capsOkay = capsOkay)
    if sane.isSome:
      result = sane.get
    else:
      raise newException(ValueError, "unable to sanitize `" & name & "`")

proc packageName*(url: Uri): string =
  ## guess the name of a package from a url
  when defined(debug) or defined(debugPath):
    assert url.isValid
  result = packageName(url.path.extractFilename.changeFileExt(""))

proc importName*(path: string): string =
  ## a uniform name usable in code for imports
  assert path.len > 0
  const capsOkay =
    when FilesystemCaseSensitive:
      true
    else:
      false
  let
    sane = path.sanitizeIdentifier(capsOkay = capsOkay)
  if sane.isSome:
    result = sane.get
  else:
    raise newException(ValueError, "unable to sanitize `" & path & "`")

proc importName*(url: Uri): string =
  let url = url.normalizeUrl
  if not url.isValid:
    raise newException(ValueError, "invalid url: " & $url)
  elif url.scheme == "file":
    result = url.path.importName
  else:
    result = url.packageName.importName.toLowerAscii

proc forkTarget*(url: Uri): ForkTargetResult =
  result.url = url.normalizeUrl
  block success:
    if not result.url.isValid:
      result.why = &"url is invalid"
      break
    if result.url.hostname.toLowerAscii != "github.com":
      result.why = &"url {result.url} does not point to github"
      break
    if result.url.path.len < 1:
      result.why = &"unable to parse url {result.url}"
      break
    # split /foo/bar into (bar, foo)
    let start = if result.url.path.startsWith("/"): 1 else: 0
    (result.owner, result.repo) = result.url.path[start..^1].splitPath
    # strip .git
    if result.repo.endsWith(".git"):
      result.repo = result.repo[0..^len("git+2")]
    result.ok = result.owner.len > 0 and result.repo.len > 0
    if not result.ok:
      result.why = &"unable to parse url {result.url}"

{.warning: "replace this with compiler code".}
proc destylize*(s: string): string =
  ## this is how we create a uniformly comparable token
  result = s.toLowerAscii.replace("_")
