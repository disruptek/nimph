import std/strformat
import std/tables
import std/os
import std/options
import std/strutils

import compiler/idents
import compiler/nimconf
import compiler/options as compileropts
import compiler/pathutils

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
    filename = path.absolutePath.normalizedPath
    config = newConfigRef()
  if readConfigFile(filename.AbsoluteFile, cache, config):
    result = config.some

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
