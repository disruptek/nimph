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

import std/math
import std/hashes
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
    # unused yet
    config*: NimphConfig
    cfg*: ConfigRef
    mycfg*: ConfigRef
    # unused yet
    #deps*: PackageGroup
    tags*: GitTagTable
    # unused yet
    #refs*: Releases
    meta*: NimbleMeta
    url*: Uri
    parent*: Project
    develop*: LinkedSearchResult

  ProjectGroup* = ref object
    table*: TableRef[string, Project]

  Dependency* = object
    url*: Uri
    operator*: Operator

  Releases* = TableRef[string, Release]

  LinkedSearchResult* = ref object
    via: LinkedSearchResult
    source: string
    search: SearchResult

template repo*(project: Project): string = project.nimble.repo
template gitDir*(project: Project): string = project.repo / dotGit
template hasGit*(project: Project): bool = dirExists(project.gitDir)
template hgDir*(project: Project): string = project.repo / dotHg
template hasHg*(project: Project): bool = dirExists(project.hgDir)
template nimphConfig*(project: Project): string = project.repo / configFile
template hasNimph*(project: Project): bool = fileExists(project.nimphConfig)
template localDeps*(project: Project): string = project.repo / DepDir / ""

proc hasLocalDeps*(project: Project): bool =
  result = dirExists(project.localDeps)

proc nimbleDir*(project: Project): string =
  ## the path to the project's dependencies
  var
    globaldeps = getHomeDir() / dotNimble / ""

  # if we instantiated this project from another, the implication is that we
  # want to point at whatever that parent project is using as its nimbleDir.
  if project.parent != nil:
    result = project.parent.nimbleDir

  # otherwise, if we have configuration data, we should use it to determine
  # what the user might be using as a package directory -- local or elsewise
  elif project.cfg != nil:
    result = project.cfg.suggestNimbleDir(project.repo,
                                          local = project.localDeps,
                                          global = globaldeps)

  # otherwise, we'll just presume some configuration-free defaults
  else:
    if project.hasLocalDeps:
      result = project.localDeps
    else:
      result = globaldeps
    result = absolutePath(result).normalizedPath

proc `$`*(project: Project): string =
  result = &"{project.name}-{project.release}"

proc runNimble*(project: Project; args: seq[string]): RunNimbleOutput =
  ## run nimble against a particular project
  var
    arguments = @["--nimbleDir=" & project.nimbleDir].concat args
  when defined(debug):
    arguments = @["--verbose"].concat arguments
  when defined(debugNimble):
    arguments = @["--debug"].concat arguments
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
        when defined(debug):
          debug "parsed a version from `nimble dump`"
        result = parsed.get
      else:
        raise newException(IOError,
                           &"unparsable version `{text}` in {project.name}")
      return
  result = project.guessVersion
  if result.isValid:
    when defined(debug):
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

proc getHeadOid(path: string): GitOid =
  var
    open: GitOpen
  withGit:
    gitTrap openRepository(open, path):
      warn &"error opening repository {path}"
      return
    result = open.repo.getHeadOid

proc getHeadOid*(project: Project): GitOid =
  if project.dist != Git:
    raise newException(Defect, &"{project} lacks a git repository to load")
  result = getHeadOid(project.gitDir)

