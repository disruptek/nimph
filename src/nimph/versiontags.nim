import std/strformat
import std/strutils
import std/sets
import std/options
import std/hashes
import std/strtabs
import std/tables

import bump

import nimph/spec
import nimph/version
import nimph/git

import nimph/group
export group

type
  VersionTags* = Group[Version, GitThing]

proc addName*(group: var VersionTags; mask: VersionMask; thing: GitThing) =
  ## add a versionmask to the group; note that this overwrites semvers
  for symbol in mask.semanticVersionStrings:
    group.imports[symbol] = $thing.oid

proc addName*(group: var VersionTags; version: Version; thing: GitThing) =
  ## add a version to the group; note that this overwrites semvers
  for symbol in version.semanticVersionStrings:
    group.imports[symbol] = $thing.oid

proc add*(group: var VersionTags; ver: Version; thing: GitThing) =
  ## add a version to the group; note that this overwrites semvers
  group.table.add ver, thing
  group.addName ver, thing

proc del*(group: var VersionTags; ver: Version) =
  ## remove a version from the group; note that this doesn't rebind semvers
  if group.table.hasKey(ver):
    group.delName $group.table[ver].oid
    group.table.del ver

proc `[]=`*(group: var VersionTags; ver: Version; thing: GitThing) =
  ## set a key to a single value
  group.del ver
  group.add ver, thing

proc `[]`*(group: VersionTags; ver: Version): var GitThing =
  ## get a git thing by version
  result = group.table[ver]

proc `[]`*(group: VersionTags; ver: VersionMask): var GitThing =
  ## get a git thing by versionmask
  for symbol in ver.semanticVersionStrings:
    if group.imports.hasKey(symbol):
      let
        complete = group.imports[symbol]
      result = group.table[parseDottedVersion(complete)]
      break

proc newVersionTags*(flags = defaultFlags): VersionTags =
  result = VersionTags(flags: flags)
  result.init(flags, mode = modeStyleInsensitive)

iterator richen*(tags: GitTagTable): tuple[release: Release; thing: GitThing] =
  ## yield releases that match the tags and the things they represent
  if tags == nil:
    raise newException(Defect, "are you lost?")
  # we're yielding #someoid, #tag, and whatever we can parse (version, mask)
  for tag, thing in tags.pairs:
    yield (release: newRelease($thing.oid, operator = Tag), thing: thing)
    yield (release: newRelease(tag, operator = Tag), thing: thing)
    let parsed = parseVersionLoosely(tag)
    if parsed.isSome:
      yield (release: parsed.get, thing: thing)

proc releaseHashes*(release: Release; head = ""): HashSet[Hash] =
  ## a set of hashes that should match valid values for the release
  result.incl hash(release)
  case release.kind:
  of Tag:
    # someNiceTag
    result.incl hash(release.reference)
    # perform the #head->oid substitution here
    if release.reference.toLowerAscii == "head" and head != "":
      result.incl head.hash
  of Wildlings:
    # 3, 3.1, 3.1.4 ... as available
    let effective = release.accepts.effectively
    for semantic in effective.semanticVersionStrings:
      result.incl hash(semantic)
    for semantic in release.accepts.semanticVersionStrings:
      result.incl hash(semantic)
    result.incl hash(effective)
    result.incl hash($effective)
  else:
    # 3, 3.1, 3.1.4 ... as available
    for semantic in release.version.semanticVersionStrings:
      result.incl hash(semantic)
    result.incl hash(release.version)
    result.incl hash($release.version)

proc releaseHashes*(release: Release; thing: GitThing; head = ""): HashSet[Hash] =
  ## a set of hashes that should match valid values for the release;
  ## the thing is presumed to be an associated tag/commit/etc and we
  ## should include useful hashes for it
  result = release.releaseHashes(head = head)
  result.incl hash(thing)
  result.incl hash($thing.oid)

iterator matches*(tags: GitTagTable; against: HashSet[Hash]):
  tuple[release: Release; thing: GitThing] =
  ## see if any of the releases in the tag table will match `against`
  ## if so, yield the release and thing
  if tags == nil:
    raise newException(Defect, "are you lost?")
  for release, thing in tags.richen:
    # compute hashes to match against
    var symbols = release.releaseHashes(thing)
    # see if we scored any matches
    if against.intersection(symbols).len != 0:
      yield (release: release, thing: thing)

when false:
  proc releaseHashes*(release: Release; head = "";
                      tags: GitTagTable = nil): HashSet[Hash] =
    ## a set of hashes that should match valid values for the release;
    ## for example, a version, a tag, or an oid.  it's the job of this
    ## procedure to peel any symbolic references using the head and tags,
    ## if they are available and provided.  it will match extremely
    ## loosely, against strings and versions parsed from tags.  beware.
    var
      symbol: string
    case release.kind:
    of Tag:
      symbol = release.reference
      # perform the #head->oid substitution here
      if symbol.toLowerAscii == "head" and head != "":
        result.incl head.hash
    of Wild, Caret, Tilde:
      let effective = release.effectively
      result.incl hash(effective)
      # matching against 3, 3.0, 3.0.0
      for semantic in effective.semanticVersionStrings:
        for match in tags.matches(semantic):
          result.incl match
      # matching against 3, 3.1, 3.1.4
      for semantic in release.semanticVersionStrings:
        for match in tags.matches(semantic):
          result.incl match
      symbol = $effective
    else:
      # matching against 3.1.4
      result.incl hash(release.version)
      symbol = $release.version

    # add some sanity
    if symbol == "":
      raise newException(Defect, "this is very much unwelcome")

    # this is a bit sketchy, since we're accepting a string literal
    result.incl symbol.hash

    # find any match of symbol->oid or symbol->tag
    # and add the associated key/value
    for match in tags.matches(symbol):
      result.incl match
