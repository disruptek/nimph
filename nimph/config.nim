import std/osproc
import std/json
import std/nre
import std/strtabs
import std/strformat
import std/tables
import std/os
import std/options
import std/strutils
import std/algorithm

import compiler/ast
import compiler/idents
import compiler/nimconf
import compiler/options as compileropts
import compiler/condsyms
import compiler/lineinfos

export compileropts
export nimconf

import npeg
import bump

import nimph/spec
import nimph/runner

when defined(debugPath):
  from std/sequtils import count

type
  ProjectCfgParsed* = object
    table*: TableRef[string, string]
    why*: string
    ok*: bool

  ConfigSection = enum
    LockerRooms = "lockfiles"

  NimphConfig* = ref object
    path: AbsoluteFile
    js: JsonNode

template excludeAllNotes(config: ConfigRef; n: typed) =
  config.notes.excl n
  when compiles(config.mainPackageNotes):
    config.mainPackageNotes.excl n
  when compiles(config.foreignPackageNotes):
    config.foreignPackageNotes.excl n

template setDefaultsForConfig(result: ConfigRef) =
  # maybe we should turn off configuration hints for these reads
  when defined(debugPath):
    result.notes.incl hintPath
  elif not defined(debug):
    excludeAllNotes(result, hintConf)
  excludeAllNotes(result, hintLineTooLong)

proc parseConfigFile*(path: AbsoluteFile): Option[ConfigRef] =
  ## use the compiler to parse a nim.cfg without changing to its directory
  var
    cache = newIdentCache()
    config = newConfigRef()

  # define symbols such as, say, nimbabel;
  # this allows us to correctly parse conditions in nim.cfg(s)
  initDefines(config.symbols)

  setDefaultsForConfig(config)

  if readConfigFile(path, cache, config):
    result = some(config)

when false:
  proc overlayConfig(config: var ConfigRef;
                     directory: string): bool {.deprecated.} =
    ## true if new config data was added to the env
    withinDirectory(directory):
      var
        priorProjectPath = config.projectPath
      let
        nextProjectPath = AbsoluteDir getCurrentDir()
        filename = nextProjectPath.string / NimCfg

      block complete:
        # do not overlay above the current config
        if nextProjectPath == priorProjectPath:
          break complete

        # if there's no config file, we're done
        result = filename.fileExists
        if not result:
          break complete

        try:
          # set the new project path for substitution purposes
          config.projectPath = nextProjectPath

          var cache = newIdentCache()
          result = readConfigFile(filename.AbsoluteFile, cache, config)

          if result:
            # this config is now authoritative, so force the project path
            priorProjectPath = nextProjectPath
          else:
            let emsg = &"unable to read config in {nextProjectPath}" # noqa
            warn emsg
        finally:
          # remember to reset the config's project path
          config.projectPath = priorProjectPath

# a global that we set just once per invocation
var
  compilerPrefixDir: AbsoluteDir

proc findPrefixDir(): AbsoluteDir =
  ## determine the prefix directory for the current compiler
  if compilerPrefixDir.isEmpty:
    debug "find prefix"
    let
      compiler = runSomething("nim",
                   @["--hints:off",
                     "--dump.format:json", "dump", "dummy"], {poDaemon})
    if not compiler.ok:
      warn "couldn't run the compiler to determine its location"
      raise newException(OSError, "cannot find a nim compiler")
    try:
      let
        js = parseJson(compiler.output)
      compilerPrefixDir = AbsoluteDir js["prefixdir"].getStr
    except JsonParsingError as e:
      warn "`nim dump` json parse error: " & e.msg
      raise
    except KeyError:
      warn "couldn't parse the prefix directory from `nim dump` output"
      compilerPrefixDir = AbsoluteDir parentDir(findExe"nim")
    debug "found prefix"
  result = compilerPrefixDir

proc loadAllCfgs*(directory: AbsoluteDir): ConfigRef =
  ## use the compiler to parse all the usual nim.cfgs;
  ## optionally change to the given (project?) directory first

  result = newConfigRef()

  # define symbols such as, say, nimbabel;
  # this allows us to correctly parse conditions in nim.cfg(s)
  initDefines(result.symbols)

  setDefaultsForConfig(result)

  # stuff the prefixDir so we load the compiler's config/nim.cfg
  # just like the compiler would if we were to invoke it directly
  result.prefixDir = findPrefixDir()

  withinDirectory(directory):
    # stuff the current directory as the project path
    result.projectPath = getCurrentDir().toAbsoluteDir

    # now follow the compiler process of loading the configs
    var cache = newIdentCache()

    # thanks, araq
    when (NimMajor, NimMinor) >= (1, 5):
      var idgen = IdGenerator(module: 0.int32, item: 0.int32)
      loadConfigs(NimCfg.RelativeFile, cache, result, idgen)
    else:
      loadConfigs(NimCfg.RelativeFile, cache, result)

  when defined(debugPath):
    debug "loaded", result.searchPaths.len, "search paths"
    debug "loaded", result.lazyPaths.len, "lazy paths"
    for path in items(result.lazyPaths):
      debug "\t" & $path
    for path in items(result.lazyPaths):
      if result.lazyPaths.count(path) > 1:
        raise newException(Defect, "duplicate lazy path: " & $path)

