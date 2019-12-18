import std/os
import std/uri
import std/strformat
import std/strutils
import std/sets
import std/hashes
import std/strtabs
import std/tables
import std/options
import std/sequtils
import std/algorithm

import bump

import nimph/spec
import nimph/package
import nimph/project
import nimph/version
import nimph/git
import nimph/config

import nimph/group
export group

type
  Dependency* = ref object
    names*: seq[string]
    requirement*: Requirement
    packages*: PackageGroup
    projects*: ProjectGroup

  DependencyGroup* = ref object of Group[Requirement, Dependency]
    packages: PackageGroup
    projects: ProjectGroup

proc name*(dependency: Dependency): string =
  result = dependency.names.join("|")

proc `$`*(dependency: Dependency): string =
  result = dependency.name & "->" & $dependency.requirement

proc newDependency*(requirement: Requirement): Dependency =
  result = Dependency(requirement: requirement)
  result.projects = newProjectGroup()
  result.packages = newPackageGroup()

proc newDependencyGroup*(flags: set[Flag]): DependencyGroup =
  result = DependencyGroup(flags: flags)
  result.init(flags, mode = modeStyleInsensitive)

proc contains*(dependencies: DependencyGroup; package: Package): bool =
  for name, dependency in dependencies.pairs:
    result = dependency.packages.hasUrl(package.url)
    if result:
      break

proc hasKey*(dependencies: DependencyGroup; name: string): bool =
  result = dependencies.imports.hasKey(name)

proc reportMultipleResolutions(project: Project; requirement: Requirement;
                               packages: PackageGroup) =
  ## output some useful warnings depending upon the nature of the dupes
  var
    urls: HashSet[Hash]
  for url in packages.urls:
    urls.incl url.hash

  if urls.len == 1:
    warn &"{project.name} has {packages.len} " &
         &"options for {requirement} dependency, all via"
    for url in packages.urls:
      warn &"\t{url}"
      break
  else:
    warn &"{project.name} has {packages.len} " &
         &"options for {requirement} dependency:"
  var count = 1
  for name, package in packages.pairs:
    if package.local:
      warn &"\t{count}\t{package.path}"
    elif package.web.isValid:
      warn &"\t{count}\t{package.web}"
    if urls.len != 1:
      warn &"\t{package.url}\n"
    count.inc
  fatal ""

proc asPackage*(project: Project): Package =
  ## cast a project to a package
  result = newPackage(name = project.name, path = project.repo,
                      dist = project.dist, url = project.createUrl())

proc adopt*(parent: Project; child: var Project) =
  ## associate a child project with the parent project of which the
  ## child is a requirement, member of local dependencies, or otherwise
  ## available to the compiler's search paths
  if child.parent != nil and child.parent != parent:
    let emsg = &"{parent} cannot adopt {child}"
    raise newException(Defect, emsg)
  child.parent = parent

proc childProjects*(project: Project): ProjectGroup =
  ## compose a group of possible dependencies of the project
  result = project.availableProjects
  for child in result.mvalues:
    if child == project:
      continue
    project.adopt(child)
    discard child.fetchConfig

proc determineDeps*(project: Project): Option[Requires] =
  ## try to parse requirements of a project
  if project.dump == nil:
    error "unable to determine deps without issuing a dump"
    return
  result = parseRequires(project.dump["requires"])
  if result.isSome:
    # this is (usually) gratuitous, but it's also the right place
    # to perform this assignment, so...  go ahead and do it
    for a, b in result.get.mpairs:
      a.notes = project.name
      b.notes = project.name

proc determineDeps*(project: var Project): Option[Requires] =
  ## try to parse requirements of a (mutable) project
  if not project.fetchDump:
    debug "nimble dump failed, so computing deps is impossible"
    return
  let
    immutable = project
  result = determineDeps(immutable)

