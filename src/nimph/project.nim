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
import nimph/thehub

import nimph/group
export group

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
    mycfg*: ConfigRef
    tags*: GitTagTable
    meta*: NimbleMeta
    url*: Uri
    parent*: Project
    develop*: LinkedSearchResult

  ProjectGroup* = NimphGroup[string, Project]

  Dependency* = object
    url*: Uri
    operator*: Operator

  Releases* = TableRef[string, Release]

  LinkedSearchResult* = ref object
    via: LinkedSearchResult
    source: string
    search: SearchResult

  ForkTargetResult* = object
    ok*: bool
    why*: string
    owner*: string
    repo*: string
    url*: Uri

template repo*(project: Project): string = project.nimble.repo
template gitDir*(project: Project): string = project.repo / dotGit
template hasGit*(project: Project): bool = dirExists(project.gitDir)
template hgDir*(project: Project): string = project.repo / dotHg
template hasHg*(project: Project): bool = dirExists(project.hgDir)
template nimphConfig*(project: Project): string = project.repo / configFile
template hasNimph*(project: Project): bool = fileExists(project.nimphConfig)
template localDeps*(project: Project): string = project.repo / DepDir / ""
template packageDirectory*(project: Project): string {.deprecated.}=
  project.nimbleDir / PkgDir

template hasReleaseTag*(project: Project): bool =
  project.release.kind == Tag

template nimCfg*(project: Project): Target =
  newTarget(project.nimble.repo / NimCfg)

