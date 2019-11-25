import std/nre
import std/strtabs
import std/strformat
import std/tables
import std/os
import std/options
import std/strutils
import std/algorithm

import compiler/idents
import compiler/nimconf
import compiler/options as compileropts
import compiler/pathutils
import compiler/condsyms

export compileropts
export nimconf

import npeg
import bump
import parsetoml

import nimph/spec

type
  ProjectCfgParsed* = object
    table*: TableRef[string, string]
    why*: string
    ok*: bool

  NimphConfig* = ref object
    toml: TomlValueRef

proc loadProjectCfg*(path: string): Option[ConfigRef] =
  ## use the compiler to parse a nim.cfg
  var
    cache = newIdentCache()
    filename = path.absolutePath
    config = newConfigRef()
  if readConfigFile(filename.AbsoluteFile, cache, config):
    result = config.some

proc loadAllCfgs*(dir = ""): ConfigRef =
  ## use the compiler to parse all the usual nim.cfgs;
  ## optionally change to the given (project?) directory first

  if dir != "":
    setCurrentDir(dir)

  result = newConfigRef()

  # define symbols such as, say, nimbabel;
  # this allows us to correctly parse conditions in nim.cfg(s)
  initDefines(result.symbols)

  # stuff the prefixDir so we load the compiler's config/nim.cfg
  # just like the compiler would if we were to invoke it directly
  let compiler = getCurrentCompilerExe()
  result.prefixDir = AbsoluteDir splitPath(compiler.parentDir).head

  # now follow the compiler process of loading the configs
  var cache = newIdentCache()
  loadConfigs(NimCfg.RelativeFile, cache, result)

proc appendConfig*(path: Target; config: string): bool =
  # make a temp file in an appropriate spot, with a significant name
  let
    temp = createTemporaryFile(path.package, dotNimble)
  debug &"writing {temp}"
  # but remember to remove the temp file later
  defer:
    debug &"removing {temp}"
    if not tryRemoveFile(temp):
      warn &"unable to remove temporary file `{temp}`"

  try:
    # if there's already a config, we'll start there
    if fileExists($path):
      debug &"copying {path} to {temp}"
      copyFile($path, temp)
  except Exception as e:
    discard e
    return

  block writing:
    # open our temp file for writing
    var
      writer = temp.open(fmAppend)
    # but remember to close the temp file in any event
    defer:
      writer.close

    # add our new content with a trailing newline
    writer.writeLine config

  # make sure the compiler can parse our new config
  let
    parsed = loadProjectCfg(temp)
  if parsed.isNone:
    return

  # copy the temp file over the original config
  try:
    debug &"copying {temp} over {path}"
    copyFile(temp, $path)
  except Exception as e:
    discard e
    return

  # it worked, thank $deity
  result = true

proc parseProjectCfg*(input: Target): ProjectCfgParsed =
  ## parse a .cfg for any lines we are entitled to mess with
  result = ProjectCfgParsed(ok: false, table: newTable[string, string]())
  var
    content: string
    table = result.table

  if not fileExists($input):
    result.why = &"config file {input} doesn't exist"
    return

  try:
    content = readFile($input)
  except:
    result.why = &"i couldn't read {input}"
    return

  let
    peggy = peg "document":
      nl <- ?'\r' * '\n'
      white <- {'\t', ' '}
      equals <- *white * {'=', ':'} * *white
      assignment <- +(1 - equals)
      comment <- '#' * *(1 - nl)
      strvalue <- '"' * *(1 - '"') * '"'
      endofval <- white | comment | nl
      anyvalue <- +(1 - endofval)
      hyphens <- '-'[0..2]
      ending <- *white * ?comment * nl
      nimblekeys <- i"nimblePath" | i"clearNimblePath" | i"noNimblePath"
      otherkeys <- i"path" | i"p" | i"define" | i"d"
      keys <- nimblekeys | otherkeys
      strsetting <- hyphens * >keys * equals * >strvalue * ending:
        table.add $1, unescape($2)
      anysetting <- hyphens * >keys * equals * >anyvalue * ending:
        table.add $1, $2
      toggle <- hyphens * >keys * ending:
        table.add $1, "it's enabled, okay?"
      line <- strsetting | anysetting | toggle | (*(1 - nl) * nl)
      document <- *line * !1
    parsed = peggy.match(content)
  try:
    result.ok = parsed.ok
    if result.ok:
      return
    result.why = parsed.repr
  except Exception as e:
    result.why = &"parse error in {input}: {e.msg}"

proc isEmpty*(config: NimphConfig): bool =
  result = config.toml.kind == TomlValueKind.None

proc newNimphConfig*(path: string): NimphConfig =
  ## instantiate a new nimph config using the given path
  result = NimphConfig()
  if not path.fileExists:
    result.toml = newTNull()
  else:
    result.toml = parseFile(path)

