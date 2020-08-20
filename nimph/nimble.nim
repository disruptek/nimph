import std/uri
import std/json
import std/options
import std/strtabs
import std/strutils
import std/os
import std/osproc
import std/strformat

import npeg

import nimph/spec
import nimph/runner

type
  DumpResult* = object
    table*: StringTableRef
    why*: string
    ok*: bool

  NimbleMeta* = ref object
    js: JsonNode
    link: seq[string]

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
    try:
      writer.write($js)
      result = true
    finally:
      writer.close

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
