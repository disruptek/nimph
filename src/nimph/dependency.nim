import std/uri
import std/strformat
import std/strutils
import std/sets
import std/hashes
import std/strtabs
import std/tables
import std/options

import bump

import nimph/spec
import nimph/package
import nimph/project
import nimph/version
import nimph/git

proc reportMultipleResolutions(project: Project;
                               requirement: Requirement; resolved: PackageGroup) =
  ## output some useful warnings depending upon the nature of the dupes

  var
    urls: HashSet[Hash]
  for url in resolved.urls:
    urls.incl url.hash

  if urls.len == 1:
    warn &"{project.name} has {resolved.len} " &
         &"options for {requirement} dependency, all via"
    for url in resolved.urls:
      warn &"\t{url}"
      break
  else:
    warn &"{project.name} has {resolved.len} " &
         &"options for {requirement} dependency:"
  var count = 1
  for name, package in resolved.pairs:
    if package.local:
      warn &"\t{count}\t{name} in {package.path}"
    elif package.web.isValid:
      warn &"\t{count}\t{name} at {package.web}"
    if urls.len != 1:
      warn &"\t{package.url}"
      fatal ""
    count.inc

proc createUrl(project: Project): Uri =
  ## determine the source url for a project which may be local
  let
    dist = project.dist
  if project.url.isValid:
    result = project.url
  else:
    case dist:
    of Local:
      result = Uri(scheme: "file", path: project.repo)
    of Git:
      var
        url = findRepositoryUrl(project.repo)
      if url.isSome:
        result = url.get
      else:
        result = Uri(scheme: "file", path: project.repo)
    else:
      raise newException(Defect, "not implemented")

proc asPackage*(project: Project): Package =
  ## cast a project to a package
  result = newPackage(name = project.name, path = project.repo,
                      dist = project.dist, url = project.createUrl())

proc childProjects*(project: Project): ProjectGroup =
  ## convenience
  result = project.availableProjects
  for child in result.mvalues:
    child.parent = project

proc determineDeps*(project: Project): Option[Requires] =
  if project.dump == nil:
    error "unable to determine deps without issuing a dump"
    return
  result = parseRequires(project.dump["requires"])

proc determineDeps*(project: var Project): Option[Requires] =
  if not project.fetchDump():
    debug "nimble dump failed, so computing deps is impossible"
    return
  let
    immutable = project
  result = determineDeps(immutable)

proc releaseSymbols(release: Release; head = "";
                    tags: GitTagTable = nil): HashSet[Hash] =
  if release.kind == Tag:
    if release.reference.toLowerAscii == "head":
      if head != "":
        result.incl head.hash
    else:
      result.incl release.reference.hash
    if tags != nil:
      if tags.hasKey(release.reference):
        result.incl hash($tags[release.reference].oid)
  else:
    if not release.isSpecific:
      return

    # stuff some version strings into
    # the hash that might match a tag
    var version = release.specifically
    result.incl hash(       $version)
    result.incl hash("v"  & $version)
    result.incl hash("V"  & $version)
    result.incl hash("v." & $version)
    result.incl hash("V." & $version)

proc symbolicMatch(req: Requirement; release: Release; head = "";
                   tags: GitTagTable = nil): bool =
  if req.operator notin {Equal, Tag} or release.kind != Tag:
    return

  let
    required = releaseSymbols(req.release, head, tags = tags)
    provided = releaseSymbols(release, head, tags = tags)
  result = len(required * provided) > 0

proc symbolicMatch(project: Project; req: Requirement): bool =
  if project.dist == Git:
    if project.tags == nil:
      warn &"i wanted to examine tags for {project} but they were empty"
    result = symbolicMatch(req, project.release, $project.getHeadOid,
                           tags = project.tags)
  else:
    debug &"without a git repo for {project.name}, i cannot determine tags"
    result = symbolicMatch(req, project.release)

proc isSatisfiedBy(req: Requirement; project: Project): bool =
  # first, check that the identity matches
  if project.name == req.identity:
    result = true
  elif req.isUrl:
    let
      url = req.toUrl
    if url.isSome:
      if project.url == url.get:
        result = true
      elif bareUrlsAreEqual(project.url, url.get):
        result = true
  # if it does, check that the version matches
  if result:
    if req.operator == Tag:
      # compare tags, head, and versions
      result = project.symbolicMatch(req)
    else:
      # try to use our release
      if project.release.isSpecific:
        result = newRelease(project.release.specifically) in req
      # fallback to the version indicated by nimble
      elif project.version.isValid:
        result = newRelease(project.version) in req

proc resolveDependency*(project: Project;
                        projects: ProjectGroup;
                        packages: PackageGroup;
                        requirement: Requirement): PackageGroup =

  result = newPackageGroup()
  # 1. is it a directory?
  for name, available in projects.pairs:
    if not requirement.isSatisfiedBy(available):
      continue
    debug &"{available} satisfies {requirement}"
    # test that the project name matches its directory name
    if name != available.name:
      warn &"package `{available.name}` may be imported as `{name}`"
    result.add name, available.asPackage

  # seems like we found some viable deps info locally
  if result.len > 0:
    return

  # 2. is it in packages?
  result = packages.matching(requirement)
  if result.len > 0:
    return

  # unavailable and all we have is a url
  if requirement.isUrl:
    let findurl = requirement.toUrl(packages)
    if findurl.isSome:
      # if it's a url but we couldn't match it, add it to the result anyway
      let package = newPackage(url = findurl.get)
      result.add $package.url, package
      return

  raise newException(ValueError, &"dunno where to get requirement {requirement}")

proc resolveDependencies*(project: var Project;
                          projects: var ProjectGroup;
                          packages: PackageGroup;
                          dependencies: var PackageGroup): bool =
  ## resolve a project's dependencies recursively; store result in dependencies
  info &"{project.cuteRelease:>8} {project.name:>12}   {project.releaseSummary}"

  result = true

  let
    findReqs = project.determineDeps
  if findReqs.isNone:
    warn &"no requirements found for {project}"
    return

  let
    requires = findReqs.get
  for requirement in requires.values:
    if requirement.isVirtual:
      continue
    let resolved = project.resolveDependency(projects, packages, requirement)
    case resolved.len:
    of 0:
      warn &"unable to resolve requirement `{requirement}`"
      result = false
      continue
    of 1:
      discard
    else:
      project.reportMultipleResolutions(requirement, resolved)
    for name, package in resolved.pairs:
      if name in dependencies:
        continue
      dependencies.add name, package
      if package.local and projects.hasProjectIn(package.path):
        var recurse = projects.mgetProjectIn(package.path)
        result = result and recurse.resolveDependencies(projects, packages,
                                                        dependencies)

proc resolveDependencies*(project: var Project;
                          dependencies: var PackageGroup): bool =
  ## entrance to the recursive dependency resolution
  var
    packages: PackageGroup
    projects = project.childProjects

  let
    findPacks = getOfficialPackages(project.nimbleDir)
  if not findPacks.ok:
    packages = newPackageGroup()
  else:
    packages = findPacks.packages

  result = project.resolveDependencies(projects, packages, dependencies)
