import std/hashes
import std/os
import std/strtabs
import std/tables
from std/sequtils import toSeq
import std/uri except Url

export strtabs.StringTableMode

import gittyup

import nimph/spec
import nimph/paths
import nimph/requirement
import nimph/version

##[

these are just collection concepts that assert a little more convenience.

a Group is a collection that holds items that may be indexed by some
stable index. deletion should preserve order whenever possible. singleton
iteration yields the original item. pairwise iteration also yields unique
indices that can be used for deletion.

a FlaggedGroup additionally has a flags field/proc that yields set[Flag];
this is used to alter group operations to, for example, silently omit
errors and warnings (Quiet) or prevent destructive modification (DryRun).

]##

type
  Group[T] = concept g, var w
    add(w, T)                # duplicate indices are accepted
    incl(w, T)               # do nothing if T's index exists
    excl(w, T)               # do nothing if T's index does not exist
    del(w, T)                # delete only T
    # the rest of these are really trivial expectations we want to meet
    contains(g, T) is bool
    hash(T)
    len(g) is Ordinal
    for item in items(g):
      item is T
    for index, item in pairs(g):
      item is T
      del(w, index)

  FlaggedGroup*[T] = concept g, var w ##
    ## this is a container that holds a Group and some contextual
    ## flags that can affect the Group's operation
    g.group is Group[T]
    w.group is Group[T]
    g.flags is set[Flag]

  IdentityGroup*[T] = concept g, var w ##
    ## an IdentityGroup lets you test for membership via Identity,
    ## PackageName, or Uri
    g is Group[T]
    w is Group[T]
    contains(g, Identity) is bool
    contains(g, PackageName) is bool
    contains(g, Uri) is bool
    `[]`(g, PackageName) is T   # indexing by identity types
    `[]`(g, Uri) is T           # indexing by identity types
    `[]`(g, Identity) is T      # indexing by identity types

when false:
  type ImportGroup*[T] = concept g, var w ##
    ## an ImportGroup lets you test for membership via ImportName
    g is Group[T]
    w is Group[T]
    importName(T) is ImportName
    contains(g, ImportName) is bool
    excl(w, ImportName)         # delete any T that yields ImportName
    `[]`(g, ImportName) is T    # index by ImportName

  type GitGroup*[T] = concept g, var w ##
    ## a GitGroup is designed to hold Git objects like tags, references,
    ## commits, and so on
    g is Group[T]
    w is Group[T]
    oid(T) is GitOid
    contains(g, GitOid) is bool
    excl(w, GitOid)             # delete any T that yields GitOid
    `[]`(g, GitOid) is T        # index by GitOid
    free(T)                     # ensure we can free the group

  type ReleaseGroup*[T] = concept g, var w ##
    ## a ReleaseGroup lets you test for membership via Release,
    ## (likely Version, Tag, and such as well)
    g is Group[T]
    w is Group[T]
    contains(g, Release) is bool
    for item in g[Release]:     # indexing iteration by Release
      item is T

proc contains*[T](group: Group[T]; value: T): bool =
  for item in items(group):
    result = item == value
    if result:
      break

proc incl*[T](group: Group[T]; value: T) =
  if value notin group:
    group.add value

proc excl*[T](group: Group[T]; value: T) =
  if value in group:
    group.del value

proc hash*(group: Group): Hash =
  var h: Hash = 0
  for item in items(group):
    h = h !& hash(item)
  result = !$h

proc contains*(flagged: FlaggedGroup; flags: set[Flag]): bool =
  flags <= flagged.flags

proc contains*(flagged: FlaggedGroup; flag: Flag): bool =
  flag in flagged.flags

proc hash*(flagged: FlaggedGroup): Hash =
  hash(flagged.group)

proc add*[T](flagged: FlaggedGroup[T]; value: T) =
  flagged.group.add value

proc del*[T](flagged: FlaggedGroup[T]; value: T) =
  flagged.group.del value

proc incl*[T](flagged: FlaggedGroup[T]; value: T) =
  flagged.group.incl value

proc excl*[T](flagged: FlaggedGroup[T]; value: T) =
  flagged.group.excl value

proc contains*[T](flagged: FlaggedGroup[T]; value: T): bool =
  value in flagged.group

iterator reversed*[T](group: Group[T]): T =
  ## yield values in reverse order
  let elems = toSeq items(group)
  for index in countDown(elems.high, elems.low):
    yield elems[index]

proc clear*(group: Group) =
  ## clear the group without any other disruption
  while len(group) > 0:
    for item in items(group):
      group.del item
      break

#
# now our customized implementations...
#
when false:
  # left for impl
  proc contains*(group: ImportGroup; name: ImportName): bool =
    for item in items(group):
      result = item.importName == name
      if result:
        break

  proc excl*(group: ImportGroup; name: ImportName) =
    while name in group:
      for item in items(group):
        if item.importName == name:
          group.del item
          break

  proc `[]`*[T](group: ImportGroup[T]; name: ImportName): T =
    block found:
      for item in items(group):
        if item.importName == name:
          result = item
          break found
      raise newException(KeyError, "not found")

  proc free*(group: GitGroup) =
    while len(group) > 0:
      for item in items(group):
        group.del item
        break


  proc contains*(group: IdentityGroup; identity: Identity): bool =
    for item in items(group):
      result = item == identity
      if result:
        break

  proc contains*(group: IdentityGroup; name: PackageName): bool =
    result = newIdentity(name) in group

  proc contains*(group: IdentityGroup; url: Uri): bool =
    result = newIdentity(url) in group

  proc add*[T](group: IdentityGroup[T]; value: T) =
    if value in group:
      raise newException(KeyError, "duplicates not supported")
    group.incl value

    proc `[]`*[T](group: IdentityGroup[T]; identity: Identity): T =
      block found:
        for item in items(group):
          if item == identity:
            result = item
            break found
        raise newException(KeyError, "not found")

  proc `[]`*[T](group: IdentityGroup[T]; url: Uri): T =
    result = group[newIdentity(url)]

  proc `[]`*[T](group: IdentityGroup[T]; name: PackageName): T =
    result = group[newIdentity(name)]
