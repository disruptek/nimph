import std/strutils
import std/hashes
import std/os

import compiler/pathutils except toAbsoluteDir, toAbsolute
export pathutils except toAbsoluteDir, toAbsolute

#[

i wish i had impl this in the first place; it's been a pita and a source
of FUD.

i'm still wary of the (loose) `==`(x, y: AnyPath) from the compiler, but
at least our hash() routines shouldn't equate AbsoluteDir to AbsoluteFile.

]#

# slash attack ///////////////////////////////////////////////////
when (NimMajor, NimMinor) >= (1, 1):
  template `///`*(a: string): string {.deprecated.} =
    ## ensure a trailing DirSep
    joinPath(a, $DirSep, "")
  template `///`*(a: AbsoluteDir): string {.deprecated.} =
    ## ensure a trailing DirSep
    `///`(a.string)
  template `//////`*(a: string | AbsoluteDir): string {.deprecated.} =
    ## ensure a trailing DirSep and a leading DirSep
    joinPath($DirSep, "", `///`(a), $DirSep, "")
else:
  template `///`*(a: string): string {.deprecated.} =
    ## ensure a trailing DirSep
    joinPath(a, "")
  template `///`*(a: AbsoluteDir): string {.deprecated.} =
    ## ensure a trailing DirSep
    `///`(a.string)
  template `//////`*(a: string | AbsoluteDir): string {.deprecated.} =
    ## ensure a trailing DirSep and a leading DirSep
    "" / "" / `///`(a) / ""

proc parentDir*(dir: AbsoluteDir): AbsoluteDir =
  result = dir / RelativeDir".."
  assert not endsWith($result, DirSep)

proc parentDir*(dir: AbsoluteFile): AbsoluteDir =
  result = AbsoluteDir(dir).parentDir

proc hash*(p: AbsoluteDir): Hash =
  ## we force the hash to use a trailing DirSep on directories
  hash(normalizePathEnd(p.string, trailingSep = true))

proc hash*(p: AbsoluteFile): Hash =
  ## we force the hash to omit a trailing DirSep on files
  hash(normalizePathEnd(p.string, trailingSep = false))

proc toAbsoluteDir*(s: string): AbsoluteDir =
  ## make very, very sure our directories are very, very well-formed
  var s = absolutePath(s).normalizedPath
  normalizePathEnd(s, trailingSep = false)
  result = pathutils.toAbsoluteDir(s)
  assert dirExists(result), $result & " is missing"
  assert not endsWith($result, DirSep)

proc toAbsoluteFile*(s: string): AbsoluteFile =
  ## make very, very sure our file paths are very, very well-formed
  let dir = getCurrentDir().toAbsoluteDir
  var s = absolutePath(s, $dir).normalizedPath
  normalizePathEnd(s, trailingSep = false)
  result = pathutils.toAbsolute(s, dir)
  assert fileExists(result), $result & " is missing"

template withinDirectory*(path: AbsoluteDir; body: untyped): untyped =
  if not dirExists(path):
    raise newException(ValueError, $path & " is not a directory")
  let cwd = getCurrentDir()
  setCurrentDir($path)
  try:
    body
  finally:
    setCurrentDir(cwd)

template withinDirectory*(path: string; body: untyped): untyped =
  withinDirectory(path.toAbsoluteDir):
    body

proc endsWith*(path: AbsoluteDir; s: string): bool =
  result = parentDir(path) / RelativeDir(s) == path

proc endsWith*(path: AbsoluteFile; s: string): bool =
  result = parentDir(path) / RelativeFile(s) == path
