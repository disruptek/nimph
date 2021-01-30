import std/json
import std/strutils
import std/logging

import ups/config
import ups/paths

type
  NimphConfig* = ref object
    path: AbsoluteFile
    js: JsonNode

proc isEmpty*(config: NimphConfig): bool =
  result = config.js.kind == JNull

proc newNimphConfig*(path: AbsoluteFile): NimphConfig =
  ## instantiate a new nimph config using the given path
  result = NimphConfig(path: path)
  if not fileExists result.path:
    result.js = newJNull()
  else:
    try:
      result.js = parseFile $path
    except Exception as e:
      error "unable to parse $#: " % [ $path ]
      error e.msg

proc addLockerRoom*(config: var NimphConfig; name: string; room: JsonNode) =
  ## add the named lockfile (in json form) to the configuration file
  addLockerRoom(config.js, name, room)

proc getAllLockerRooms*(config: NimphConfig): JsonNode =
  ## retrieve a JObject holding all lockfiles in the configuration file
  result = getAllLockerRooms config.js

proc getLockerRoom*(config: NimphConfig; name: string): JsonNode =
  ## retrieve the named lockfile (or JNull) from the configuration
  result = getLockerRoom(config.js, name)

when false:
  import compiler/nimconf
  export nimconf

  proc overlayConfig(config: var ConfigRef;
                     directory: string): bool {.deprecated.} =
    ## true if new config data was added to the env
    withinDirectory(directory):
      var
        priorProjectPath = config.projectPath
      let
        nextProjectPath = getCurrentDir().toAbsoluteDir
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
