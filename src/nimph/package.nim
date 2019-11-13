import std/tables
import std/times
import std/os
import std/hashes
import std/strformat
import std/sequtils
import std/strutils
import std/tables
import std/uri
import std/json
import std/options

import npeg
import bump

import nimph/spec
import nimph/version

type
  DistMethod* = enum
    Local = "local"
    Git = "git"
    Nest = "nest"
    Merc = "hg"

  Package* = ref object
    name*: string
    url*: Uri
    dist*: DistMethod
    tags*: seq[string]
    description*: string
    license*: string
    web*: Uri
    naive*: bool

  PackageGroup* = ref object
    table*: TableRef[string, Package]
    info*: FileInfo  ## sloppy support for aging the nimble package list

  PackagesResult* = tuple
    ok: bool
    why: string
    packages: PackageGroup

proc newPackage*(name: string; dist: DistMethod; url: Uri): Package =
  ## create a new package
  result = Package(name: name, dist: dist, url: url)

proc naiveName*(path: string): string =
  ## guess the import name of a package from a url path
  result = path.extractFilename.changeFileExt("").split("-")[^1]

proc newPackage*(url: Uri): Package =
  ## create a new package with only a url
  result = newPackage(name = naiveName(url.path), dist = Git, url = url)
  # flag this package as not necessarily named correctly;
  # we had to guess at what the final name might be...
  result.naive = true

proc newPackage(name: string; license: string; description: string): Package =
  ## create a new package for nimble's package list consumer
  result = Package(name: name, license: license, description: description)

proc `$`*(package: Package): string =
  result = package.name
  if package.naive:
    result &= " (???)"

proc newPackageGroup*(): PackageGroup =
  ## instantiate a new package group for collecting a list of packages
  result = PackageGroup()
  result.table = newTable[string, Package]()

proc newPackageGroup(filename: string): PackageGroup =
  ## instantiate a new package group using a package list from nimble
  result = newPackageGroup()
  result.info = getFileInfo(filename)

proc len*(group: PackageGroup): int =
  result = group.table.len

proc contains*(group: PackageGroup; name: string): bool =
  result = name in group.table

proc `[]`*(group: PackageGroup; name: string): Package =
  result = group.table[name]

proc add*(group: PackageGroup; name: string; package: Package) =
  if name.len == 0:
    warn "btw, i didn't add a package with an empty name"
  else:
    group.table.add name, package

proc aimAt*(package: Package; req: Requirement): Package =
  var
    aim = package.url
  if aim.anchor == "":
    case req.release.kind:
    of Tag:
      aim.anchor = req.release.reference
      removePrefix(aim.anchor, {'#'})
    of Equal:
      aim.anchor = $req.release.version
    else:
      discard

  result = newPackage(name = package.name,
                      dist = package.dist,
                      url = aim)
  result.license = package.license
  result.description = package.description
  result.tags = package.tags
  result.naive = false
  result.web = package.web

proc add(group: PackageGroup; js: JsonNode) =
  var
    name = js["name"].getStr
    package = newPackage(name = name,
                         license = js.getOrDefault("license").getStr,
                         description = js.getOrDefault("description").getStr)

  if "alias" in js:
    raise newException(ValueError, "don't add aliases thusly")

  if "url" in js:
    package.url = js["url"].getStr.parseUri
  if "web" in js:
    package.web = js["web"].getStr.parseUri
  else:
    package.web = package.url
  if "method" in js:
    package.dist = parseEnum[DistMethod](js["method"].getStr)
  else:
    package.dist = Git # let's be explicit here
  if "tags" in js:
    package.tags = mapIt(js["tags"], it.getStr)

  group.add name, package

proc getOfficialPackages*(nimbledir: string): PackagesResult {.raises: [].} =
  let
    filename = nimbledir / officialPackages

  block parsing:
    try:
      # we might not even have to open the file; wouldn't that be wonderful?
      if not nimbledir.dirExists or not filename.fileExists:
        result = (ok: false, why: &"{filename} not found", packages: nil)
        break

      # okay, i guess we have to read and parse this silly thing
      let
        content = readFile(filename)
        js = parseJson(content)

      # setup a new group
      var
        group = newPackageGroup(filename)

      # consume the json array
      var
        aliases: seq[tuple[name: string; alias: string]]
      for node in js.items:
        # if it's an alias, stash it for later
        if "alias" in node:
          aliases.add (node.getOrDefault("name").getStr,
                       node["alias"].getStr)
          continue

        # else try to add it to the group
        try:
          group.add node
        except Exception as e:
          warn node
          warn &"error reading package: {e.msg}"

      # now add in the aliases we collected
      for name, alias in aliases.items:
        if alias in group:
          group.add name, group[alias]
        else:
          warn &"alias `{name}` refers to a missing package `{alias}`"

      result = (ok: true, why: "", packages: group)
    except Exception as e:
      result = (ok: false, why: e.msg, packages: nil)

proc ageInDays*(group: PackageGroup): int64 =
  ## days since the packages file was last refreshed
  result = (getTime() - group.info.lastWriteTime).inDays

proc toUrl*(requirement: Requirement; group: PackageGroup): Option[Uri] =
  ## try to determine the distribution url for a requirement
  var url: Uri

  # if it could be a url, try to parse it as such
  result = requirement.toUrl
  if result.isNone:
    # otherwise, see if we can find it in the package group
    if requirement.identity in group:
      let
        package = group[requirement.identity]
      if package.dist notin {Local, Git}:
        warn &"the `{package.dist}` distribution method is unsupported"
        return
      url = package.url
      result = url.some
      debug "parsed in packages", requirement

  # maybe stuff the reference into the anchor
  if result.isSome:
    url = result.get
    if requirement.release.kind == Tag:
      url.anchor = requirement.release.reference
      removePrefix(url.anchor, {'#'})
    result = url.some

iterator pairs*(group: PackageGroup): tuple[name: string; package: Package] =
  for name, package in group.table.pairs:
    yield (name: name, package: package)

proc bareUrlsAreEqual*(a, b: Uri): bool =
  if a.scheme.len != 0 and b.scheme.len != 0:
    var
      x = a
      y = b
    x.anchor = ""
    y.anchor = ""
    result = $x == $y

proc matching*(group: PackageGroup; req: Requirement): PackageGroup =
  result = newPackageGroup()
  if req.isUrl:
    let
      findurl = req.toUrl(group)
    if findurl.isNone:
      raise newException(ValueError,
                         &"couldn't parse url for requirement {req}")
    for name, package in group.pairs:
      if bareUrlsAreEqual(package.url, findurl.get):
        result.add name, package.aimAt(req)
        debug "matched the url in packages", $package.url
  else:
    for name, package in group.pairs:
      if name == req.identity:
        result.add name, package.aimAt(req)
        debug "matched the package by name"