proc peelRelease*(project: Project; release: Release): Release =
  var
    thing: GitThing
  result = release

  # if there's no way to peel it, just bail
  if project.dist != Git or result.kind != Tag:
    return

  # else, look up the reference
  gitTrap thing, lookupThing(thing, project.repo, result.reference):
    warn &"unable to find release reference `{result.reference}`"
    return

  # it's a valid reference, let's try to convert it to a release
  case thing.kind:
  of goTag:
    # the reference is a tag, so we need to resolve the target oid
    result = project.peelRelease newRelease($thing.targetId,
                                            operator = Tag)
  of goCommit:
    # good; we found a matching commit
    result = newRelease($thing.oid, operator = Tag)
  else:
    # otherwise, it's some kinda git object we don't grok
    let emsg = &"{thing.kind} references unimplemented" # noqa
    raise newException(ValueError, emsg)

proc peelRelease*(project: Project): Release =
  result = project.peelRelease(project.release)

iterator matchingReleases(requirement: Requirement; head = "";
                          tags: GitTagTable = nil): Release =
  ## yield releases that satisfy the requirement, using the head and tags
  case requirement.release.kind:
  of Tag:
    let reference = requirement.release.reference
    # recognize "head" as matching a provided head oid
    if reference.toLowerAscii == "head":
      # if it exists, i mean
      if head != "":
        yield newRelease(head, operator = Tag)
    else:
      # if we have tags to work with, then we try to match
      # against the tag and include the hash of the tag's oid
      if tags != nil:
        # this could be looking for `head`, by the way...
        if tags.hasKey(reference):
          if reference.toLowerAscii != "head":
            yield newRelease($tags[reference].oid, operator = Tag)
          else:
            debug "found `head` in the tags table"
        # now see if the specified reference matches a tag
        for name, thing in tags.pairs:
          if reference.toLowerAscii == $thing.oid:
            yield newRelease($thing.oid, operator = Tag)
        # we won't actually lookup a missing reference here; that really
        # should be done in a proc that has access to the project
  else:
    # we just iterate over all the tags and see any can be
    # converted to a version which satisfies the requirement
    if tags != nil:
      for name, thing in tags.pairs:
        let parsed = name.parseVersionLoosely
        if parsed.isNone:
          debug &"could not parse tag `{name}`"
          continue
        if requirement.isSatisfiedBy(parsed.get):
          yield newRelease($thing.oid, operator = Tag)

iterator symbolicMatch*(project: Project; req: Requirement): Release =
  ## see if a project can match a given requirement symbolically
  if project.tags == nil:
    raise newException(Defect, "fetch tags for the project first")
  if project.dist == Git:
    if project.tags == nil:
      warn &"i wanted to examine tags for {project} but they were empty"
      raise newException(Defect, "seems like a programmer error to me")
    let
      gotHead = project.getHeadOid
      head = if gotHead.isSome: $gotHead.get else: ""
    for release in req.matchingReleases(head = head, tags = project.tags):
      debug &"release match {release} for {req}"
      yield release
    # here we will try to lookup any random reference requirement, just in case
    #
    # this currently could duplicate a release emitted above, but that's okay
    if req.release.kind == Tag:
      var thing: GitThing
      if grcOk == lookupThing(thing, project.repo, req.release.reference):
        debug &"found {req.release.reference} in {project}"
        yield newRelease($thing.oid, operator = Tag)
      else:
        debug &"could not find {req.release.reference} in {project}"
  else:
    debug &"without a repo for {project.name}, i cannot match {req}"
    # if we don't have any tags or the head, it's a simple test
    if req.isSatisfiedBy(project.release):
      yield project.release

proc symbolicMatch*(project: Project; req: Requirement; release: Release): bool =
  ## convenience
  if project.tags == nil:
    raise newException(Defect, "fetch tags for the project first")
  let release = project.peelRelease(release)
  for match in project.symbolicMatch(req):
    result = match == release
    if result:
      break

proc symbolicMatch*(project: var Project; req: Requirement; release: Release): bool =
  ## convenience
  if project.tags == nil:
    project.fetchTagTable
  let readonly = project
  result = readonly.symbolicMatch(req, release)

proc symbolicMatch*(project: Project; req: Requirement): bool =
  ## convenience
  if project.tags == nil:
    raise newException(Defect, "fetch tags for the project first")
  for match in project.symbolicMatch(req):
    result = true
    break

