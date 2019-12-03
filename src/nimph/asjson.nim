import std/uri
import std/strutils
import std/strformat
import std/options
import std/json

import bump

import nimph/spec
import nimph/version
import nimph/package

proc toJson*(operator: Operator): JsonNode =
  result = newJString($operator)

proc toOperator*(js: JsonNode): Operator =
  result = parseEnum[Operator](js.getStr)

proc toJson*(version: Version): JsonNode =
  result = newJArray()
  for index in VersionIndex.low .. VersionIndex.high:
    result.add newJInt(version.at(index).int)

proc toVersion*(js: JsonNode): Version =
  let
    e = js.getElems
  if e.len != VersionIndex.high + 1:
    let emsg = &"dunno what to do with a version of len {e.len}"
    raise newException(ValueError, emsg)
  result = (major: e[0].getInt.uint,
            minor: e[1].getInt.uint,
            patch: e[2].getInt.uint)

proc toJson*(mask: VersionMask): JsonNode =
  # is it a *.*.*?
  if mask.at(0).isNone:
    result = newJString("*")
  else:
    result = newJArray()
    for index in VersionIndex.low .. VersionIndex.high:
      let value = mask.at(index)
      if value.isSome:
        result.add newJInt(value.get.int)

proc toVersionMask*(js: JsonNode): VersionMask =
  if js.kind == JString:
    # it's a *.*.*
    return

  # it's an array with items in it
  let
    e = js.getElems
  if e.high > VersionIndex.high:
    let emsg = &"dunno what to do with a version mask of len {e.len}"
    raise newException(ValueError, emsg)
  for index in VersionIndex.low .. VersionIndex.high:
    if index > e.high:
      break
    result[index] = e[index].getInt.uint.some

proc toJson*(release: Release): JsonNode =
  result = newJObject()
  result["operator"] = release.kind.toJson
  case release.kind:
  of Tag:
    result["reference"] = newJString(release.reference)
  of Wild, Caret, Tilde:
    result["accepts"] = release.accepts.toJson
  of Equal, AtLeast, Over, Under, NotMore:
    result["version"] = release.version.toJson

proc toRelease*(js: JsonNode): Release =
  result = Release(kind: js["operator"].toOperator)
  case result.kind:
  of Tag:
    result.reference = js["reference"].getStr
  of Wild, Caret, Tilde:
    result.accepts = js["accepts"].toVersionMask
  of Equal, AtLeast, Over, Under, NotMore:
    result.version = js["version"].toVersion

proc toJson*(requirement: Requirement): JsonNode =
  result = newJObject()
  result["identity"] = newJString(requirement.identity)
  result["operator"] = requirement.operator.toJson
  result["release"] = requirement.release.toJson

proc toRequirement*(js: JsonNode): Requirement =
  result.identity = js["identity"].getStr
  result.operator = js["operator"].toOperator
  result.release = js["release"].toRelease

proc toJson*(dist: DistMethod): JsonNode =
  result = newJString($dist)

proc toDistMethod*(js: JsonNode): DistMethod =
  result = parseEnum[DistMethod](js.getStr)

proc toJson*(uri: Uri): JsonNode =
  let url = case uri.scheme:
  of "ssh", "":
    uri.convertToSsh
  else:
    uri.normalizeUrl
  result = newJString($url)

proc toUri*(js: JsonNode): Uri =
  result = parseUri(js.getStr)