proc parseVersionFromTag(tag: string): Version =
  {.warning: "need to parse v. prefixes out of this".}
  let isVersion = parseVersion(&"""version = "{tag}"""")
  if isVersion.isSome:
    result = isVersion.get

proc nameMyRepo(project: Project; head: string): string =
  result = project.name & "-" & $project.release
  if project.release in {Tag}:
    let tag = project.release.reference
    # use the nimble style of project-#head when appropriate
    if head == project.release.reference:
      result = project.name & "-" & "#head"
    else:
      # try to use a version number if it matches our tag
      let version = parseVersionFromTag(tag)
      if version.isValid:
        result = project.name & "-" & $version
      else:
        result = project.name & "-#" & tag
  elif project.version.isValid:
    result = project.name & "-" & $project.version
  else:
    result = project.name

proc relocateDependency(project: var Project; head: string) =
  ## try to rename a project to more accurately reflect tag or version
  let
    repository = project.repo
    current = repository.lastPathPart
    name = project.nameMyRepo(head)
  if current == name:
    return
  let
    splat = repository.splitFile
    future = splat.dir / name
  if dirExists(future):
    warn &"cannot rename `{current}` to `{name}` -- already exists"
  else:
    moveDir(repository, future)
  let nimble = future / project.nimble.package.addFileExt(project.nimble.ext)
  project.nimble = newTarget(nimble)

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

proc releaseSummary*(project: Project): string =
  if project.dist != Git:
    return "⚠️(not in git repository)"
  if not project.release.isValid:
    return "⚠️(invalid release)"
  if project.release.kind != Tag:
    return "⚠️(not tagged)"
  withGit:
    var
      thing: GitThing
      opened: GitOpen
    gitTrap opened, openRepository(opened, project.repo):
      let path {.used.} = project.repo # template reasons
      warn &"error opening repository {path}"
      return
    gitTrap thing, lookupThing(thing, opened.repo, project.release.reference):
      warn &"error reading reference `{project.release.reference}`"
      return
    result = thing.summary

proc cuteRelease*(project: Project): string =
  if project.dist == Git and project.release.isValid:
    let
      head = project.getHeadOid
    if project.tags == nil:
      error "unable to determine tags without fetching them from git"
      result = head.short(6)
    else:
      block search:
        for tag, target in project.tags.pairs:
          if target.oid == head:
            result = $tag
            break search
        result = head.short(6)
  elif project.version.isValid:
    result = $project.version
  else:
    result = "???"

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
  if project.dist == Git:
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

proc parseNimbleLink(path: string): tuple[nimble: string; source: string] =
  let
    lines = readFile(path).splitLines
  if lines.len != 2:
    raise newException(ValueError, &"malformed {path}")
  result = (nimble: lines[0], source: lines[1])

proc linkedFindTarget(dir: string; target = ""; nimToo = false;
                      ascend = true): LinkedSearchResult =
  ## recurse through .nimble-link files to find the .nimble
  var
    extensions = @[dotNimble, dotNimbleLink]
  if nimToo:
    extensions = @["".addFileExt("nim")] & extensions

  result = LinkedSearchResult()
  result.search = findTarget(dir, extensions = extensions,
                             target = target, ascend = ascend)

  let found = result.search.found
  if found.isNone or found.get.ext != dotNimbleLink:
    return

  try:
    let parsed = parseNimbleLink($found.get)
    if fileExists(parsed.nimble):
      result.source = parsed.source
    # specify the path to the .nimble and the .nimble filename itself
    var recursed = linkedFindTarget(parsed.nimble.parentDir, nimToo = nimToo,
                                    target = parsed.nimble.extractFilename,
                                    ascend = ascend)
    if recursed.search.found.isSome:
      recursed.via = result
      return recursed
    result.search.message = &"{found.get} didn't lead to a {dotNimble}"
  except ValueError as e:
    result.search.message = e.msg
  result.search.found = none(Target)

proc findProject*(project: var Project; dir = "."): bool =
  ## locate a project starting from `dir`
  let
    target = linkedFindTarget(dir)
  if target.search.found.isNone:
    if target.search.message != "":
      error target.search.message
    return
  elif target.via != nil:
    var
      target = target  # shadow linked search result
    while target.via != nil:
      debug &"--> via {target.via.search.found.get}"
      target = target.via

  project = newProject(target.search.found.get)
  project.develop = target.via
  project.meta = fetchNimbleMeta(project.repo)
  project.dist = project.guessDist
  let
    mycfg = loadProjectCfg($project.nimCfg)
  if mycfg.isSome:
    project.mycfg = mycfg.get
  if project.meta.hasUrl:
    project.url = project.meta.url
  project.version = project.knowVersion
  project.inventRelease
  if project.release.isValid:
    debug &"{project} version {project.version}"
  else:
    error &"unable to determine reference for {project}"
    return
  result = true

template packageDirectory*(project: Project): string {.deprecated.}=
  project.nimbleDir / PkgDir

iterator packageDirectories(project: Project): string =
  ## yield directories according to the project's path configuration
  if project.parent != nil or project.cfg == nil:
    raise newException(Defect, "nonsensical outside root project")
  for directory in project.cfg.packagePaths:
    yield directory

proc len*(group: ProjectGroup): int =
  result = group.table.len

proc add*(group: ProjectGroup; name: string; project: Project) =
  group.table.add name, project

proc newProjectGroup*(): ProjectGroup =
  result = ProjectGroup()
  result.table = newTable[string, Project]()

proc contains*(group: ProjectGroup; name: string): bool =
  result = name in group.table

proc importName*(path: string): string =
  ## a uniform name usable in code for imports
  assert path.len > 0
  result = path.pathToImport.packageName

proc importName*(target: Target): string =
  ## a uniform name usable in code for imports
  assert target.repo.len > 0
  result = target.repo.importName

proc importName*(linked: LinkedSearchResult): string =
  ## a uniform name usable in code for imports
  if linked.via != nil:
    result = linked.via.importName
  else:
    # if found isn't populated, we SHOULD crash here
    result = linked.search.found.get.importName

proc importName*(project: Project): string =
  {.warning: "fix importName".}
  ##
  ## this needs to be fixed to look at install dirs,
  ## rewrite src directories, and so on...  it should
  ## probably produce a strtable of symbols and paths
  ##
  if project.develop != nil:
    result = project.develop.importName
  else:
    result = project.nimble.importName

iterator pairs*(group: ProjectGroup): tuple[name: string; project: Project] =
  for directory, project in group.table.pairs:
    yield (name: directory, project: project)

iterator values*(group: ProjectGroup): Project =
  for project in group.table.values:
    yield project

iterator mvalues*(group: ProjectGroup): var Project =
  for project in group.table.mvalues:
    yield project

proc hasProjectIn*(group: ProjectGroup; directory: string): bool =
  result = group.table.hasKey(directory)

proc getProjectIn*(group: ProjectGroup; directory: string): Project =
  result = group.table[directory]

proc mgetProjectIn*(group: var ProjectGroup; directory: string): var Project =
  result = group.table[directory]

proc availableProjects*(project: Project): ProjectGroup =
  ## find packages locally available to a project; note that
  ## this can include the project itself -- perfectly fine
  result = newProjectGroup()
  for directory in project.packageDirectories:
    var package: Project
    if findProject(package, directory):
      if package.repo notin result:
        result.add package.repo, package
    else:
      debug &"no package found in {directory}"

proc `==`*(a, b: Project): bool =
  ## a dirty (if safe) way to compare equality of projects
  if a.isNil or b.isNil:
    result = a.isNil == b.isNil
  else:
    let
      apath = $a.nimble
      bpath = $b.nimble
    if apath == bpath:
      result = true
    else:
      debug "had to use samefile to compare {apath} to {bpath}"
      result = sameFile(apath, bpath)

proc findRepositoryUrl*(path: string): Option[Uri] =
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

proc removeSearchPath*(project: Project; path: string): bool =
  ## remove a search path from the project's nim.cfg
  result = removeSearchPath(project.nimCfg, path)

proc excludeSearchPath*(project: Project; path: string): bool =
  ## exclude a search path from the project's nim.cfg
  result = excludeSearchPath(project.nimCfg, path)

proc addSearchPath*(project: Project; path: string): bool =
  for exists in project.packageDirectories:
    if exists == path:
      return
  if project.cfg == nil:
    raise newException(Defect, "nonsensical")
  result = project.cfg.addSearchPath(project.nimCfg, path)

proc determineSearchPath(project: Project): string =
  if project.dump == nil:
    raise newException(Defect, "no dump available")
  block found:
    if "srcDir" in project.dump:
      let srcDir = project.dump["srcDir"]
      if srcDir != "":
        setCurrentDir(project.repo)
        result = srcDir.absolutePath
        break
    result = project.repo

proc assertSearchPath*(project: Project; target: Project) =
  if project.parent != nil:
    project.parent.assertSearchPath(target)
  else:
    let
      path = target.determineSearchPath
    block found:
      for search in project.cfg.packagePaths(exists = false):
        if search / "" == path / "":
          break found
      discard project.addSearchPath(path)

proc assertSearchPath*(project: Project; target: var Project) =
  target.fetchDump
  let
    readonly = target
  project.assertSearchPath(readonly)

proc clone*(project: var Project; url: Uri; name: string): bool =
  ## clone a package into the project's nimbleDir
  var
    bare = url
    tag: string
    directory = project.nimbleDir / PkgDir
    oid: string

  if bare.anchor != "":
    tag = bare.anchor
  bare.anchor = ""

  when false:
    {.warning: "clone into a temporary directory".}
    # FIXME: we should probably clone into a temporary directory that we
    # can confirm does not exist; then investigate the contents and consider
    # renaming it to match its commit hash or tag.
  else:
    # we have to strip the # from a version tag for the compiler's benefit
    #
    let version = parseVersionFromTag(tag)
    if version.isValid:
      directory = directory / name & "-" & $version
    elif tag.len != 0:
      directory = directory / name & "-#" & tag
    else:
      directory = directory / name & "-#head"

  fatal &"👭cloning {bare}..."
  info &"... into {directory}"

  withGit:
    var
      got: GitClone
    gitTrap got, clone(got, bare, directory):
      return

    oid = $getHeadOid(got.repo)

  var
    proj: Project
  if findProject(proj, directory) and proj.repo == directory:
    if not writeNimbleMeta(directory, bare, oid):
      warn &"unable to write {nimbleMeta} in {directory}"
    proj.relocateDependency(oid)
    # reload the project's config to see if we capture a new search path
    project.cfg = loadAllCfgs(project.repo)
    project.assertSearchPath(proj)
  else:
    error "couldn't make sense of the project i just cloned"

  result = true

proc allImportTargets*(config: ConfigRef; repo: string):
  OrderedTableRef[Target, LinkedSearchResult] =
  ## yield projects from the group in the same order that they may be
  ## resolved by the compiler, if at all, given a particular configuration
  ##
  ## FIXME: is it safe to assume that searchPaths are searched in the same
  ## order that they appear in the parsed configuration?  need test for this
  result = newOrderedTable[Target, LinkedSearchResult]()

  for path in config.extantSearchPaths(repo):
    let
      target = linkedFindTarget(path, target = path.importName,
                                nimToo = true, ascend = false)
      found = target.search.found
    if found.isNone:
      continue
    result.add found.get, target

iterator asFoundVia*(group: ProjectGroup; config: ConfigRef;
                     repo: string): var Project =
  ## yield projects from the group in the same order that they may be
  ## resolved by the compiler, if at all, given a particular configuration
  ##
  ## FIXME: is it safe to assume that searchPaths are searched in the same
  ## order that they appear in the parsed configuration?  need test for this
  var
    dedupe = newTable[string, Project](nextPowerOfTwo(group.len))

  for path in config.extantSearchPaths(repo):
    let
      target = linkedFindTarget(path, ascend = false)
      found = target.search.found
    if found.isNone or target.importName in dedupe:
      continue
    for project in group.mvalues:
      if found.get == project.nimble:
        dedupe.add target.importName, project
        yield project
        break

proc fetchConfig*(project: var Project): bool =
  ## ensure we've got a valid configuration to work with
  if project.cfg == nil:
    project.cfg = loadAllCfgs(dir = project.repo)
    result = true

proc countNimblePaths*(project: Project):
  tuple[local: int; global: int; paths: seq[string]] =
  ## try to count the effective number of --nimblePaths
  let
    repository = project.repo
  for iteration in countDown(2, 0):
    for path in likelyLazy(project.cfg, repository, least = iteration):
      if path.startsWith(repository):
        result.local.inc
      else:
        result.global.inc
      result.paths.add path
    if result.local + result.global != 0:
      break

proc numberOfNimblePaths*(project: Project): int =
  ## simpler count of effective --nimblePaths
  result = project.countNimblePaths.paths.len