template hasLocalDeps*(project: Project): bool =
  dirExists(project.localDeps)

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
    result = project.cfg.suggestNimbleDir(local = project.localDeps,
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

proc fetchConfig*(project: var Project; force = false): bool =
  ## ensure we've got a valid configuration to work with
  if project.cfg == nil or force:
    if project.parent == nil:
      debug &"config fetch for parent {project}"
      project.cfg = loadAllCfgs(project.repo)
      result = true
    else:
      project.cfg = project.parent.cfg
      debug &"config fetch for child {project}"
      result = overlayConfig(project.cfg, project.repo)
      if result:
        discard project.parent.fetchConfig(force = true)
      result = true
  else:
    discard
    when defined(debug):
      notice &"unnecessary config fetch for {project}"

proc runNimble*(project: Project; args: seq[string];
                opts = {poParentStreams}): RunNimbleOutput =
  ## run nimble against a particular project
  let
    nimbleDir = project.nimbleDir
  result = runNimble(args, opts, nimbleDir = nimbleDir)

proc runNimble*(project: var Project; args: seq[string];
                opts = {poParentStreams}): RunNimbleOutput =
  ## run nimble against a particular project, fetching its config first
  let
    readonly = project
  # ensure we have a config for the project before running nimble;
  # this could change the nimbleDir value used
  discard project.fetchConfig
  result = readonly.runNimble(args, opts = opts)

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

proc fetchDump*(project: var Project; package: string; refresh = false): bool =
  ## make sure the nimble dump is available
  if project.dump == nil or refresh:
    discard project.fetchConfig
    let
      dumped = fetchNimbleDump(package, nimbleDir = project.nimbleDir)
    result = dumped.ok
    if not result:
      # puke on this for now...
      raise newException(IOError, dumped.why)
    # try to prevent a bug when the above changes
    project.dump = dumped.table
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
        let emsg = &"unparsable version `{text}` in {project.name}" # noqa
        raise newException(IOError, emsg)
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
  ## retrieve the #head oid from a repository at the given path
  var
    open: GitOpen
  withGit:
    gitTrap openRepository(open, path):
      warn &"error opening repository {path}"
      return
    result = open.repo.getHeadOid

proc getHeadOid*(project: Project): GitOid =
  ## retrieve the #head oid from the project's repository
  if project.dist != Git:
    let emsg = &"{project} lacks a git repository to load" # noqa
    raise newException(Defect, emsg)
  result = getHeadOid(project.gitDir)

proc parseVersionFromTag(tag: string): Version =
  {.warning: "need to parse v. prefixes out of this".}
  let isVersion = parseVersion(&"""version = "{tag}"""")
  if isVersion.isSome:
    result = isVersion.get

proc nameMyRepo(project: Project; head: string): string =
  ## name a repository directory in such a way that the compiler can grok it
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

proc fetchTagTable*(project: var Project): GitTagTable {.discardable.} =
  ## retrieve the tags for a project from its git repository
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
  ## summarize a project's tree using whatever we can
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
  ## a very short summary of a release; ie. a git commit or version
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
  ## find the current release tag of a project
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
  ## find the current release tag of a project
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
  ## parse a dotNimbleLink file into its constituent components
  let
    lines = readFile(path).splitLines
  if lines.len != 2:
    raise newException(ValueError, "malformed " & path)
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

proc findRepositoryUrl*(path: string; name = defaultRemote): Option[Uri] =
  ## find the (remote?) url to a given local repository
  var
    remote: GitRemote
    open: GitOpen

  withGit:
    gitTrap openRepository(open, path):
      warn &"error opening repository {path}"
      return
    gitTrap remote, remoteLookup(remote, open.repo, name):
      warn &"unable to fetch remote `{name}` from repo in {path}"
      result = Uri(scheme: "file", path: path.absolutePath / "").some
      return
    try:
      let url = remote.url
      if url.isValid:
        result = remote.url.some
      else:
        warn &"bad git url in {path}: {url}"
    except:
      warn &"unable to parse url from remote `{name}` from repo in {path}"

proc createUrl*(project: Project): Uri =
  ## determine the source url for a project which may be local
  if project.url.isValid:
    result = project.url
  else:
    case project.dist:
    of Local:
      if project.meta.hasUrl:
        result = project.meta.url
      else:
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

proc createUrl*(project: var Project): Uri =
  let
    readonly = project
  result = readonly.createUrl
  project.url = result

proc findProject*(project: var Project; dir: string;
                  parent: Project = nil): bool =
  ## locate a project starting from `dir`
  let
    target = linkedFindTarget(dir, ascend = true)
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

  # there's really no scenario in which we need to instantiate a
  # new parent project when looking for children...
  if parent != nil:
    if parent.nimble == target.search.found.get:
      return

  project = newProject(target.search.found.get)
  project.parent = parent
  project.develop = target.via
  project.meta = fetchNimbleMeta(project.repo)
  project.dist = project.guessDist
  let
    mycfg = loadProjectCfg($project.nimCfg)
  if mycfg.isSome:
    project.mycfg = mycfg.get
  project.url = project.createUrl
  project.version = project.knowVersion
  project.inventRelease
  if project.release.isValid:
    debug &"{project} version {project.version}"
  else:
    error &"unable to determine reference for {project}"
    return
  result = true

iterator packageDirectories(project: Project): string =
  ## yield directories according to the project's path configuration
  if project.parent != nil or project.cfg == nil:
    raise newException(Defect, "nonsensical outside root project")
  for directory in project.cfg.packagePaths(exists = true):
    yield directory

proc newProjectGroup*(): ProjectGroup =
  const mode =
    when FilesystemCaseSensitive:
      modeCaseSensitive
    else:
      modeCaseInsensitive
  result = ProjectGroup()
  result.init(mode = mode)

proc importName*(linked: LinkedSearchResult): string =
  ## a uniform name usable in code for imports
  if linked.via != nil:
    result = linked.via.importName
  else:
    # if found isn't populated, we SHOULD crash here
    result = linked.search.found.get.importName

proc importName*(project: Project): string =
  ## a uniform name usable in code for imports
  if project.develop != nil:
    result = project.develop.importName
  else:
    result = project.nimble.importName

proc hasProjectIn*(group: ProjectGroup; directory: string): bool =
  ## true if a project is stored at the given directory
  result = group.hasKey(directory)

proc getProjectIn*(group: ProjectGroup; directory: string): Project =
  ## retrieve a project via its path
  result = group.get(directory)

proc mgetProjectIn*(group: var ProjectGroup; directory: string): var Project =
  ## retrieve a mutable project via its path
  result = group.mget(directory)

proc availableProjects*(project: Project): ProjectGroup =
  ## find packages locally available to a project; note that
  ## this will include the project itself
  result = newProjectGroup()
  result.add project.repo, project
  for directory in project.packageDirectories:
    var proj: Project
    if findProject(proj, directory, parent = project):
      if proj.repo notin result:
        result.add proj.repo, proj
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
      when defined(debugPath):
        debug &"had to use samefile to compare {apath} to {bpath}"
      result = sameFile(apath, bpath)

proc removeSearchPath*(project: Project; path: string): bool =
  ## remove a search path from the project's nim.cfg
  result = project.cfg.removeSearchPath(project.nimCfg, path)

proc excludeSearchPath*(project: Project; path: string): bool =
  ## exclude a search path from the project's nim.cfg
  result = project.cfg.excludeSearchPath(project.nimCfg, path)

proc addSearchPath*(project: Project; path: string): bool =
  ## add a search path to the given project's configuration
  for exists in project.packageDirectories:
    if exists == path:
      return
  if project.cfg == nil:
    raise newException(Defect, "load a configuration first")
  result = project.cfg.addSearchPath(project.nimCfg, path)

proc determineSearchPath(project: Project): string =
  ## produce the search path to add for a given project
  if project.dump == nil:
    raise newException(Defect, "no dump available")
  block found:
    if "srcDir" in project.dump:
      let srcDir = project.dump["srcDir"]
      if srcDir != "":
        withinDirectory(project.repo):
          result = srcDir.absolutePath
        break
    result = project.repo
  result = result / ""

iterator missingSearchPaths*(project: Project; target: Project): string =
  ## one (or more?) paths to the target package which are
  ## apparently missing from the project's search paths
  let
    path = target.determineSearchPath / ""
  block found:
    if not path.dirExists:
      break
    for search in project.cfg.packagePaths(exists = false):
      if search == path:
        break found
    yield path

iterator missingSearchPaths*(project: Project; target: var Project): string =
  ## one (or more?) path to the target package which are apparently missing from
  ## the project's search paths; this will resolve up the parent tree to find
  ## the highest project in which to modify a configuration
  if not target.fetchDump:
    warn &"unable to fetch dump for {target}; this won't end well"

  let
    readonly = target
  var
    parent = project
  while project.parent != nil:
    parent = project.parent
  for path in parent.missingSearchPaths(readonly):
    yield path

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

  # don't clone the compiler when we're debugging nimph
  when defined(debug):
    if "github.com/nim-lang/Nim" in $bare:
      raise newException(Defect, "won't clone the compiler when debugging nimph")

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
  if findProject(proj, directory, parent = project) and
                 proj.repo == directory:
    if not writeNimbleMeta(directory, bare, oid):
      warn &"unable to write {nimbleMeta} in {directory}"
    proj.relocateDependency(oid)
    # reload the project's config to see if we capture a new search path
    project.cfg = loadAllCfgs(project.repo)
    for path in project.missingSearchPaths(proj):
      if project.addSearchPath(path):
        info &"added path `{path}` to `{project.nimcfg}`"
      else:
        warn &"couldn't add path `{path}` to `{project.nimcfg}`"
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

  for path in config.extantSearchPaths:
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
  var
    dedupe = newTable[string, Project](nextPowerOfTwo(group.len))

  # procede in path order to try to find projects using the paths
  for path in config.packagePaths(exists = true):
    let
      target = linkedFindTarget(path, ascend = false)
      found = target.search.found
    if found.isNone:
      continue
    for project in group.mvalues:
      if found.get == project.nimble:
        if project.importName notin dedupe:
          dedupe.add project.importName, project
          yield project
        break

  # now report on anything we weren't able to discover
  for project in group.values:
    if project.importName notin dedupe:
      notice &"no path to {project.repo}"

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

proc forkTarget*(url: Uri): ForkTargetResult =
  result.url = url
  block success:
    if not url.isValid:
      result.why = &"url is invalid"
      break
    if result.url.hostname.toLowerAscii != "github.com":
      result.why = &"url {result.url} does not point to github"
      break
    if result.url.path.len < 1:
      result.why = &"unable to parse url {result.url}"
      break
    # split /foo/bar into (bar, foo)
    (result.owner, result.repo) = result.url.path[1..^1].splitPath
    # strip .git
    if result.repo.endsWith(".git"):
      result.repo = result.repo[0..^len("git+2")]
    result.ok = result.owner.len > 0 and result.repo.len > 0
    if not result.ok:
      result.why = &"unable to parse url {result.url}"

proc forkTarget*(project: Project): ForkTargetResult =
  ## try to determine a github source of a project so that we can fork it
  result.ok = false

  {.warning: "look at any remotes to see if they are valid".}
  {.warning: "try to lookup the project in the packages list".}
  {.warning: "try to lookup the project in our github repos".}

  block success:
    if not project.url.isValid:
      result.why = &"unable to parse url {result.url}"
      break
    result = project.url.forkTarget

proc `==`(x, y: ForkTargetResult): bool =
  result = x.ok == y.ok and x.owner == y.owner and x.repo == y.repo

proc promoteFork*(project: Project; repo: HubRepo; name: string): bool =
  ## true if we were able to promote a repo to be our new origin
  var
    remote, upstream: GitRemote
    open: GitOpen
  let
    path = project.repo

  withGit:
    gitTrap openRepository(open, project.repo):
      warn &"error opening repository {path}"
      return
    gitTrap remote, remoteLookup(remote, open.repo, name):
      warn &"unable to fetch remote `{name}` from repo in {path}"
      return
    block donehere:
      try:
        # maybe we've already pointed at the repo?
        if remote.url.forkTarget == repo.git.forkTarget:
          result = true
          break
      except:
        warn &"unparseable remote `{name}` from repo in {path}"
      gitFail upstream, remoteLookup(upstream, open.repo, upstreamRemote):
        # there's no upstream remote; rename origin to upstream
        gitTrap open.repo.remoteRename(name, upstreamRemote):
          # this should issue warnings of any problems...
          break
        # and make a new origin remote using the hubrepo's url
        gitTrap upstream, remoteCreate(upstream, open.repo,
                                       defaultRemote, repo.git.convertToSsh):
          # this'll issue some errors for us, too...
          break
        # success
        result = true
        return

      try:
        # upstream exists, so, i dunno, just warn the user?
        if upstream.url.forkTarget != remote.url.forkTarget:
          warn &"remote `{upstreamRemote}` exists for repo in {path}"
        else:
          {.warning: "origin equals upstream; remove upstream and try again?".}
          warn &"remote `{upstreamRemote}` is the same as `{name}` in {path}"
      except:
        warn &"unparseable remote `{upstreamRemote}` from repo in {path}"
