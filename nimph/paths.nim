import std/strutils
import std/hashes
import std/os

import compiler/pathutils except toAbsoluteDir
export pathutils except toAbsoluteDir

# slash attack ///////////////////////////////////////////////////
when (NimMajor, NimMinor) >= (1, 1):
  template `///`*(a: string): string =
    ## ensure a trailing DirSep
    joinPath(a, $DirSep, "")
  template `///`*(a: AbsoluteDir): string =
    ## ensure a trailing DirSep
    `///`(a.string)
  template `//////`*(a: string | AbsoluteDir): string =
    ## ensure a trailing DirSep and a leading DirSep
    joinPath($DirSep, "", `///`(a), $DirSep, "")
else:
  template `///`*(a: string): string =
    ## ensure a trailing DirSep
    joinPath(a, "")
  template `///`*(a: AbsoluteDir): string =
    ## ensure a trailing DirSep
    `///`(a.string)
  template `//////`*(a: string | AbsoluteDir): string =
    ## ensure a trailing DirSep and a leading DirSep
    "" / "" / `///`(a) / ""

proc parentDir*(dir: AbsoluteDir): AbsoluteDir =
  result = dir / RelativeDir".."

proc parentDir*(dir: AbsoluteFile): AbsoluteDir =
  result = AbsoluteDir(dir) / RelativeDir".."

proc hash*(p: AnyPath): Hash = hash(p.string)

proc toAbsoluteDir*(s: string): AbsoluteDir =
  ## make very, very sure our directories are very, very well-formed
  var s = absolutePath(s).normalizedPath
  normalizePathEnd(s, trailingSep = true)
  result = pathutils.toAbsoluteDir(s)
  assert dirExists(result)
  assert endsWith($result, DirSep)

proc toAbsoluteFile*(s: string): AbsoluteFile =
  ## make very, very sure our paths are very, very well-formed
  var s = absolutePath(s, getCurrentDir()).normalizedPath
  result = toAbsolute(s, toAbsoluteDir(getCurrentDir()))
  assert fileExists(result)

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
