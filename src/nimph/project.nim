#[

this is the workflow we want...

git clone --depth 1 --branch 1.8.0 someurl somedir

  ... later ...

git fetch origin tag 1.8.1
git checkout 1.8.1

some outstanding issues:

✅clone a repo from a url;
❌shallow clone with only the most recent reference?
✅rename package directory to match nimble semantics;
✅determine a url for the original repo -- use origin;
✅determine the appropriate reference to add to the anchor;
✅does the current commit match an existing tag?


]#

import std/hashes
import std/sets
import std/strutils
import std/tables
import std/uri
import std/options
import std/strformat
import std/os
import std/osproc
import std/sequtils
import std/strtabs

import bump

import nimph/spec
import nimph/config
import nimph/nimble
import nimph/git
import nimph/package
import nimph/version

type
  Project* = ref object
    name*: string
    nimble*: Target
    version*: Version
    dist*: DistMethod
    release*: Release
    dump*: StringTableRef
    config*: NimphConfig
    cfg*: ConfigRef
    deps*: PackageGroup
    tags*: GitTagTable
    refs*: Releases
    meta*: NimbleMeta
    url*: Uri
    parent*: Project

  ProjectGroup* = ref object
    table*: TableRef[string, Project]

  Dependency* = object
    url*: Uri
    operator*: Operator

  Releases* = TableRef[string, Release]

template repo*(project: Project): string = project.nimble.repo
template gitDir*(project: Project): string = project.repo / dotGit
template hasGit*(project: Project): bool = dirExists(project.gitDir)
template hgDir*(project: Project): string = project.repo / dotHg
template hasHg*(project: Project): bool = dirExists(project.hgDir)
template nimphConfig*(project: Project): string = project.repo / configFile
template hasNimph*(project: Project): bool = fileExists(project.nimphConfig)

proc nimbleDir*(project: Project): string =
  ## the path to the project's dependencies
  if project.parent != nil:
    result = project.parent.nimbleDir
  else:
    var
      localdeps = project.repo / DepDir
      globaldeps = getHomeDir() / dotNimble
    if dirExists(localdeps):
      result = localdeps
    else:
      result = globaldeps
    result = absolutePath(result).normalizedPath

proc `$`*(project: Project): string =
  result = &"{project.name}-{project.release}"

proc runNimble*(project: Project; args: seq[string]): RunNimbleOutput =
  ## run nimble against a particular project
  var
    arguments = concat(@["--nimbleDir=" & project.nimbleDir], args)
  # the ol' belt-and-suspenders approach to specifying nimbleDir
  putEnv("NIMBLE_DIR", project.nimbleDir)
  result = runNimble(arguments, {poParentStreams})

proc guessVersion*(project: Project): Version =
  ## a poor man's measure of project version; pukes on comments
  let
    contents = readFile($project.nimble)
    parsed = parseVersion(contents)

  if parsed.isNone:
    debug &"unable to parse version from {project.nimble}"
  else:
    result = parsed.get
    if not result.isValid:
      error &"the version in {project.nimble} seems to be invalid"

proc fetchDump*(project: var Project; package: string;
               refresh = false): bool =
  ## make sure the nimble dump is available
  if project.dump == nil or refresh:
    let
      dumped = fetchNimbleDump(package)
    if not dumped.ok:
      result = false
      # puke on this for now...
      raise newException(IOError, dumped.why)
    else:
      # try to prevent a bug when the above changes
      result = true
      project.dump = dumped.table
      return
  else:
    result = true

proc fetchDump*(project: var Project; refresh = false): bool {.discardable.} =
  ## make sure the nimble dump is available
  result = project.fetchDump(project.nimble.repo, refresh = refresh)