proc appendConfig*(path: AbsoluteFile; config: string): bool =
  # make a temp file in an appropriate spot, with a significant name
  let
    temp = createTemporaryFile(lastPathPart($path), dotNimble).absolutePath
  debug &"writing {temp}"

  try:
    block complete:
      try:
        # if there's already a config, we'll start there
        if fileExists($path):
          debug &"copying {path} to {temp}"
          copyFile($path, temp)
      except Exception as e:
        warn &"unable make a copy of {path} to to {temp}: {e.msg}"
        break complete

      block writing:
        # open our temp file for writing
        var
          writer = temp.open(fmAppend)
        try:
          # add our new content with a trailing newline
          writer.writeLine "# added by nimph:\n" & config
        finally:
          # remember to close the temp file in any event
          writer.close

      # make sure the compiler can parse our new config
      if parseConfigFile(temp.AbsoluteFile).isNone:
        break complete

      # copy the temp file over the original config
      try:
        debug &"copying {temp} over {path}"
        copyFile(temp, $path)
      except Exception as e:
        warn &"unable make a copy of {temp} to to {path}: {e.msg}"
        break complete

      # it worked, thank $deity
      result = true
  finally:
    debug &"removing {temp}"
    if not tryRemoveFile(temp):
      warn &"unable to remove temporary file `{temp}`"

proc parseProjectCfg*(input: AbsoluteFile): ProjectCfgParsed =
  ## parse a .cfg for any lines we are entitled to mess with
  result = ProjectCfgParsed(ok: false, table: newTable[string, string]())
  var
    table = result.table

  block success:
    if not fileExists($input):
      result.why = &"config file {input} doesn't exist"
      break success

    var
      content = readFile($input)
    if not content.endsWith("\n"):
      content &= "\n"
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
        break success
      result.why = parsed.repr
    except Exception as e:
      result.why = &"parse error in {input}: {e.msg}"

proc isEmpty*(config: NimphConfig): bool =
  result = config.js.kind == JNull

proc newNimphConfig*(path: AbsoluteFile): NimphConfig =
  ## instantiate a new nimph config using the given path
  result = NimphConfig(path: path)
  if not fileExists(result.path):
    result.js = newJNull()
  else:
    try:
      result.js = parseFile($path)
    except Exception as e:
      error &"unable to parse {path}:"
      error e.msg

