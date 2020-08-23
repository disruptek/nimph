import std/strtabs
import std/tables
import std/times
import std/os
import std/hashes
import std/strformat
import std/sequtils
import std/strutils
import std/uri except Url
import std/json
import std/options

import npeg

import nimph/spec
import nimph/requirements
import nimph/paths

import nimph/groups
export groups

type
  Dist* = enum
    Local = "local"
    Git = "git"
    Nest = "nest"
    Merc = "hg"
    Nimble = "nimble"

  Package* = object
    name*: PackageName
    url*: Uri
    dist*: Dist
    tags*: seq[string]
    description*: string
    license*: string
    web*: Uri
    naive*: bool
    local*: bool
    path*: AbsoluteDir
    author*: string

  Packages* = object
    flags: set[Flag]
    group: OrderedTable[Identity, Package]

  PackagesResult* = object
    ok*: bool
    why*: string
    packages*: Packages
    info: FileInfo

proc importName*(package: Package): ImportName =
  ## calculate how a package will be imported by the compiler
  importName(package.name)

proc newPackage*(name: PackageName; path: AbsoluteDir;
                 dist: Dist; url: Uri): Package =
  ## create a new package that probably points to a local repo
  result = Package(name: name, dist: dist, url: url,
                   path: path, local: dirExists(path))

proc newPackage*(name: PackageName; dist: Dist; url: Uri): Package =
  ## create a new package
  result = Package(name: name, dist: dist, url: url)

proc newPackage*(url: Uri): Package =
  ## create a new package with only a url
  result = newPackage(name = url.packageName, dist = Git,
                      url = url.convertToGit)
  # flag this package as not necessarily named correctly;
  # we had to guess at what the final name might be...
  result.naive = true

proc newPackage(name: PackageName; license: string; desc: string): Package =
  ## create a new package for nimble's package list consumer
  result = Package(name: name, license: license, description: desc)

proc `$`*(package: Package): string =
  result = $package.name
  if package.naive:
    result &= " (???)"

proc newPackages*(flags: set[Flag] = defaultFlags): Packages =
  ## instantiate a new package group for collecting a list of packages
  result = Packages(flags: flags)

proc aimAt*(package: Package; req: Requirement): Package =
  ## produce a refined package which might meet the requirement
  var
    aim = package.url
  if aim.anchor == "":
    aim.anchor = req.release.asUrlAnchor

  result = newPackage(name = package.name, dist = package.dist, url = aim)
  result.license = package.license
  result.description = package.description
  result.tags = package.tags
  result.naive = false
  result.web = package.web

proc add(group: Packages; js: JsonNode) =
  ## how packages get added to a group from the json list
  var
    name = packageName js["name"].getStr
    package = newPackage(name = name,
                         license = js.getOrDefault("license").getStr,
                         desc = js.getOrDefault("description").getStr)

  if "alias" in js:
    raise newException(Defect, "don't add aliases thusly")

  if "url" in js:
    package.url = js["url"].getStr.parseUri
  if "web" in js:
    package.web = js["web"].getStr.parseUri
  else:
    package.web = package.url
  if "method" in js:
    package.dist = parseEnum[Dist](js["method"].getStr)
  if "author" in js:
    package.author = js["author"].getStr
  else:
    package.dist = Git # let's be explicit here
  if "tags" in js:
    package.tags = mapIt(js["tags"], it.getStr.toLowerAscii)

  group.add newIdentity(name), package

