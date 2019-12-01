import std/os
import std/hashes
import std/strtabs
import std/tables
import std/uri

import nimph/spec

type
  NimphGroup*[T: ref object] = ref object of RootObj
    table: OrderedTableRef[string, T]
    imports: StringTableRef

template init*(group: var typed; node: typedesc; mode = modeStyleInsensitive) =
  ## initialize the name cache
  group.table = newOrderedTable[string, node]()
  group.imports = newStringTable(mode)

proc addName(group: NimphGroup; name: string; value: string) =
  ## add a name to the group, which points to value
  assert value in group.table
  group.imports[name] = value

proc delName(group: NimphGroup; key: string) =
  ## remove a name from the group
  var
    remove: seq[string]
  # don't trust anyone; if the value matches, pull the name
  for name, value in group.imports.pairs:
    if value == key:
      remove.add name
  for name in remove:
    group.imports.del name

proc del*(group: NimphGroup; name: string) =
  group.table.del name
  group.delName name

proc len*(group: NimphGroup): int =
  result = group.table.len

proc get*[T](group: NimphGroup[T]; name: string): T =
  ## fetch a package from the group using style-insensitive lookup
  if name in group.table:
    result = group.table[name]
  else:
    result = group.table[group.imports[name.importName]]

proc mget*[T](group: var NimphGroup[T]; name: string): var T =
  ## fetch a package from the group using style-insensitive lookup
  if name in group.table:
    result = group.table[name]
  else:
    result = group.table[group.imports[name.importName]]

proc `[]`*[T](group: NimphGroup[T]; name: string): T =
  ## fetch a package from the group using style-insensitive lookup
  result = group.get(name)

proc add*[T](group: NimphGroup[T]; name: string; value: T) =
  group.table.add name, value
  group.addName name.importName, name

proc add*[T](group: NimphGroup[T]; url: Uri; value: T) =
  ## add a (bare) url as a key
  let
    naked = url.bare
    key = $naked
  group.table.add key, value
  {.warning: "does this make sense?  when?".}
  group.addName naked.importName, key

iterator pairs*[T](group: NimphGroup[T]): tuple[key: string; val: T] =
  for key, value in group.table.pairs:
    yield (key: key, val: value)


iterator values*[T](group: NimphGroup[T]): T =
  for value in group.table.values:
    yield value

iterator mvalues*[T](group: NimphGroup[T]): var T =
  for value in group.table.mvalues:
    yield value

proc hasKey*[T](group: NimphGroup[T]; name: string): bool =
  result = name in group.table or name.importName in group.imports

proc contains*[T](group: NimphGroup[T]; name: string): bool =
  result = group.hasKey(name)

proc contains*[T](group: NimphGroup[T]; url: Uri): bool =
  ## true if a member of the group has the same (bare) url
  for value in group.values:
    if bareUrlsAreEqual(value.url, url):
      result = true
      break

proc contains*[T](group: NimphGroup[T]; value: T): bool =
  for v in group.values:
    if v == value:
      result = true
      break
