import std/strformat
import std/strutils
import std/sets
import std/options
import std/hashes
import std/strtabs
import std/tables

import bump
import gittyup

import nimph/spec
import nimph/version

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
    # someoid
    yield (release: newRelease($thing.oid, operator = Tag), thing: thing)
    # tag
    yield (release: newRelease(tag, operator = Tag), thing: thing)
    let parsed = parseVersionLoosely(tag)
    if parsed.isSome:
      # 3.1.4 or 3.1.*
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
  # when we have a commit, we'll add the hash of the commit and its oid string
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