proc symbolicMatch*(project: var Project; req: Requirement): bool =
  ## convenience
  if project.tags == nil:
    project.fetchTagTable
  let readonly = project
  result = readonly.symbolicMatch(req)

proc isSatisfiedBy(req: Requirement; project: Project; release: Release): bool =
  block satisfied:
    if req.release.kind == Tag:
      # the requirement is for a particular tag...
      # compare tags, head, and versions
      result = project.symbolicMatch(req, release)
      debug &"project symbolic match {result} {req}"
      # if the tag doesn't match, make sure we fail hard here
      break

    # otherwise, if all we have is a tag but the requirement is for
    # something version-like, then we have to just use the version;
    # ditto if we don't even have a valid release, of course
    elif not project.release.isValid or project.release.kind == Tag:
      if project.version.isValid:
        # fallback to the version indicated by nimble
        result = req.isSatisfiedBy newRelease(project.version)
        debug &"project version match {result} {req}"
      # we did our best
      break

    # the project.release is valid and it's not a tag.
    #
    # first we wanna see if our version is specific; if it is, we
    # will just see if that specific incarnation satisfies the req
    if project.release.isSpecific:
      # try to use our release
      result = req.isSatisfiedBy newRelease(project.release.specifically)
      debug &"project release match {result} {req}"
      break

  # make sure we can satisfy prior requirements as well
  if result and req.child != nil:
    result = req.child.isSatisfiedBy(project, release)

proc isSatisfiedBy(req: Requirement; project: Project): bool =
  ## true if a requirement is satisfied by the given project,
  ## at any known/available version for the project
  # first, check that the identity matches
  if project.name == req.identity:
    result = true
  elif req.isUrl:
    let
      url = req.toUrl
    if url.isSome:
      let
        x = project.url.convertToGit
        y = url.get.convertToGit
      result = x == y or bareUrlsAreEqual(x, y)
  # if the name doesn't match, let's just bomb early
  if not result:
    return
  # now we need to confirm that the version will work
  result = block:
    # if the project's release satisfies the requirement, great
    if req.isSatisfiedBy(project, project.release):
      true
    # it's also fine if the project can symbolically satisfy the requirement
    elif project.symbolicMatch(req):
      true
    # else we really have no reason to think we can satisfy the requirement
    else:
      false

  # make sure we can satisfy prior requirements as well
  if result and req.child != nil:
    result = req.child.isSatisfiedBy(project)

{.warning: "nim bug #12818".}
proc get*[K: Requirement, V](group: Group[K, V]; key: Requirement): V =
  ## fetch a dependency from the group using the requirement
  result = group.table[key]

proc mget*[K: Requirement, V](group: var Group[K, V]; key: K): var V =
  ## fetch a dependency from the group using the requirement
  result = group.table[key]

proc addName(dependency: var Dependency; name: string) =
  ## add an import name to the dependency, as might be used in code
  let
    package = name.importName
  if package notin dependency.names:
    dependency.names.add package

proc add(dependency: var Dependency; package: Package) =
  ## add a package to the dependency
  if package.url notin dependency.packages:
    dependency.packages.add package.url, package
  dependency.addName package.importName

proc add(dependency: var Dependency; url: Uri) =
  ## add a url (as a package) to the dependency
  dependency.add newPackage(url = url)

proc add(dependency: var Dependency; packages: PackageGroup) =
  ## add a group of packages to the dependency
  for package in packages.values:
    dependency.add package

proc add(dependency: var Dependency; directory: string; project: Project) =
  ## add a local project in the given directory to an existing dependency
  if dependency.projects.hasKey(directory):
    raise newException(Defect, "attempt to duplicate project dependency")
  dependency.projects.add directory, project
  dependency.addName project.name
  # this'll help anyone sniffing around thinking packages precede projects
  dependency.add project.asPackage

proc newDependency*(project: Project): Dependency =
  ## convenience to form a new dependency on a specific project
  let
    requirement = newRequirement(project.name, Equal, project.release)
  requirement.notes = project.name
  result = newDependency(requirement)
  result.add project.repo, project