proc knowVersion*(project: var Project): Version =
  ## pull out all the stops to determine the version of a project
  if project.dump != nil:
    if "version" in project.dump:
      let
        text {.used.} = project.dump["version"]
        parsed = parseVersion(&"""version = "{text}"""")
      if parsed.isSome:
        debug "parsed a version from `nimble dump`"
        result = parsed.get
      else:
        raise newException(IOError, &"dump yielded unparsable version `{text}`")
      return
  result = project.guessVersion
  if result.isValid:
    debug &"parsed a version from {project.nimble}"
    return
  if project.fetchDump():
    result = project.knowVersion
    return
  raise newException(IOError, "unable to determine {project.package} version")

proc nimCfg*(project: Project): Target =
  result = newTarget(project.nimble.repo / NimCfg)

proc newProject*(nimble: Target): Project =
  ## instantiate a new project from the given .nimble
  new result
  if not fileExists($nimble):
    raise newException(ValueError,
                       "unable to instantiate a project w/o a " & dotNimble)
  let
    splat = absolutePath($nimble).normalizedPath.splitFile
  result.nimble = (repo: splat.dir, package: splat.name, ext: splat.ext)
  result.name = splat.name
  result.config = newNimphConfig(splat.dir / configFile)
  result.refs = newTable[string, Release]()

proc getHeadOid(repository: GitRepository): GitOid =
  var
    head: GitReference
  gitTrap head, repositoryHead(head, repository):
    warn "error fetching repo head"
    return
  result = head.oid

proc getHeadOid(path: string): GitOid =
  var
    open: GitOpen
  withGit:
    gitTrap openRepository(open, path):
      warn &"error opening repository {path}"
      return
    result = open.repo.getHeadOid

proc getHeadOid(project: Project): GitOid =
  if not project.hasGit:
    raise newException(Defect, &"{project} lacks a git repository to load")
  result = getHeadOid(project.gitDir)

proc relocateDependency(project: Project; package: var Project) =
  ## try to rename a package to more accurately reflect tag or version
  let
    repository = repo(package)
    current = repository.lastPathPart
  var
    name = package.name & "-" & $package.release
  if package.release in {Tag}:
    # use the nimble style of package-#head when appropriate
    if $package.getHeadOid == package.release.reference:
      name = package.name & "-" & "#head"
  if current == name:
    return
  let
    splat = repository.splitFile
    future = splat.dir / name
  if dirExists(future):
    warn &"cannot rename `{current}` to `{name}` -- already exists"
  else:
    moveDir(repository, future)

proc hasReleaseTag(project: Project): bool =
  result = project.release.kind == Tag

proc fetchTagTable*(project: var Project): GitTagTable {.discardable.} =
  var
    opened: GitOpen
  withGit:
    gitTrap opened, openRepository(opened, project.repo):
      let path {.used.} = project.repo # template reasons
      warn &"error opening repository {path}"
      return
    gitTrap tagTable(opened.repo, result):
      let path {.used.} = project.repo # template reasons
      warn &"unable to fetch tags from repo in {path}"
      return
    project.tags = result

proc findCurrentTag*(project: Project): Release =
  let
    head = project.getHeadOid
  var
    name: string
  if project.tags == nil:
    error "unable to determine tags without fetching them from git"
    name = $head
  else:
    block search:
      for tag, target in project.tags.pairs:
        if target.oid == head:
          name = $tag
          info &"{project.name} positioned at {name}"
          break search
      name = $head
  result = newRelease(name, operator = Tag)

proc findCurrentTag*(project: var Project): Release =
  let
    readonly = project
  if project.tags == nil:
    project.fetchTagTable
  result = readonly.findCurrentTag

proc inventRelease(project: var Project): Release {.discardable.} =
  ## compute the most accurate release specification for the project
  if project.hasGit:
    project.release = project.findCurrentTag
  elif project.url.anchor.len > 0:
    project.release = newRelease(project.url.anchor, operator = Tag)
  elif project.version.isValid:
    project.release = newRelease(project.version)
  else:
    # grab the directory name
    let name = repo(project).lastPathPart
    # maybe it's package-something
    var prefix = project.name & "-"
    if name.startsWith(prefix):
      # i'm lazy
      let release = newRelease(name.split(prefix)[^1])
      if release.kind in {Tag, Equal}:
        warn &"had to resort to parsing reference from directory `{name}`"
        project.release = release
      else:
        warn &"unable to parse reference from directory `{name}`"
  result = project.release

proc guessDist(project: Project): DistMethod =
  ## guess at the distribution method used to deposit the assets
  if project.hasGit:
    result = Git
  elif project.hasHg:
    result = Merc
#  elif project.hasNimph:
#    result = Nest
  else:
    result = Local

proc followFoundTarget(dir: string): SearchResult =
  ## recurse through .nimble-link files to find the .nimble
  result = findTarget(dir, extensions = @[dotNimble, dotNimbleLink])
  if result.found.isNone:
    return
  let found = result.found.get
  if found.ext == dotNimble:
    return
  for line in lines($found):
    if fileExists(line):
      result.message = &"followed {found}"
      result.found = newTarget(line).some
      return
  result.message = &"{found} didn't lead to a {dotNimble}"
  result.found = none(Target)

proc findProject*(project: var Project; dir = "."): bool =
  ## locate a project starting from `dir`
  let
    target = followFoundTarget(dir)
  if target.found.isNone:
    if target.message != "":
      error target.message
    return
  # this is a hack but i wanna keep my eye on this for now...
  elif target.message.startsWith("followed"):
    warn target.message
  project = newProject(target.found.get)
  project.meta = fetchNimbleMeta(repo(project))
  project.dist = project.guessDist
  if project.meta.hasUrl:
    project.url = project.meta.url
  project.version = project.knowVersion
  project.inventRelease
  if project.release.isValid:
    debug &"{project} release {project.release}"
  else:
    error &"unable to determine reference for {project}"
    return
  result = true

template packageDirectory(project: Project): string = project.nimbleDir / PkgDir

iterator packageDirectories(project: Project): string =
  let
    pkgs = packageDirectory(project)
  if dirExists(pkgs):
    for component, directory in walkDir(pkgs):
      if component notin {pcDir, pcLinkToDir}:
        continue
      yield directory

proc add(group: ProjectGroup; name: string; project: Project) =
  group.table.add name, project

proc newProjectGroup(): ProjectGroup =
  result = ProjectGroup()
  result.table = newTable[string, Project]()

proc pathToImport(path: string): string =
  result = path.extractFilename.split("-")[0]

iterator pairs*(group: ProjectGroup): tuple[name: string; project: Project] =
  for directory, project in group.table.pairs:
    yield (name: directory.pathToImport, project: project)

iterator values*(group: ProjectGroup): Project =
  for project in group.table.values:
    yield project

iterator mvalues*(group: ProjectGroup): var Project =
  for project in group.table.mvalues:
    yield project

proc hasProjectIn(group: ProjectGroup; directory: string): bool =
  result = group.table.hasKey(directory)

proc getProjectIn(group: ProjectGroup; directory: string): Project =
  result = group.table[directory]

proc mgetProjectIn(group: var ProjectGroup; directory: string): var Project =
  result = group.table[directory]

proc availableProjects*(path: string): ProjectGroup =
  ## find packages locally available to a project; note that
  ## this can include the project itself -- perfectly fine
  result = newProjectGroup()
  for component, directory in walkDir(path):
    if component notin {pcDir, pcLinkToDir}:
      continue
    var
      package: Project
    if findProject(package, directory):
      result.add directory, package
    else:
      warn &"unable to identify package in {directory}"

proc childProjects*(project: Project): ProjectGroup =
  ## convenience
  result = availableProjects(packageDirectory(project))
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

proc `==`*(a, b: Project): bool =
  ## a dirty (if safe) way to compare equality of projects
  let
    apath = $a.nimble
    bpath = $b.nimble
  if apath == bpath:
    result = true
  else:
    debug "had to use samefile to compare {apath} to {bpath}"
    result = sameFile(apath, bpath)

proc isValid*(url: Uri): bool =
  result = url.scheme.len != 0

proc findRepositoryUrl(path: string): Option[Uri] =
  var
    remote: GitRemote
    open: GitOpen
    name = defaultRemote

  withGit:
    gitTrap openRepository(open, path):
      warn &"error opening repository {path}"
      return
    gitTrap remote, remoteLookup(remote, open.repo, defaultRemote):
      warn &"unable to fetch remote `{name}` from repo in {path}"
      return
    try:
      let url = remote.url
      if url.isValid:
        result = remote.url.some
    except:
      warn &"unable to parse url from remote `{name}` from repo in {path}"

proc createUrl(project: Project; dist: DistMethod): Uri =
  ## determine the source url for a project which may be local
  assert dist == project.guessDist
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

proc asPackage(project: Project): Package =
  ## cast a project to a package
  let
    dist = project.guessDist

  result = newPackage(name = project.name,
                      dist = dist,
                      url = project.createUrl(dist))

proc releaseSymbols(release: Release; head = "";
                    tags: GitTagTable = nil): HashSet[Hash] =
  if release.kind != Tag:
    raise newException(Defect, &"why are you calling this on {release.kind}?")
  if release.reference.toLowerAscii == "head":
    if head != "":
      result.incl head.hash
  else:
    result.incl release.reference.hash
  if tags != nil:
    if tags.hasKey(release.reference):
      result.incl hash($tags[release.reference].oid)

proc symbolicMatch(req: Requirement; release: Release; head = "";
                   tags: GitTagTable = nil): bool =
  if req.operator notin {Equal, Tag} or release.kind != Tag:
    return

  let
    required = releaseSymbols(req.release, head, tags = tags)
    provided = releaseSymbols(release, head, tags = tags)
  result = len(required * provided) > 0

proc symbolicMatch(project: Project; req: Requirement): bool =
  if project.hasGit:
    if project.tags == nil:
      warn &"i wanted to examine tags for {project} but they were empty"
    result = symbolicMatch(req, project.release, $project.getHeadOid,
                           tags = project.tags)
  else:
    warn &"without a git repo for {project.name}, i cannot determine tags"
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
    result = project.release in req
    # if we want #head, see if the current position is also #head
    if project.symbolicMatch(req):
      result = true
    # else, if we have a version number and the requirement isn't for
    # a particular tag, then accept a matching version release
    elif project.version.isValid:
      result = result or newRelease(project.version) in req

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
    result.add repo(available), available.asPackage

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
      debug "ignoring virtual dependency:", requirement
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
      warn &"found {resolved.len} options for {requirement} dependency:"
      var
        count = 1
      for name, package in resolved.pairs:
        warn &"{count}\t{name}"
        warn &"\t{package.url}\n"
        count.inc
    for name, package in resolved.pairs:
      if name notin dependencies:
        debug name, "-->", $package.url
        dependencies.add name, package
    for name, package in resolved.pairs:
      if projects.hasProjectIn(name):
        var
          recurse = projects.mgetProjectIn(name)
        result = result and recurse.resolveDependencies(projects, packages,
                                                        dependencies)

proc resolveDependencies*(project: var Project;
                          dependencies: var PackageGroup): bool =
  let
    findPacks = getOfficialPackages(project.nimbleDir)
  var
    packages: PackageGroup
    projects = project.childProjects

  if not findPacks.ok:
    packages = newPackageGroup()
  else:
    packages = findPacks.packages

  result = project.resolveDependencies(projects, packages, dependencies)

proc clone*(project: var Project; url: Uri; name: string): bool =
  ## clone a package into the project's nimbleDir
  withGit:
    var
      bare = url
      tag: string
      directory = project.nimbleDir / PkgDir / name

    if bare.anchor != "":
      tag = bare.anchor
    bare.anchor = ""

    when false:
      discard
      # FIXME: we should probably clone into a temporary directory that we
      # can confirm does not exist; then investigate the contents and consider
      # renaming it to match its commit hash or tag.
    else:
      if tag == "":
        directory &= "-#head"
      else:
        # FIXME: not sure how we want to handle this; all refs should be treated
        # the same, but for nimble-compat reasons, we may want to strip the #
        # prefix from a version tag...
        let
          isVersion = parseVersion(&"""version = "{tag}"""")
        if isVersion.isSome:
          directory &= "-" & tag
        else:
          directory &= "-#" & tag

    info &"cloning {bare} ..."
    info &"... into {directory}"

    var
      got: GitClone
    gitTrap got, clone(got, bare, directory):
      return

    var
      proj: Project
    if findProject(proj, directory):
      if not writeNimbleMeta(directory, bare, $getHeadOid(got.repo)):
        warn &"unable to write {nimbleMeta} in {directory}"
      project.relocateDependency(proj)
    else:
      error "couldn't make sense of the project i just cloned"

    result = true
