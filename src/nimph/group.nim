import std/os
import std/strtabs
import std/tables
from std/sequtils import toSeq
import std/uri except Url

export strtabs.StringTableMode

import nimph/spec

type
  Group*[K; V: ref object] = ref object of RootObj
    table*: OrderedTableRef[K, V]
    imports*: StringTableRef
    flags*: set[Flag]
    mode: StringTableMode

proc init*[K, V](group: Group[K, V]; flags: set[Flag]; mode = modeStyleInsensitive) =
  ## initialize the table and name cache
  group.table = newOrderedTable[K, V]()
  when K is Uri:
    group.mode = modeCaseSensitive
  else:
    group.mode = mode
  group.imports = newStringTable(group.mode)
  group.flags = flags

proc addName[K: string, V](group: Group[K, V]; name: K; value: string) =
  ## add a name to the group, which points to value
  assert group.table.hasKey(value)
  group.imports[name] = value

proc addName[K: Uri, V](group: Group[K, V]; url: K) =
  ## add a url to the group, which points to value
  assert group.table.hasKey(url)
  group.imports[$url] = $url
  when defined(debug):
    assert $url.bare notin group.imports
  group.imports[$url.bare] = $url

proc delName*(group: Group; key: string) =
  ## remove a name from the group
  var
    remove: seq[string]
  # don't trust anyone; if the value matches, pull the name
  for name, value in group.imports.pairs:
    if value == key:
      remove.add name
  for name in remove:
    group.imports.del name

proc del*[K: string, V](group: Group[K, V]; name: K) =
  group.table.del name
  group.delName name

proc del*[K: Uri, V](group: Group[K, V]; url: K) =
  group.table.del url
  group.delName $url

{.warning: "nim bug #12818".}
proc len*[K, V](group: Group[K, V]): int =
  result = group.table.len

proc len*(group: Group): int =
  result = group.table.len

proc get*[K: string, V](group: Group[K, V]; key: K): V =
  ## fetch a package from the group using style-insensitive lookup
  if group.table.hasKey(key):
    result = group.table[key]
  elif group.imports.hasKey(key.importName):
    result = group.table[group.imports[key.importName]]
  else:
    let emsg = &"{key.importName} not found"
    raise newException(KeyError, emsg)

proc mget*[K: string, V](group: var Group[K, V]; key: K): var V =
  ## fetch a package from the group using style-insensitive lookup
  if group.table.hasKey(key):
    result = group.table[key]
  elif group.imports.hasKey(key.importName):
    result = group.table[group.imports[key.importName]]
  else:
    let emsg = &"{key.importName} not found"
    raise newException(KeyError, emsg)

proc `[]`*[K, V](group: var Group[K, V]; key: K): var V =
  ## fetch a package from the group using style-insensitive lookup
  result = group.mget(key)

proc `[]`*[K, V](group: Group[K, V]; key: K): V =
  ## fetch a package from the group using style-insensitive lookup
  result = group.get(key)

proc add*[K: string, V](group: Group[K, V]; key: K; value: V) =
  group.table.add key, value
  group.addName(key.importName, key)

proc add*[K: string, V](group: Group[K, V]; url: Uri; value: V) =
  ## add a (bare) url as a key
  let
    naked = url.bare
    key = $naked
  group.table.add key, value
  # this gets picked up during instant-instantiation of a package from
  # a project's url, a la asPackage(project: Project): Package ...
  group.addName naked.importName, key

proc `[]=`*[K, V](group: Group[K, V]; key: K; value: V) =
  ## set a key to a single value
  if group.hasKey(key):
    group.del key
  group.add key, value

{.warning: "nim bug #12818".}
proc add*[K: Uri, V](group: Group[K, V]; url: Uri; value: V) =
  ## add a (full) url as a key
  group.table.add url, value
  group.addName url

iterator pairs*[K, V](group: Group[K, V]): tuple[key: K; val: V] =
  for key, value in group.table.pairs:
    yield (key: key, val: value)

iterator mpairs*[K, V](group: Group[K, V]): tuple[key: K; val: V] =
  for key, value in group.table.mpairs:
    yield (key: key, val: value)

iterator values*[K, V](group: Group[K, V]): V =
  for value in group.table.values:
    yield value

iterator mvalues*[K, V](group: Group[K, V]): var V =
  for value in group.table.mvalues:
    yield value

proc hasKey*[K, V](group: Group[K, V]; key: K): bool =
  result = group.table.hasKey(key)

proc contains*[K, V](group: Group[K, V]; key: K): bool =
  result = group.table.contains(key) or group.imports.contains(key.importName)

proc contains*[K, V](group: Group[K, V]; url: Uri): bool =
  ## true if a member of the group has the same (bare) url
  for value in group.values:
    if bareUrlsAreEqual(value.url, url):
      result = true
      break

proc contains*[K, V](group: Group[K, V]; value: V): bool =
  for v in group.values:
    if v == value:
      result = true
      break

iterator reversed*[K, V](group: Group[K, V]): V =
  ## yield values in reverse order of entry
  let
    elems = toSeq group.values

  for index in countDown(elems.high, elems.low):
    yield elems[index]

proc clear*[K, V](group: Group[K, V]) =
  ## clear the group without any other disruption
  group.table.clear
  group.imports.clear(group.mode)
