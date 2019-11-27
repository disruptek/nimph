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

type
  Dependency* = ref object
    names*: seq[string]
    requirement*: Requirement
    packages*: PackageGroup
    projects*: ProjectGroup

  DependencyGroup* = ref object
    table*: TableRef[Requirement, Dependency]

proc newDependency*(requirement: Requirement): Dependency =
  result = Dependency(requirement: requirement)
  result.projects = newProjectGroup()
  result.packages = newPackageGroup()

proc newDependencyGroup*(): DependencyGroup =
  result = DependencyGroup()
  result.table = newTable[Requirement, Dependency]()

iterator pairs*(dependencies: DependencyGroup):
  tuple[requirement: Requirement; dependency: Dependency] =
  for requirement, dependency in dependencies.table.pairs:
    yield (requirement: requirement, dependency: dependency)

proc contains*(dependencies: DependencyGroup; package: Package): bool =
  for name, dependency in dependencies.pairs:
    result = package.url in dependency.packages
    if result:
      break

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

proc adopt*(parent: Project; child: var Project) =
  ## associate a child project with the parent project of which the
  ## child is a requirement, member of local dependencies, or otherwise
  ## available to the compiler's search paths
  child.parent = parent

proc childProjects*(project: Project): ProjectGroup =
  ## compose a group of possible dependencies of the project
  result = project.availableProjects
  for child in result.mvalues:
    project.adopt(child)

proc determineDeps*(project: Project): Option[Requires] =
  ## try to parse requirements of a project
  if project.dump == nil:
    error "unable to determine deps without issuing a dump"
    return
  result = parseRequires(project.dump["requires"])

proc determineDeps*(project: var Project): Option[Requires] =
  ## try to parse requirements of a (mutable) project
  if not project.fetchDump():
    debug "nimble dump failed, so computing deps is impossible"
    return
  let
    immutable = project
  result = determineDeps(immutable)

proc releaseSymbols(release: Release; head = "";
                    tags: GitTagTable = nil): HashSet[Hash] =
  ## compute a set of hashes that could match this release; ie.
  ## tags, oids, version numbers, etc.
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
  ## see if a requirement's symbolic need is met by a release's
  ## symbolic value
  if req.operator notin {Equal, Tag} or release.kind != Tag:
    return

  let
    required = releaseSymbols(req.release, head, tags = tags)
    provided = releaseSymbols(release, head, tags = tags)
  result = len(required * provided) > 0

proc symbolicMatch(project: Project; req: Requirement): bool =
  ## see if a project can match a given requirement symbolically
  if project.dist == Git:
    if project.tags == nil:
      warn &"i wanted to examine tags for {project} but they were empty"
    result = symbolicMatch(req, project.release, $project.getHeadOid,
                           tags = project.tags)
  else:
    debug &"without a repo for {project.name}, i cannot match {req}"
    result = symbolicMatch(req, project.release)

proc isSatisfiedBy(req: Requirement; project: Project): bool =
  ## true if a requirement is satisfied by the given project
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

proc addName(dependency: var Dependency; name: string) =
  ## add an import name to the dependency, as might be used in code
  let
    package = name.packageName
  if package notin dependency.names:
    dependency.names.add package

proc add(dependency: var Dependency; package: Package) =
  ## add a package to the dependency
  let key = $package.url.bare
  if key notin dependency.packages:
    dependency.packages.add key, package
  dependency.addName package.name

proc add(dependency: var Dependency; url: Uri) =
  ## add a url (as a package) to the dependency
  dependency.add newPackage(url = url)

proc add(dependency: var Dependency; packages: PackageGroup) =
  ## add a group of packages to the dependency
  for package in packages.values:
    dependency.add package

proc add(dependency: var Dependency; directory: string; project: Project) =
  ## add a local project in the given directory to an existing dependency
  dependency.projects.add directory, project
  dependency.addName project.name
  # this'll help anyone sniffing around thinking packages precede projects
  dependency.add project.asPackage

proc add(dependencies: DependencyGroup; dependency: Dependency) =
  ## add a single dependency to the dependency group
  dependencies.table[dependency.requirement] = dependency

