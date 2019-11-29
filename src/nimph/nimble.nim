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

  RunNimbleOutput* = tuple
    output: string
    ok: bool

  NimbleMeta* = ref object
    js: JsonNode
    link: seq[string]

proc runNimble*(args: seq[string]; options: set[ProcessOption];
                nimbleDir = ""): RunNimbleOutput =
  ## run nimble
  var
    command = findExe("nimble")
    arguments = args
    opts = options
  if command == "":
    result = (output: "unable to find nimble in path", ok: false)
    warn result.output
    return

  when defined(debug):
    arguments = @["--verbose"].concat arguments
  when defined(debugNimble):
    arguments = @["--debug"].concat arguments

  if nimbleDir != "":
    # the ol' belt-and-suspenders approach to specifying nimbleDir
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
    result = (output: "", ok: process.waitForExit == 0)
  else:
    # the user wants to capture output
    command &= " " & quoteShellCommand(arguments)
    when defined(debug):
      debug command
    let
      (output, code) = execCmdEx(command, opts)
    result = (output: output, ok: code == 0)

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
  withinDirectory(path):
    let
      nimble = runNimble(@["dump", path], {poDaemon}, nimbleDir = nimbleDir)
    if not nimble.ok:
      result.why = "nimble execution failed"
      error nimble.output
      return

  let
    parsed = parseNimbleDump(nimble.output)
  if parsed.isNone:
    result.why = &"unable to parse `nimble dump` output"
    return
  result.table = parsed.get
  result.ok = true

proc hasUrl*(meta: NimbleMeta): bool =
  ## true if the metadata includes a url
  result = "url" in meta.js

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
  if not dirExists(path):
    warn &"{path} is not a directory; cannot write {nimbleMeta}"
    return
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
  if meta.js.kind == JObject:
    result = meta.js.getOrDefault("isLink").getBool

proc isValid*(meta: NimbleMeta): bool =
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