proc mergeContents(existing: var Dependency; dependency: Dependency): bool =
  ## combine two dependencies and yield true if a new project is added
  # add the requirement to the existing requirement
  existing.requirement.adopt dependency.requirement
  # adding the packages as a group will work
  existing.add dependency.packages
  # add projects according to their repo
  for directory, project in dependency.projects.pairs:
    if directory in existing.projects:
      continue
    existing.projects.add directory, project
    result = true

proc addName(group: var DependencyGroup; req: Requirement; dep: Dependency) =
  ## add any import names from the dependency into the dependency group
  for directory, project in dep.projects.pairs:
    let name = project.importName
    if name notin group.imports:
      group.imports[name] = directory
    elif group.imports[name] != directory:
      warn &"name collision for import `{name}`:"
      for path in [directory, group.imports[name]]:
        warn &"\t{path}"
  when defined(debugImportNames):
    when not defined(release) and not defined(danger):
      for name in dep.names.items:
        if not group.imports.hasKey(name):
          warn &"{name} was in {dep.names} but not group names:"
          warn $group.imports
        assert group.imports.hasKey(name)

proc add*(group: var DependencyGroup; req: Requirement; dep: Dependency) =
  group.table.add req, dep
  group.addName req, dep

proc addedRequirements(dependencies: var DependencyGroup;
                       dependency: var Dependency): bool =
  ## add a dependency to the group and return true if the
  ## addition added new requirements to the group
  let
    required = dependency.requirement
  var
    existing: Dependency

  # look for an existing dependency to merge into
  block found:
    # check to see if an existing project will work
    for req, dep in dependencies.mpairs:
      for directory, project in dep.projects.pairs:
        if required.isSatisfiedBy(project):
          existing = dep
          break found
    # failing that, check to see if an existing package matches
    for req, dep in dependencies.mpairs:
      for url, package in dep.packages.pairs:
        if package.url in dependency.packages:
          existing = dep
          break found
    # found nothing; install the dependency in the group
    dependencies.add required, dependency
    # we've added requirements we can analyze only if projects exist
    result = dependency.projects.len > 0

  # if we found a good merge target, then merge our existing dependency
  if existing != nil:
    result = existing.mergeContents dependency
    # point to the merged dependency
    dependency = existing

proc pathForName*(dependencies: DependencyGroup; name: string): Option[string] =
  ## try to retrieve the directory for a given import
  if dependencies.imports.hasKey(name):
    result = dependencies.imports[name].some

proc projectForPath*(deps: DependencyGroup; path: string): Option[Project] =
  ## retrieve a project from the dependencies using its path
  for dependency in deps.values:
    if dependency.projects.hasKey(path):
      result = dependency.projects[path].some
      break

proc reqForProject*(group: DependencyGroup; project: Project): Option[Requirement] =
  ## try to retrieve a requirement given a project
  for requirement, dependency in group.pairs:
    if project in dependency.projects:
      result = requirement.some
      break

proc projectForName*(group: DependencyGroup; name: string): Option[Project] =
  ## try to retrieve a project given an import name
  let
    path = group.pathForName(name)
  if path.isNone:
    return
  result = group.projectForPath(path.get)

proc isHappy*(dependency: Dependency): bool =
  ## true if the dependency is being met successfully
  result = dependency.projects.len > 0

proc isHappyWithVersion*(dependency: Dependency): bool =
  ## true if the dependency is happy with the version of the project
  for project in dependency.projects.values:
    result = dependency.requirement.isSatisfiedBy(project, project.release)
    if result:
      break