proc getOfficialPackages*(nimbleDir: AbsoluteDir): PackagesResult =
  ## parse the official packages list from nimbledir
  var
    filename =
      if nimbleDir.endsWith PkgDir:
        nimbleDir.parentDir / officialPackages.RelativeFile
      else:
        nimbleDir / officialPackages.RelativeFile

  # make sure we have a sane return value
  result = PackagesResult(ok: false, why: "", packages: newPackages())

  var group = result.packages
  block parsing:
    try:
      # we might not even have to open the file; wouldn't that be wonderful?
      if not nimbledir.dirExists or not filename.fileExists:
        result.why = &"{filename} not found"
        break

      # grab the file info for aging purposes
      result.info = getFileInfo($filename)

      # okay, i guess we have to read and parse this silly thing
      let
        content = readFile($filename)
        js = parseJson(content)

      # consume the json array
      var
        aliases: seq[tuple[name: PackageName; alias: PackageName]]
      for node in js.items:
        # if it's an alias, stash it for later
        if "alias" in node:
          aliases.add (packageName node.getOrDefault("name").getStr,
                       packageName node["alias"].getStr)
        else:
          # else try to add it to the group
          try:
            group.add node
          except Exception as e:
            notice node
            warn &"error parsing package: {e.msg}"

      # now add in the aliases we collected
      for name, alias in aliases.items:
        if alias in group:
          group.add name, group.get(alias)
        else:
          warn &"alias `{name}` refers to a missing package `{alias}`"

      result.ok = true
    except Exception as e:
      result.why = e.msg

proc ageInDays*(found: PackagesResult): int64 =
  ## days since the packages file was last refreshed
  result = (getTime() - found.info.lastWriteTime).inDays

proc contains*(packages: Packages; name: PackageName): bool =
  result = name in packages.group

proc contains*(packages: Packages; package: Package): bool =
  result = package.name in packages

proc contains*(packages: Packages; url: Uri): bool =
  for package in items(packages):
    assert bare(package.url) == package.url
    result = package.url == url
    if result:
      break

proc contains*(packages: Packages; identity: Identity): bool =
  case identity.kind
  of Name:
    result = identity.name in packages
  of Url:
    result = identity.url in packages

proc `[]`*(packages: Packages; name: PackageName): Package =
  result = packages.group[name]

proc `[]`*(packages: Packages; url: Uri): Package =
  block found:
    for package in items(packages):
      if package.url == url:
        result = package
        break found
    raise newException(KeyError, "not found")

proc `[]`*(packages: Packages; identity: Identity): Package =
  case identity.kind
  of Name:
    result = packages[identity.name]
  of Url:
    result = packages[identity.url]

proc toUrl*(requirement: Requirement; group: Packages): Option[Uri] =
  ## try to determine the distribution url for a requirement
  var url: Uri

  # if it could be a url, try to parse it as such
  result = requirement.toUrl
  if result.isNone:
    # otherwise, see if we can find it in the package group
    if requirement.identity in group:
      let
        package = group.get(requirement.identity)
      if package.dist notin {Local, Git}:
        warn &"the `{package.dist}` distribution method is unsupported"
      else:
        url = package.url
        result = url.some
        debug "parsed in packages", requirement

  # maybe stuff the reference into the anchor
  if result.isSome:
    url = result.get
    url.anchor = requirement.release.asUrlAnchor
    result = url.some

proc hasUrl*(group: Packages; url: Uri): bool =
  ## true if the url seems to match a package in the group
  for value in group.values:
    result = bareUrlsAreEqual(value.url.convertToGit,
                              url.convertToGit)
    if result:
      break

proc matching*(group: Packages; req: Requirement): Packages =
  ## select a subgroup of packages that appear to match the requirement
  result = newPackages()
  if req.isUrl:
    let
      findurl = req.toUrl(group)
    if findurl.isNone:
      let emsg = &"couldn't parse url for requirement {req}" # noqa
      raise newException(ValueError, emsg)
    for name, package in group.pairs:
      if bareUrlsAreEqual(package.url.convertToGit,
                          findurl.get.convertToGit):
        result.add name, package.aimAt(req)
        when defined(debug):
          debug "matched the url in packages", $package.url
  else:
    for name, package in group.pairs:
      if name == req.identity:
        result.add name, package.aimAt(req)
        when defined(debug):
          debug "matched the package by name"

iterator urls*(group: Packages): Uri =
  ## yield (an ideally git) url for each package in the group
  for package in group.values:
    yield if package.dist == Git:
      package.url.convertToGit
    else:
      package.url