iterator packagePaths*(config: ConfigRef; exists = true): string =
  ## yield package paths from the configuration as /-terminated strings;
  ## if the exists flag is passed, then the path must also exist
  if config == nil:
    raise newException(Defect, "attempt to load search paths from nil config")
  let
    lib = config.libpath.string / ""
  var
    dedupe = newStringTable(modeStyleInsensitive)
  for path in config.searchPaths:
    let path = path.string / ""
    if path.startsWith(lib):
      continue
    dedupe[path] = ""
  for path in config.lazyPaths:
    let path = path.string / ""
    dedupe[path] = ""
  for path in dedupe.keys:
    if exists and not path.dirExists:
      continue
    yield path

iterator likelySearch*(config: ConfigRef; repo: string): string =
  ## yield /-terminated directory paths likely added via --path
  when defined(debug):
    if repo != repo.absolutePath:
      error &"repo {repo} wasn't normalized"

  for search in config.searchPaths.items:
    let search = search.string / "" # cast from AbsoluteDir
    # we don't care about library paths
    if search.startsWith(config.libpath.string / ""):
      continue

    # limit ourselves to the repo?
    when WhatHappensInVegas:
      if search.startsWith(repo):
        yield search
    else:
      yield search

iterator likelyLazy*(config: ConfigRef; repo: string; least = 0): string =
  ## yield /-terminated directory paths likely added via --nimblePath
  when defined(debug):
    if repo != repo.absolutePath:
      error &"repo {repo} wasn't normalized"

  # build a table of sightings of directories
  var popular = newCountTable[string]()
  for search in config.lazyPaths.items:
    let
      search = search.string / ""      # cast from AbsoluteDir
      parent = search.parentDir / ""   # ensure a trailing /
    popular.inc search
    if search != parent:               # silly: elide /
      if parent in popular:            # the parent has to have been added
        popular.inc parent

  # sort the table in descending order
  popular.sort

  # yield the directories that exist
  for search, count in popular.pairs:
    when false:
      # if the directory doesn't exist, ignore it
      if not dirExists(search):
        continue

    # maybe we can ignore unpopular paths
    if least > count:
      continue

    # limit ourselves to the repo?
    when WhatHappensInVegas:
      if search.startsWith(repo):
        yield search
    else:
      yield search

proc suggestNimbleDir*(config: ConfigRef; repo: string;
                       local = ""; global = ""): string =
  ## come up with a useful nimbleDir based upon what we find in the
  ## current configuration, the location of the project, and the provided
  ## suggestions for local or global package directories
  var
    local = local
    global = global

  block either:
    # if a local directory is suggested, see if we can confirm its use
    if local != "":
      assert local.endsWith(DirSep)
      for search in config.likelySearch(repo):
        if search.startsWith(local):
          result = local
          break either

    # otherwise, try to pick a global .nimble directory based upon lazy paths
    for search in config.likelyLazy(repo):
      #
      # FIXME: maybe we should look for some nimble debris?
      #
      if search.endsWith(PkgDir & DirSep):
        result = search.parentDir  # ie. the parent of pkgs
      else:
        result = search            # doesn't look like pkgs... just use it
      break either

    # otherwise, try to make one up using the suggestion
    if global == "":
      raise newException(IOError, "unable to guess global {dotNimble} directory")
    assert global.endsWith(DirSep)
    result = global
    break either

proc removeSearchPath*(nimcfg: Target; path: string): bool =
  ## try to remove a path from a nim.cfg; true if it was
  ## successful and false if any error prevented success
  let
    fn = $nimcfg
  if not fn.fileExists:
    return
  let
    content = fn.readFile
    cfg = fn.loadProjectCfg
    parsed = nimcfg.parseProjectCfg
  if cfg.isNone:
    error &"the compiler couldn't parse {nimcfg}"
    return

  if not parsed.ok:
    error &"i couldn't parse {nimcfg}:"
    error parsed.why
    return
  for key, value in parsed.table.pairs:
    if key.toLowerAscii notin ["p", "path", "nimblepath"]:
      continue
    if value.absolutePath / "" != path.absolutePath:
      continue
    let
      regexp = re("(*ANYCRLF)(?i)(?s)(-{0,2}" & key & "[:=]\"?" &
                  value & "\"?)\\s*")
      swapped = content.replace(regexp, "")
    if swapped != content:
      fn.writeFile(swapped)
      result = true

proc excludeSearchPath*(nimcfg: Target; path: string): bool =
  result = appendConfig(nimcfg, &"""--excludePath="{path}"""")

when false:
  iterator extantSearchPaths*(config: ConfigRef; repo: string; least = 0): string =
    if config == nil:
      raise newException(Defect, "attempt to load search paths from nil config")
    for path in config.likelySearch(repo):
      if dirExists(path):
        yield path
    for path in config.likelyLazy(repo, least = least):
      if dirExists(path):
        yield path
else:
  iterator extantSearchPaths*(config: ConfigRef;
                              repo: string; least = 0): string =
    for path in config.packagePaths(exists = true):
      yield path