proc resolveUsing*(projects: ProjectGroup; packages: PackageGroup;
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

proc resolve*(project: Project; deps: var DependencyGroup;
              req: Requirement): bool

proc resolve*(project: var Project; dependencies: var DependencyGroup): bool =
  ## resolve a project's dependencies recursively; store result in dependencies

  # assert a usable config
  assert project.cfg != nil

  if Flag.Quiet notin dependencies.flags:
    info &"{project.cuteRelease:>8} {project.name:>12}   {project.releaseSummary}"

  # assume innocence until the guilt is staining the carpet in the den
  result = true

  block complete:
    # start with determining the dependencies of the project
    let requires = project.determineDeps
    if requires.isNone:
      warn &"no requirements found for {project}"
      break complete

    # next, iterate over each requirement
    for requirement in requires.get.values:
      # and if it's not "virtual" (ie. the compiler)
      if requirement.isVirtual:
        continue
      # and we haven't already processed the same exact requirement
      if dependencies.table.hasKey(requirement):
        continue
      # then try to stay truthy while resolving that requirement, too
      result = result and project.resolve(dependencies, requirement)
      # if we failed, there's no point in continuing
      if not result:
        break complete

proc resolve*(project: Project; deps: var DependencyGroup;
             req: Requirement): bool =
  ## resolve a single project's requirement, storing the result
  var resolved = resolveUsing(deps.projects, deps.packages, req)
  case resolved.packages.len:
  of 0:
    warn &"unable to resolve requirement `{req}`"
    result = false
    return
  of 1:
    discard
  else:
    project.reportMultipleResolutions(req, resolved.packages)

  # this game is now ours to lose
  result = true

  block complete:
    # if the addition of the dependency is not novel, we're done
    if not deps.addedRequirements(resolved):
      break complete

    # else, we'll resolve dependencies introduced in any new dependencies.
    # note: we're using project.cfg and project.repo as a kind of scope
    for recurse in resolved.projects.asFoundVia(project.cfg, project.repo):
      # if one of the existing dependencies is using the same project, then
      # we won't bother to recurse into it and process its requirements
      if deps.isUsing(recurse.nimble, outside = resolved):
        continue
      result = result and recurse.resolve(deps)
      # if we failed, there's no point in continuing
      if not result:
        break complete

proc getOfficialPackages(project: Project): PackagesResult =
  result = getOfficialPackages(project.nimbleDir)

proc newDependencyGroup*(project: Project;
                         flags = defaultFlags): DependencyGroup =
  ## a convenience to load packages and projects for resolution
  result = newDependencyGroup(flags)

  # try to load the official packages list; either way, a group will exist
  let official = project.getOfficialPackages
  result.packages = official.packages

  # collect all the packages from the environment
  result.projects = project.childProjects

proc setHeadToRelease*(project: var Project; release: Release): bool =
  ## advance the head of a project to a particular release
  if project.dist != Git:
    return
  if not release.isValid or release.kind != Tag:
    return
  # we want the code because it'll tell us what went wrong
  let code = checkoutTree(project.repo, release.reference)
  case code:
  of grcOk:
    debug &"roll {project.name} to {release}"
    result = true
    # make sure we invalidate some data
    project.dump = nil
    project.version = (0'u, 0'u, 0'u)
  else:
    debug &"roll {project.name} to {release}: {code}"

proc rollTowards*(project: var Project; requirement: Requirement): bool =
  ## advance the head of a project to meet a given requirement
  if project.dist != Git:
    return
  if project.tags == nil:
    project.fetchTagTable

  # reverse the order of matching releases so that we start with the latest
  # valid release, first and proceed to lesser versions thereafter
  var releases = toSeq project.symbolicMatch(requirement)
  releases.reverse

  # iterate over all matching tags
  for match in releases.items:
    # try to point to the matching release
    result = project.setHeadToRelease(match)
    if not result:
      warn &"failed checkout of {match}"
      continue
    # freshen project version, release, etc.
    project.refresh
    # then, maybe rename the directory appropriately
    if project.parent != nil:
      project.parent.relocateDependency(project)
    break

proc addName*(group: var VersionTags; ver: Version; thing: GitThing) =
  group.imports[$ver] = $thing.oid

proc add*(group: var VersionTags; ver: Version; thing: GitThing) =
  group.table.add ver, thing
  group.addName ver, thing

proc del*(group: var VersionTags; ver: Version) =
  ## remove a version from the group
  if group.table.hasKey(ver):
    group.delName $group.table[ver].oid
    group.table.del ver

proc `[]=`*(group: var VersionTags; ver: Version; thing: GitThing) =
  ## set a key to a single value
  group.del ver
  group.add ver, thing

proc `[]`*(group: VersionTags; ver: Version): var GitThing =
  ## get a git thing by version
  result = group.table[ver]

proc newVersionTags(flags = defaultFlags): VersionTags =
  result = VersionTags(flags: flags)
  result.init(flags, mode = modeStyleInsensitive)

template returnToHeadAfter*(project: var Project; body: untyped) =
  ## run some code in the body if you can, and then return the
  ## project to where it was in git before you left

  # we may have no head; if that's the case, we have no tags either
  let previous = project.getHeadOid
  if previous.isSome:

    # this could just be a bad idea all the way aroun'
    if not project.repoLockReady:
      error "refusing to roll the repo when it's dirty"
    else:
      # if we have no way to get back, don't even depart
      var home: GitReference
      gitTrap home, referenceDWIM(home, project.repo, "HEAD"):
        raise newException(IOError, "i'm lost; where am i?")

      defer:
        # there's no place like home
        if not project.setHeadToRelease(newRelease($previous.get,
                                                   operator = Tag)):
          raise newException(IOError, "cannot detach head to " & $previous.get)

        # re-attach the head if we can
        gitTrap setHead(project.repo, $home.name):
          raise newException(IOError, "cannot set head to " & home.name)

        # be sure to reload the project specifics now that we're home
        project.refresh

      body

proc versionChangingCommits*(project: var Project): VersionTags =
  # a table of the commits that changed the Version of a Project's
  # dotNimble file
  result = newVersionTags()
  let
    # this is the package.nimble file without any other path parts
    package = project.nimble.package.addFileExt(project.nimble.ext)

  project.returnToHeadAfter:
    # iterate over commits to the dotNimble file
    for commit in commitsForSpec(project.repo, @[package]):
      var
        thing = commit.toThing
      let release = newRelease($thing.oid, operator = Tag)
      if not project.setHeadToRelease(release):
        continue
      # freshen project version, release, etc.
      project.refresh
      result[project.version] = thing

proc reset*(dependencies: var DependencyGroup; project: var Project) =
  ## reset a dependency group and prepare to resolve dependencies again
  # empty the group of all requirements and dependencies
  dependencies.clear
  # reset the project's configuration to find new paths, etc.
  project.cfg = loadAllCfgs(project.repo)
  # rescan for package dependencies applicable to this project
  dependencies.projects = project.childProjects

proc roll*(project: var Project; requirement: Requirement;
           goal: RollGoal; dry_run = false): bool =
  ## true if the project is fully upgraded per the requirement
  if project.dist != Git:
    return
  if project.tags == nil:
    project.fetchTagTable
  let
    current = project.version
    head = project.getHeadOid

  # up-to-date until proven otherwise
  result = true

  # no head means that we're up-to-date, obviously
  if head.isNone:
    return

  var
    releases = toSeq project.symbolicMatch(requirement)
  case goal:
  of Upgrade:
    releases.reverse
  of Downgrade:
    discard
  of Specific:
    raise newException(Defect, "not implemented")

  # iterate over all matching tags
  for match in releases:
    # if we're at the next best release then we're done
    if match.kind == Tag and match.reference == $head.get:
      break

    # make a friendly name for the future version
    let
      friendly = block:
        if match.kind in {Tag}:
          project.tags.shortestTag(match.reference)
        else:
          $match
    if dry_run:
      # make some noise and don't actually do anything
      info &"would {goal} {project.name} from {current} to {friendly}"
      result = false
      break

    # make sure we don't do something stupid
    if not project.repoLockReady:
      error &"refusing to roll {project.name} 'cause it's dirty"
      result = false
      break

    # try to point to the matching release
    result = project.setHeadToRelease(match)
    if not result:
      warn &"failed checkout of {match}"
      continue
    else:
      notice &"rolled {project.name} from {current} to {friendly}"
    # freshen project version, release, etc.
    project.refresh
    # then, maybe rename the directory appropriately
    if project.parent != nil:
      project.parent.relocateDependency(project)
    result = true
    break
