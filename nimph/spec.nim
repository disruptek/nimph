import std/strformat
import std/options
import std/strutils
import std/hashes
import std/uri
import std/os
import std/times

import bump
import cutelog
export cutelog

import nimph/paths
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

  ImportName* = distinct string
  DotNimble* = distinct AbsoluteFile

const
  dotNimble* {.strdefine.} = "".addFileExt("nimble")
  dotNimbleLink* {.strdefine.} = "".addFileExt("nimble-link")
  dotGit* {.strdefine.} = "".addFileExt("git")
  dotHg* {.strdefine.} = "".addFileExt("hg")
  DepDir* {.strdefine.} = //////"deps"
  PkgDir* {.strdefine.} = //////"pkgs"
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
  # when true, try to support nimble
  AndNimble* = false

proc `$`*(file: DotNimble): string {.borrow.}
proc `$`*(name: ImportName): string {.borrow.}

template repo*(file: DotNimble): string =
  $parentDir(file.AbsoluteFile)

template package*(file: DotNimble): string =
  lastPathPart($file).changeFileExt("")

template ext*(file: DotNimble): string =
  splitFile($file).ext

proc toDotNimble*(file: AbsoluteFile): DotNimble =
  file.DotNimble

proc toDotNimble*(file: string): DotNimble =
  toAbsoluteFile(file).toDotNimble

proc toDotNimble*(file: Target): DotNimble =
  toDotNimble($file)

proc fileExists*(file: DotNimble): bool {.borrow.}

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

proc normalizeUrl*(uri: Uri): Uri =
  result = uri
  if result.scheme == "" and result.path.contains("@"):
    let
      usersep = result.path.find("@")
      pathsep = result.path.find(":")
    result.path = uri.path[pathsep+1 .. ^1]
    result.username = uri.path[0 ..< usersep]
    result.hostname = uri.path[usersep+1 ..< pathsep]
    result.scheme = "ssh"
  else:
    if result.scheme.startsWith("http"):
      result.scheme = "git"

proc convertToGit*(uri: Uri): Uri =
  result = uri.normalizeUrl
  if result.scheme == "" or result.scheme == "ssh":
    result.scheme = "git"
  if result.scheme == "git" and not result.path.endsWith(".git"):
    result.path &= ".git"
  result.username = ""

proc convertToSsh*(uri: Uri): Uri =
  result = uri.convertToGit
  if not result.path[0].isAlphaNumeric:
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
  var
    # ensure the path doesn't end in a slash
    path = url.path
  removeSuffix(path, {'/'})
  result = packageName(path.extractFilename.changeFileExt(""))

proc importName*(path: string): string =
  ## a uniform name usable in code for imports
  assert path.len > 0
  # strip any leading directories and extensions
  result = splitFile(path).name
  const capsOkay =
    when FilesystemCaseSensitive:
      true
    else:
      false
  let
    sane = path.sanitizeIdentifier(capsOkay = capsOkay)
  # if it's a sane identifier, use it
  if sane.isSome:
    result = sane.get
  elif not capsOkay:
    # emit a lowercase name on case-insensitive filesystems
    result = result.toLowerAscii
  # else, we're just emitting the existing file's basename

proc pathToImport*(path: string): string =
  ## calculate how a path will be imported by the compiler
  assert path.len > 0
  result = path.lastPathPart.split("-")[0]
  assert result.len > 0

proc importName*(dir: AbsoluteDir | AbsoluteFile): string =
  ## a uniform name usable in code for imports
  importName($dir)

proc importName*(file: DotNimble): string =
  ## a uniform name usable in code for imports
  importName(file.package)

proc importName*(url: Uri): string =
  ## a uniform name usable in code for imports
  let url = url.normalizeUrl
  if not url.isValid:
    raise newException(ValueError, "invalid url: " & $url)
  elif url.scheme == "file":
    result = url.path.importName
  else:
    result = url.packageName.importName

template pathToImport*(path: AbsoluteDir | string): string =
  importName(path)

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

template timer*(name: string; body: untyped) =
  let clock = epochTime()
  body
  debug name & " took " & $(epochTime() - clock)
