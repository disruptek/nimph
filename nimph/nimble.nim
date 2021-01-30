import std/uri
import std/json
import std/options
import std/strtabs
import std/strutils
import std/os
import std/osproc
import std/strformat

import npeg
import bump

import ups/runner
import ups/paths

import nimph/spec

type
  DumpResult* = object
    table*: StringTableRef
    why*: string
    ok*: bool

  NimbleMeta* = ref object
    js: JsonNode
    link: seq[string]

  LinkedSearchResult* = ref object
    via: LinkedSearchResult
    source: string
    search: SearchResult

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

proc fetchNimbleDump*(path: AbsoluteDir;
                      nimbleDir = AbsoluteDir""): DumpResult =
  ## parse nimble dump output into a string table
  result = DumpResult(ok: false)
  withinDirectory(path):
    let
      nimble = runSomething("nimble", @["dump", $path], {poDaemon},
                            nimbleDir = nimbleDir)

    result.ok = nimble.ok
    if result.ok:
      let
        parsed = parseNimbleDump(nimble.output)
      result.ok = parsed.isSome
      if result.ok:
        result.table = get(parsed)
      else:
        result.why = &"unable to parse `nimble dump` output"
    else:
      result.why = "nimble execution failed"
      if nimble.output.len > 0:
        error nimble.output

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

proc writeNimbleMeta*(path: AbsoluteDir; url: Uri; revision: string): bool =
  ## try to write a new nimblemeta.json
  block complete:
    if not dirExists(path):
      warn &"{path} is not a directory; cannot write {nimbleMeta}"
      break complete
    var
      revision = revision
    removePrefix(revision, {'#'})
    var
      metafn = path / RelativeFile(nimbleMeta)
      js = %* {
        "url": $url,
        "vcsRevision": revision,
        "files": @[],
        "binaries": @[],
        "isLink": false,
      }
      writer = open($metafn, fmWrite)
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

proc fetchNimbleMeta*(path: AbsoluteDir): NimbleMeta =
  ## parse the nimblemeta.json file if it exists
  result = NimbleMeta(js: newJObject())
  let
    metafn = path / RelativeFile(nimbleMeta)
  try:
    if fileExists(metafn):
      let
        content = readFile($metafn)
      result.js = parseJson(content)
  except Exception as e:
    discard e # noqa
    warn &"error while trying to parse {nimbleMeta}: {e.msg}"

proc parseNimbleLink*(path: string): tuple[nimble: string; source: string] =
  ## parse a dotNimbleLink file into its constituent components
  let
    lines = readFile(path).splitLines
  if lines.len != 2:
    raise newException(ValueError, "malformed " & path)
  result = (nimble: lines[0], source: lines[1])

proc linkedFindTarget*(dir: AbsoluteDir; target = ""; nimToo = false;
                       ascend = true): LinkedSearchResult =
  ## recurse through .nimble-link files to find the .nimble
  var
    extensions = @[dotNimble, dotNimbleLink]
  if nimToo:
    extensions = @["".addFileExt("nim")] & extensions

  # perform the search with our cleverly-constructed extensions
  result = LinkedSearchResult()
  result.search = findTarget($dir, extensions = extensions,
                             target = target, ascend = ascend)

  # if we found nothing, or we found a dotNimble, then we're done
  let found = result.search.found
  if found.isNone or found.get.ext != dotNimbleLink:
    return

  # now we need to parse this dotNimbleLink and recurse on the target
  try:
    let parsed = parseNimbleLink($get(found))
    if fileExists(parsed.nimble):
      result.source = parsed.source
    let parent = parentDir(parsed.nimble).toAbsoluteDir
    # specify the path to the .nimble and the .nimble filename itself
    var recursed = linkedFindTarget(parent, nimToo = nimToo,
                                    target = parsed.nimble.extractFilename,
                                    ascend = ascend)
    # if the recursion was successful, add ourselves to the chain and return
    if recursed.search.found.isSome:
      recursed.via = result
      return recursed

    # a failure mode yielding a useful explanation
    result.search.message = &"{found.get} didn't lead to a {dotNimble}"
  except ValueError as e:
    # a failure mode yielding a less-useful explanation
    result.search.message = e.msg

  # critically, set the search to none because ultimately, we found nothing
  result.search.found = none(Target)

proc importName*(target: Target): ImportName =
  result = target.package.importName

proc importName*(linked: LinkedSearchResult): ImportName =
  ## a uniform name usable in code for imports
  if linked.via != nil:
    result = linked.via.importName
  else:
    # if found isn't populated, we SHOULD crash here
    result = linked.search.found.get.importName
