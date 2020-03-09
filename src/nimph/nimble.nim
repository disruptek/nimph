import std/uri
import std/json
import std/options
import std/strtabs
import std/strutils
import std/os
import std/osproc
import std/strformat
import std/sequtils

import npeg

import nimph/spec

type
  DumpResult* = object
    table*: StringTableRef
    why*: string
    ok*: bool

  NimbleOutput* = object
    arguments*: seq[string]
    output*: string
    ok*: bool

  NimbleMeta* = ref object
    js: JsonNode
    link: seq[string]

proc stripPkgs*(nimbledir: string): string =
  ## omit and trailing /PkgDir from a path
  result = nimbleDir / $DirSep
  # the only way this is a problem is if the user stores deps in pkgs/pkgs,
  # but we can remove this hack once we have nimblePaths in nim-1.0 ...
  if result.endsWith($DirSep / PkgDir / $DirSep):
    result = result.parentDir / $DirSep

proc runSomething*(exe: string; args: seq[string]; options: set[ProcessOption];
                   nimbleDir = ""): NimbleOutput =
  ## run a program with arguments, perhaps with a particular nimbleDir
  var
    command = findExe(exe)
    arguments = args
    opts = options
  block ran:
    if command == "":
      result = NimbleOutput(output: &"unable to find {exe} in path")
      warn result.output
      break ran

    if exe == "nimble":
      when defined(debug):
        arguments = @["--verbose"].concat arguments
      when defined(debugNimble):
        arguments = @["--debug"].concat arguments

    if nimbleDir != "":
      # we want to strip any trailing PkgDir arriving from elsewhere...
      var nimbleDir = nimbleDir.stripPkgs
      if not nimbleDir.dirExists:
        let emsg = &"{nimbleDir} is missing; can't run {exe}" # noqa
        raise newException(IOError, emsg)
      # the ol' belt-and-suspenders approach to specifying nimbleDir
      if exe == "nimble":
        arguments = @["--nimbleDir=" & nimbleDir].concat arguments
      putEnv("NIMBLE_DIR", nimbleDir)

    if poParentStreams in opts or poInteractive in opts:
      # sorry; i just find this easier to read than union()
      opts.incl poInteractive
      opts.incl poParentStreams
      # the user wants interactivity
      when defined(debug):
        debug command, arguments.join(" ")
      let
        process = startProcess(command, args = arguments, options = opts)
      result = NimbleOutput(ok: process.waitForExit == 0)
    else:
      # the user wants to capture output
      command &= " " & quoteShellCommand(arguments)
      when defined(debug):
        debug command
      let
        (output, code) = execCmdEx(command, opts)
      result = NimbleOutput(output: output, ok: code == 0)

    # for utility, also return the arguments we used
    result.arguments = arguments

    # a failure is worth noticing
    if not result.ok:
      notice exe & " " & arguments.join(" ")

proc parseNimbleDump*(input: string): Option[StringTableRef] =
  ## parse output from `nimble dump`
  var
    table = newStringTable(modeStyleInsensitive)
  let
    peggy = peg "document":
      nl <- ?'\r' * '\n'
      white <- {'\t', ' '}
      key <- +(1 - ':')
      value <- '"' * *(1 - '"') * '"'
      errline <- white * >*(1 - nl) * +nl:
        warn $1
      line <- >key * ':' * +white * >value * +nl:
        table[$1] = unescape($2)
      anyline <- line | errline
      document <- +anyline * !1
    parsed = peggy.match(input)
  if parsed.ok:
    result = table.some

proc fetchNimbleDump*(path: string; nimbleDir = ""): DumpResult =
  ## parse nimble dump output into a string table
  result = DumpResult(ok: false)
  block fetched:
    withinDirectory(path):
      let
        nimble = runSomething("nimble",
                              @["dump", path], {poDaemon}, nimbleDir = nimbleDir)
      if not nimble.ok:
        result.why = "nimble execution failed"
        if nimble.output.len > 0:
          error nimble.output
        break fetched

    let
      parsed = parseNimbleDump(nimble.output)
    if parsed.isNone:
      result.why = &"unable to parse `nimble dump` output"
      break fetched
    result.table = parsed.get
    result.ok = true

proc hasUrl*(meta: NimbleMeta): bool =
  ## true if the metadata includes a url
  result = "url" in meta.js
  result = result and meta.js["url"].kind == JString
  result = result and meta.js["url"].getStr != ""

proc url*(meta: NimbleMeta): Uri =
  ## return the url associated with the package
  if not meta.hasUrl:
    raise newException(ValueError, "url not available")
  result = parseUri(meta.js["url"].getStr)
  if result.anchor == "":
    if "vcsRevision" in meta.js:
      result.anchor = meta.js["vcsRevision"].getStr
      removePrefix(result.anchor, {'#'})

proc writeNimbleMeta*(path: string; url: Uri; revision: string): bool =
  ## try to write a new nimblemeta.json
  block complete:
    if not dirExists(path):
      warn &"{path} is not a directory; cannot write {nimbleMeta}"
      break complete
    var
      revision = revision
    removePrefix(revision, {'#'})
    var
      js = %* {
        "url": $url,
        "vcsRevision": revision,
        "files": @[],
        "binaries": @[],
        "isLink": false,
      }
      writer = open(path / nimbleMeta, fmWrite)
    defer:
      writer.close
    writer.write($js)
    result = true

proc isLink*(meta: NimbleMeta): bool =
  ## true if the metadata says it's a link
  if meta.js.kind == JObject:
    result = meta.js.getOrDefault("isLink").getBool

proc isValid*(meta: NimbleMeta): bool =
  ## true if the metadata appears to hold some data
  result = meta.js != nil and meta.js.len > 0

proc fetchNimbleMeta*(path: string): NimbleMeta =
  ## parse the nimblemeta.json file if it exists
  result = NimbleMeta(js: newJObject())
  let
    metafn = path / nimbleMeta
  try:
    if metafn.fileExists:
      let
        content = readFile(metafn)
      result.js = parseJson(content)
  except Exception as e:
    discard e # noqa
    warn &"error while trying to parse {nimbleMeta}: {e.msg}"
