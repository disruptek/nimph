import std/os
import std/strtabs
import std/tables
import std/uri

import nimph/spec

type
  NimphGroup*[K; V: ref object] = ref object of RootObj
    table*: OrderedTableRef[K, V]
    imports*: StringTableRef

proc init*[K, V](group: NimphGroup[K, V];
                 mode = modeStyleInsensitive) =
  ## initialize the table and name cache
  group.table = newOrderedTable[K, V]()
  group.imports = newStringTable(mode)

proc addName[K: string, V](group: NimphGroup[K, V];
                           name: K; value: string) =
  ## add a name to the group, which points to value
  assert group.table.hasKey(value)
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

proc get*[K: string, V](group: NimphGroup[K, V]; key: K): V =
  ## fetch a package from the group using style-insensitive lookup
  if group.table.hasKey(key):
    result = group.table[key]
  elif group.imports.hasKey(key.importName):
    result = group.table[group.imports[key.importName]]
  else:
    let emsg = &"{key.importName} not found"
    raise newException(KeyError, emsg)

proc mget*[K: string, V](group: var NimphGroup[K, V]; key: K): var V =
  ## fetch a package from the group using style-insensitive lookup
  if group.table.hasKey(key):
    result = group.table[key]
  elif group.imports.hasKey(key.importName):
    result = group.table[group.imports[key.importName]]
  else:
    let emsg = &"{key.importName} not found"
    raise newException(KeyError, emsg)

proc `[]`*[K, V](group: var NimphGroup[K, V]; key: K): var V =
  ## fetch a package from the group using style-insensitive lookup
  result = group.mget(key)

proc `[]`*[K, V](group: NimphGroup[K, V]; key: K): V =
  ## fetch a package from the group using style-insensitive lookup
  result = group.get(key)

proc add*[K: string, V](group: NimphGroup[K, V]; key: K; value: V) =
  group.table.add key, value
  group.addName(key.importName, key)

proc add*[K: string, V](group: NimphGroup[K, V]; url: Uri; value: V) =
  ## add a (bare) url as a key
  let
    naked = url.bare
    key = $naked
  group.table.add key, value
  {.warning: "does this make sense?  when?".}
  group.addName naked.importName, key

iterator pairs*[K, V](group: NimphGroup[K, V]): tuple[key: K; val: V] =
  for key, value in group.table.pairs:
    yield (key: key, val: value)

iterator mpairs*[K, V](group: NimphGroup[K, V]): tuple[key: K; val: V] =
  for key, value in group.table.mpairs:
    yield (key: key, val: value)

iterator values*[K, V](group: NimphGroup[K, V]): V =
  for value in group.table.values:
    yield value

iterator mvalues*[K, V](group: NimphGroup[K, V]): var V =
  for value in group.table.mvalues:
    yield value

proc hasKey*[K, V](group: NimphGroup[K, V]; key: K): bool =
  result = group.table.hasKey(key)

proc contains*[K, V](group: NimphGroup[K, V]; key: K): bool =
  result = group.table.contains(key) or group.imports.contains(key.importName)

proc contains*[K, V](group: NimphGroup[K, V]; url: Uri): bool =
  ## true if a member of the group has the same (bare) url
  for value in group.values:
    if bareUrlsAreEqual(value.url, url):
      result = true
      break

proc contains*[K, V](group: NimphGroup[K, V]; value: V): bool =
  for v in group.values:
    if v == value:
      result = true
      break