proc contains*(dependencies: DependencyGroup; req: Requirement): bool =
  result = req in dependencies.table

proc contains*(dependencies: DependencyGroup; dep: Dependency): bool =
  result = dep.requirement in dependencies

proc `[]`*(dependencies: DependencyGroup; req: Requirement): Dependency =
  result = dependencies.table[req]

proc addsRequirements(dependencies: DependencyGroup;
                      dependency: Dependency): bool =
  ## true if the addition of a dependency will add new requirements to
  ## the dependency group
  if dependency.requirement notin dependencies:
    dependencies.add dependency
    return true
  var
    existing = dependencies[dependency.requirement]
  # adding the packages as a group will work
  existing.add dependency.packages
  # add projects according to their repo
  for project in dependency.projects.values:
    existing.add project.repo, project

proc isHappy*(dependency: Dependency): bool =
  ## true if the dependency is being met successfully
  result = dependency.projects.len > 0

proc resolveDependency*(project: Project;
                        projects: ProjectGroup;
                        packages: PackageGroup;
                        requirement: Requirement): Dependency =
  ## filter all we know about the environment, a requirement, and the
  ## means by which we may satisfy it, into a single object
  result = newDependency(requirement)
  block success:

    # 1. is it a directory?
    for directory, available in projects.pairs:
      if not requirement.isSatisfiedBy(available):
        continue
      debug &"{available} satisfies {requirement}"
      result.add directory, available

    # seems like we found some viable deps info locally
    if result.isHappy:
      break success

    # 2. is it in packages?
    let matches = packages.matching(requirement)
    result.add(matches)
    if matches.len > 0:
      break success

    # 3. all we have is a url
    if requirement.isUrl:
      let findurl = requirement.toUrl(packages)
      if findurl.isSome:
        # if it's a url but we couldn't match it, add it to the result anyway
        result.add findurl.get
        break success

    raise newException(ValueError, &"dunno where to get requirement {requirement}")

proc isUsing*(dependencies: DependencyGroup; target: Target;
              outside: Dependency = nil): bool =
  ## true if the target points to a repo we're importing
  block found:
    for requirement, dependency in dependencies.pairs:
      if dependency == outside:
        continue
      for directory, project in dependency.projects.pairs:

        if directory == target.repo:
          result = true
          break found
  when defined(debug):
    debug &"is using {target.repo}: {result}"

proc resolveDependencies*(project: var Project;
                          projects: var ProjectGroup;
                          packages: PackageGroup;
                          dependencies: var DependencyGroup): bool =
  ## resolve a project's dependencies recursively;
  ## store result in dependencies

  # assert a usable config
  discard project.fetchConfig

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
    if requirement in dependencies:
      continue
    var resolved = project.resolveDependency(projects, packages, requirement)
    case resolved.packages.len:
    of 0:
      warn &"unable to resolve requirement `{requirement}`"
      result = false
      continue
    of 1:
      discard
    else:
      project.reportMultipleResolutions(requirement, resolved.packages)

    # if the addition of the resolution is not novel, move along
    if not dependencies.addsRequirements(resolved):
      continue

    # else, we'll resolve dependencies introduced in any new projects
    #
    # note: we're using project.cfg and project.repo as a kind of scope
    for recurse in resolved.projects.asFoundVia(project.cfg, project.repo):
      if dependencies.isUsing(recurse.nimble, outside = resolved):
        continue
      result = result and recurse.resolveDependencies(projects, packages,
                                                      dependencies)

proc getOfficialPackages(project: Project): PackagesResult =
  result = getOfficialPackages(project.nimbleDir)

proc resolveDependencies*(project: var Project;
                          dependencies: var DependencyGroup): bool =
  ## entrance to the recursive dependency resolution
  var
    packages: PackageGroup
    projects = project.childProjects

  let
    findPacks = project.getOfficialPackages
  if not findPacks.ok:
    packages = newPackageGroup()
  else:
    packages = findPacks.packages

  result = project.resolveDependencies(projects, packages, dependencies)