template isStdLib*(config: ConfigRef; path: string): bool =
  path.startsWith(///config.libpath)

template isStdlib*(config: ConfigRef; path: AbsoluteDir): bool =
  config.isStdLib($path)

iterator likelySearch*(config: ConfigRef; libsToo: bool): AbsoluteDir =
  ## yield /-terminated directory paths likely added via --path
  for search in items(config.searchPaths):
    # we don't care about library paths
    if not libsToo and config.isStdLib(search):
      continue
    yield search

iterator likelySearch*(config: ConfigRef; repo: AbsoluteDir;
                       libsToo: bool): AbsoluteDir =
  ## yield absolute directory paths likely added via --path
  for search in config.likelySearch(libsToo = libsToo):
    # limit ourselves to the repo?
    when WhatHappensInVegas:
      if startsWith($search, $repo):
        yield search
    else:
      yield search

iterator likelyLazy*(config: ConfigRef; least = 0): AbsoluteDir =
  ## yield absolute directory paths likely added via --nimblePath
  # build a table of sightings of directories
  var popular = newCountTable[AbsoluteDir]()
  for search in items(config.lazyPaths):
    let
      parent = parentDir(search)
    when defined(debugPath):
      if search in popular:
        raise newException(Defect, "duplicate lazy path: " & $search)
    if search notin popular:
      popular.inc search
    if search != parent:               # silly: elide /
      if parent in popular:            # the parent has to have been added
        popular.inc parent

  # sort the table in descending order
  popular.sort

  # yield the directories that exist
  for search, count in popular.pairs:
    # maybe we can ignore unpopular paths
    if least > count:
      continue
    yield search

iterator likelyLazy*(config: ConfigRef; repo: AbsoluteDir;
                     least = 0): AbsoluteDir =
  ## yield absolute directory paths likely added via --nimblePath
  for search in config.likelyLazy(least = least):
    # limit ourselves to the repo?
    when WhatHappensInVegas:
      if startsWith($search, $repo):
        yield search
    else:
      yield search

iterator packagePaths*(config: ConfigRef; exists = true): AbsoluteDir =
  ## yield package paths from the configuration as absolute directories;
  ## if the exists flag is passed, then the path must also exist.
  ## this should closely mimic the compiler's search

  # the method by which we de-dupe paths
  const mode =
    when FilesystemCaseSensitive:
      modeCaseSensitive
    else:
      modeCaseInsensitive
  var
    paths: seq[AbsoluteDir]
    dedupe = newStringTable(mode)

  template addOne(p: AbsoluteDir) =
    if $path in dedupe:
      continue
    dedupe[$path] = ""
    paths.add path

  if config == nil:
    raise newException(Defect, "attempt to load search paths from nil config")

  for path in config.searchPaths:
    addOne(path)
  for path in config.lazyPaths:
    addOne(path)
  when defined(debugPath):
    debug &"package directory count: {paths.len}"

  # finally, emit paths as appropriate
  for path in items(paths):
    if exists and not dirExists(path):
      continue
    yield path

proc suggestNimbleDir*(config: ConfigRef; local = ""; global = ""): AbsoluteDir =
  ## come up with a useful nimbleDir based upon what we find in the
  ## current configuration, the location of the project, and the provided
  ## suggestions for local or global package directories
  var
    local = local
    global = global

  block either:
    # if a local directory is suggested, see if we can confirm its use
    if local != "" and dirExists(local):
      local = ///local
      assert local.endsWith(DirSep)
      for search in config.likelySearch(libsToo = false):
        if startsWith($search, local):
          # we've got a path statement pointing to a local path,
          # so let's assume that the suggested local path is legit
          result = toAbsoluteDir(local)
          break either

    # nim 1.1.1 supports nimblePath storage in the config;
    # we follow a "standard" that we expect Nimble to use,
    # too, wherein the last-added --nimblePath wins
    when (NimMajor, NimMinor) >= (1, 1):
      if len(config.nimblePaths) > 0:
        result = config.nimblePaths[0]
        break either

    # otherwise, try to pick a global .nimble directory based upon lazy paths
    for search in config.likelyLazy:
      if endsWith($search, PkgDir & DirSep):
        result = parentDir(search) # ie. the parent of pkgs
      else:
        result = search            # doesn't look like pkgs... just use it
      break either

    # otherwise, try to make one up using the suggestion
    if global == "":
      raise newException(IOError, "can't guess global {dotNimble} directory")
    global = ///global
    assert endsWith(global, DirSep)
    result = toAbsoluteDir(global)
    break either

iterator pathSubsFor(config: ConfigRef; sub: string;
                     conf: AbsoluteDir): AbsoluteDir =
  ## a convenience to work around the compiler's broken pathSubs; the `conf`
  ## string represents the path to the "current" configuration file
  block:
    if sub.toLowerAscii notin ["nimbledir", "nimblepath"]:
      yield config.pathSubs(&"${sub}", $conf).toAbsoluteDir
      break

    when declaredInScope nimbleSubs:
      for path in config.nimbleSubs(&"${sub}"):
        yield path.toAbsoluteDir
    else:
      # we have to pick the first lazy path because that's what Nimble does
      for search in config.lazyPaths:
        if endsWith($search, PkgDir & DirSep):
          yield parentDir(search)
        else:
          yield search
        break

iterator pathSubstitutions(config: ConfigRef; path: AbsoluteDir;
                           conf: AbsoluteDir; write: bool): string =
  ## compute the possible path substitions, including the original path
  const
    readSubs = @["nimcache", "config", "nimbledir", "nimblepath",
                 "projectdir", "projectpath", "lib", "nim", "home"]
    writeSubs =
      when writeNimbleDirPaths:
        readSubs
      else:
        @["nimcache", "config", "projectdir", "lib", "nim", "home"]
  var
    matchedPath = false
  when defined(debug):
    if not conf.dirExists:
      raise newException(Defect, "passed a config file and not its path")
  let
    conf = if conf.dirExists: conf else: conf.parentDir
    substitutions = if write: writeSubs else: readSubs

  for sub in items(substitutions):
    for attempt in config.pathSubsFor(sub, conf):
      # ignore any empty substitutions
      if $attempt == "/":
        continue
      # note if any substitution matches the path
      if path == attempt:
        matchedPath = true
      if startsWith($path, $attempt):
        yield replace($path, $attempt, ///fmt"${sub}")
  # if a substitution matches the path, don't yield it at the end
  if not matchedPath:
    yield $path

proc bestPathSubstitution(config: ConfigRef; path: AbsoluteDir;
                          conf: AbsoluteDir): string =
  ## compute the best path substitution, if any
  block found:
    for sub in config.pathSubstitutions(path, conf, write = true):
      result = sub
      break found
    result = $path

proc removeSearchPath*(config: ConfigRef; nimcfg: AbsoluteFile;
                       path: AbsoluteDir): bool =
  ## try to remove a path from a nim.cfg; true if it was
  ## successful and false if any error prevented success
  block complete:
    # well, that was easy
    if not fileExists(nimcfg):
      break complete

    # make sure we can parse the configuration with the compiler
    if parseConfigFile(nimcfg).isNone:
      error &"the compiler couldn't parse {nimcfg}"
      break complete

    # make sure we can parse the configuration using our "naive" npeg parser
    let
      parsed = parseProjectCfg(nimcfg)
    if not parsed.ok:
      error &"could not parse {nimcfg} naïvely:"
      error parsed.why
      break complete

    var
      content = readFile($nimcfg)
    # iterate over the entries we parsed naively,
    for key, value in parsed.table.pairs:
      # skipping anything that it's a path,
      if key.toLowerAscii notin ["p", "path", "nimblepath"]:
        continue
      # and perform substitutions to see if one might match the value
      # we are trying to remove; the write flag is false so that we'll
      # use any $nimbleDir substitutions available to us, if possible
      for sub in config.pathSubstitutions(path, parentDir(nimcfg), write = false):
        if sub notin [value, ///value]:
          continue
        # perform a regexp substition to remove the entry from the content
        let
          regexp = re("(*ANYCRLF)(?i)(?s)(-{0,2}" & key.escapeRe &
                      "[:=]\"?" & value.escapeRe & "/?\"?)\\s*")
          swapped = content.replace(regexp, "")
        # if that didn't work, cry a bit and move on
        if swapped == content:
          notice &"failed regex edit to remove path `{value}`"
          continue
        # make sure we search the new content next time through the loop
        content = swapped
        result = true
        # keep performing more substitutions

    # finally, write the edited content
    writeFile(nimcfg, content)

proc addSearchPath*(config: ConfigRef; nimcfg: AbsoluteFile;
                    path: AbsoluteDir): bool =
  ## add the given path to the given config file, using the compiler's
  ## configuration as input to determine the best path substitution
  let
    best = config.bestPathSubstitution(path, parentDir(nimcfg))
  result = appendConfig(nimcfg, &"""--path="{best}"""")

proc excludeSearchPath*(config: ConfigRef; nimcfg: AbsoluteFile;
                        path: AbsoluteDir): bool =
  ## add an exclusion for the given path to the given config file, using the
  ## compiler's configuration as input to determine the best path substitution
  let
    best = config.bestPathSubstitution(path, parentDir(nimcfg))
  result = appendConfig(nimcfg, &"""--excludePath="{best}"""")

iterator extantSearchPaths*(config: ConfigRef; least = 0): AbsoluteDir =
  ## yield existing search paths from the configuration as /-terminated strings;
  ## this will yield library paths and nimblePaths with at least `least` uses
  if config == nil:
    raise newException(Defect, "attempt to load search paths from nil config")
  # path statements
  for path in config.likelySearch(libsToo = true):
    if dirExists(path):
      yield path
  # nimblePath statements
  for path in config.likelyLazy(least = least):
    if dirExists(path):
      yield path

proc addLockerRoom*(config: var NimphConfig; name: string; room: JsonNode) =
  ## add the named lockfile (in json form) to the configuration file
  if config.isEmpty:
    config.js = newJObject()
  if $LockerRooms notin config.js:
    config.js[$LockerRooms] = newJObject()
  config.js[$LockerRooms][name] = room
  writeFile(config.path, config.js.pretty)

proc getAllLockerRooms*(config: NimphConfig): JsonNode =
  ## retrieve a JObject holding all lockfiles in the configuration file
  block found:
    if not config.isEmpty:
      if $LockerRooms in config.js:
        result = config.js[$LockerRooms]
        break
    result = newJObject()

proc getLockerRoom*(config: NimphConfig; name: string): JsonNode =
  ## retrieve the named lockfile (or JNull) from the configuration
  let
    rooms = config.getAllLockerRooms
  if name in rooms:
    result = rooms[name]
  else:
    result = newJNull()
