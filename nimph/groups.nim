import std/hashes
import std/os
from std/sequtils import toSeq
import std/uri except Url

import gittyup

import nimph/spec
import nimph/paths
import nimph/requirements
import nimph/versions

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
  Suitable = concept s, t           ## the most basic of identity assumptions
    hash(s) is Hash
    `==`(s, t) is bool

  Collectable[T] = concept c        ## a collection of suitable items
    T is Suitable
    contains(c, T) is bool
    len(c) is Ordinal
    for item in items(c):           # ...that you can iterate
      item is T

  Groupable[T] = concept g, var w   ## a collection we can grow or shrink
    g is Collectable[T]
    add(w, T)
    del(w, T)

  Group[T] = concept g, var w       ## add the concept of a unique index
    g is Groupable[T]
    incl(w, T)                      # do nothing if T's index exists
    excl(w, T)                      # do nothing if T's index does not exist
    for index, item in pairs(g):    # pairs iteration yields the index
      item is T
      del(w, index)                 # the index can be used for deletion
      add(w, index, T)              # it will raise if the index exists
      `[]`(w, index) is T           # get via index
      `[]=`(w, index, T)            # set via index

  IdentityGroup*[T] = concept g, var w ##
    ## an IdentityGroup lets you test for membership via Identity,
    ## PackageName, or Uri
    g is Group[T]
    w is Group[T]
    contains(g, Identity) is bool
    contains(g, PackageName) is bool
    contains(g, Uri) is bool
    `[]`(g, PackageName) is T       # indexing by identity types
    `[]`(g, Uri) is T               # indexing by identity types
    `[]`(g, Identity) is T          # indexing by identity types

  ImportGroup*[T] = concept g, var w ##
    ## an ImportGroup lets you test for membership via ImportName
    g is Group[T]
    w is Group[T]
    importName(T) is ImportName
    contains(g, ImportName) is bool
    excl(w, ImportName)             # delete any T that yields ImportName
    `[]`(g, ImportName) is T        # index by ImportName

  GitGroup*[T] = concept g, var w ##
    ## a GitGroup is designed to hold Git objects like tags, references,
    ## commits, and so on
    g is Group[T]
    w is Group[T]
    oid(T) is GitOid
    contains(g, GitOid) is bool
    excl(w, GitOid)                 # delete any T that yields GitOid
    `[]`(g, GitOid) is T            # index by GitOid
    free(T)                         # ensure we can free the group

  ReleaseGroup*[T] = concept g, var w ##
    ## a ReleaseGroup lets you test for membership via Release,
    ## (likely Version, Tag, and such as well)
    g is Group[T]
    w is Group[T]
    contains(g, Release) is bool
    for item in g[Release]:         # indexing iteration by Release
      item is T

proc incl*[T](group: Groupable[T]; value: T) =
  if value notin group:
    group.add value

proc excl*[T](group: Groupable[T]; value: T) =
  if value in group:
    group.del value

proc hash*(group: Collectable): Hash =
  var h: Hash = 0
  for item in items(group):
    h = h !& hash(item)
  result = !$h

iterator backwards*[T](group: Collectable): T =
  ## yield values in reverse order
  let items = toSeq items(group)
  for index in countDown(items.high, items.low):
    yield items[index]

#
# now our customized implementations...
#
proc contains*(group: Group; name: ImportName): bool =
  for item in items(group):
    result = item.importName == name
    if result:
      break

proc excl*(group: Group; name: ImportName) =
  while name in group:
    for item in items(group):
      if importName(item) == name:
        group.del item
        break

proc `[]`*[T](group: Group[T]; name: ImportName): T =
  block found:
    for item in items(group):
      if item.importName == name:
        result = item
        break found
    raise newException(KeyError, "not found")

proc free*(group: Group) =
  ## free GitGroup members
  while len(group) > 0:
    for item in items(group):
      group.del item
      break

proc contains*(group: Group; identity: Identity): bool =
  for item in items(group):
    result = item == identity
    if result:
      break

proc contains*(group: Group; name: PackageName): bool =
  result = newIdentity(name) in group

proc contains*(group: Group; url: Uri): bool =
  result = newIdentity(url) in group

proc add*[T](group: Group[T]; value: T) =
  if value in group:
    raise newException(KeyError, "duplicates not supported")
  group.incl value

proc `[]`*[T](group: Group[T]; identity: Identity): T =
  block found:
    for item in items(group):
      if item == identity:
        result = item
        break found
    raise newException(KeyError, "not found")

proc `[]`*[T](group: Group[T]; url: Uri): T =
  result = group[newIdentity(url)]

proc `[]`*[T](group: Group[T]; name: PackageName): T =
  result = group[newIdentity(name)]
