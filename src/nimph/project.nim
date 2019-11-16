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
    # unused yet
    config*: NimphConfig
    cfg*: ConfigRef
    # unused yet
    #deps*: PackageGroup
    tags*: GitTagTable
    # unused yet
    #refs*: Releases
    meta*: NimbleMeta
    url*: Uri
    parent*: Project

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

proc nimbleDir*(project: Project): string =
  ## the path to the project's dependencies
  var
    localdeps = project.repo / DepDir / ""
    globaldeps = getHomeDir() / dotNimble / ""

  # if we instantiated this project from another, the implication is that we
  # want to point at whatever that parent project is using as its nimbleDir.
  if project.parent != nil:
    result = project.parent.nimbleDir

  # otherwise, if we have configuration data, we should use it to determine
  # what the user might be using as a package directory -- local or elsewise
  elif project.cfg != nil:
    result = project.cfg.suggestNimbleDir(project.repo,
                                          local = localdeps,
                                          global = globaldeps)

  # otherwise, we'll just presume some configuration-free defaults
  else:
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

proc linkedFindTarget(dir: string; target = ""): LinkedSearchResult =
  ## recurse through .nimble-link files to find the .nimble
  result = LinkedSearchResult()
  result.search = findTarget(dir, extensions = @[dotNimble, dotNimbleLink],
                             target = target)

  let found = result.search.found
  if found.isNone or found.get.ext == dotNimble:
    return

  try:
    let parsed = parseNimbleLink($found.get)
    if fileExists(parsed.nimble):
      result.source = parsed.source
    # specify the path to the .nimble and the .nimble filename itself
    var recursed = linkedFindTarget(parsed.nimble.parentDir,
                                    target = parsed.nimble.extractFilename)
    recursed.via = result
    result = recursed
  except ValueError as e:
    result.search.message = e.msg
    return

  result.search.message = &"{found} didn't lead to a {dotNimble}"
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
  project.meta = fetchNimbleMeta(project.repo)
  project.dist = project.guessDist
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

proc add(group: ProjectGroup; name: string; project: Project) =
  group.table.add name, project

proc newProjectGroup(): ProjectGroup =
  result = ProjectGroup()
  result.table = newTable[string, Project]()

proc contains*(group: ProjectGroup; name: string): bool =
  result = name in group.table

iterator pairs*(group: ProjectGroup): tuple[name: string; project: Project] =
  for directory, project in group.table.pairs:
    yield (name: directory.pathToImport, project: project)

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
