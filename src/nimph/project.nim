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
import std/strtabs
import std/asyncdispatch
import std/algorithm
import std/sequtils

import bump
import gittyup

import nimph/spec
import nimph/config
import nimph/runner
import nimph/nimble
import nimph/package
import nimph/version
import nimph/thehub
import nimph/versiontags
import nimph/requirement

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

  ProjectGroup* = Group[string, Project]

  Releases* = TableRef[string, Release]

  LinkedSearchResult* = ref object
    via: LinkedSearchResult
    source: string
    search: SearchResult

  # same as Requires, for now
  Requirements* = OrderedTableRef[Requirement, Requirement]
  RequirementsTags* = Group[Requirements, GitThing]

template repo*(project: Project): string = project.nimble.repo
template gitDir*(project: Project): string = project.repo / dotGit
template hasGit*(project: Project): bool =
  dirExists(project.gitDir) or fileExists(project.gitDir)
template hgDir*(project: Project): string = project.repo / dotHg
template hasHg*(project: Project): bool = dirExists(project.hgDir)
template nimphConfig*(project: Project): string = project.repo / configFile
template hasNimph*(project: Project): bool = fileExists(project.nimphConfig)
template localDeps*(project: Project): string = `///`(project.repo / DepDir)
template packageDirectory*(project: Project): string {.deprecated.} =
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
    globaldeps = getHomeDir() / ///dotNimble

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
    else:
      project.cfg = project.parent.cfg
    result = true
  else:
    discard
    when defined(debug):
      notice &"unnecessary config fetch for {project}"

proc runSomething*(project: Project; exe: string; args: seq[string];
                   opts = {poParentStreams}): RunOutput =
  ## run something against a particular project
  let
    nimbleDir = project.nimbleDir
  result = runSomething(exe, args, opts, nimbleDir = nimbleDir)

proc runSomething*(project: var Project; exe: string; args: seq[string];
                   opts = {poParentStreams}): RunOutput =
  ## run something against a particular project, fetching its config first
  let
    readonly = project
  # ensure we have a config for the project before running nimble;
  # this could change the nimbleDir value used
  discard project.fetchConfig
  result = readonly.runSomething(exe, args, opts = opts)

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
  block:
    # this is really the most likely to work, so start with a dump
    if project.dump != nil:
      if "version" in project.dump:
        let
          text = project.dump["version"]
          parsed = parseVersionLoosely(text)
        if parsed.isNone:
          let emsg = &"unparsable version `{text}` in {project.name}" # noqa
          raise newException(IOError, emsg)
        # get the effective version instead of a release.version
        result = parsed.get.effectively
        break

    # we don't have a dump to work with, or the dump has no version in it
    result = project.guessVersion
    if not result.isValid:
      # that was a bad guess; if we have no dump, recurse on the dump
      if project.dump == nil and project.fetchDump:
        result = project.knowVersion

  if not result.isValid:
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

proc getHeadOid*(project: Project): GitResult[GitOid] =
  ## retrieve the #head oid from the project's repository
  if project.dist != Git:
    let emsg = &"{project} lacks a git repository to load" # noqa
    raise newException(Defect, emsg)
  block:
    repository := openRepository(project.gitDir):
      error &"Cannot get head oid - unable to open repo at `{project.repo}`: {code.dumpError}"
      result.err code
      break
    result = repository.getHeadOid

proc demandHead*(repository: GitRepository): string =
  ## retrieve the repository's #head oid as a string, or ""
  block:
    oid := repository.getHeadOid:
      break
    result = $oid

proc demandHead*(project: Project): string =
  ## retrieve the project's #head oid as a string, or ""
  if project.dist == Git:
    block:
      oid := project.getHeadOid:
        break
      result = $oid

proc shortOid(oid: GitOid; size = 6): string =
  ## a shortened version of the oid; measure twice, cut once
  let
    short = oid.short(6)
  if short.isErr:
    result = "💣" & $short.error
  else:
    result = short.get

template matchingBranches(project: Project; body: untyped): untyped =
  block:
    repository := openRepository(project.gitDir):
      error &"Cannot get matchig branches - unable to open repo at `{project.repo}`: {code.dumpError}"
      break
    for bref in repository.branches:
      if bref.isOk:
        try:
          var
            branch {.inject.}: GitReference = bref.get
          body
        finally:
          free bref.get
      else:
        warn &"unable to fetch branch in {repository}"

iterator matchingBranches*(project: Project; oid: GitOid): GitReference =
  project.matchingBranches:
    if oid == branch.oid:
      yield branch

iterator matchingBranches*(project: Project; name: string): GitReference =
  project.matchingBranches:
    if name == branch.branchName.split("/")[^1]:
      yield branch

proc nameMyRepo(project: Project): string =
  ## name a repository directory in such a way that the compiler can grok it
  block complete:
    if project.dist == Git:
      block hashead:
        oid := project.getHeadOid:
          # no head is not an error
          break hashead
        # the release is a tag, so we might be able to simplify it
        if project.release.kind in {Tag}:
          let tag = project.tags.shortestTag($oid)
          # use the nimble style of project-#head when appropriate
          if tag == $oid:
            # try to find a matching oid in the current branch
            for branch in project.matchingBranches(oid):
              result = project.name & "-" & "#" & branch.name.split("/")[^1]
              break complete
            result = project.name & "-" & "#head"
          else:
            let loose = parseVersionLoosely(tag)
            if loose.isSome:
              result = project.name & "-" & $loose.get
            else:
              result = project.name & "-#" & tag
          break complete

    # fallback to version
    if project.version.isValid:
      result = project.name & "-" & $project.version
    else:
      result = project.name & "-0"  # something the compiler can grok?

proc sortByVersion*(tags: GitTagTable): GitTagTable =
  ## re-order an ordered table to match version sorting
  var
    order: seq[tuple[tag: string, version: Version, thing: GitThing]]
  result = newTagTable(nextPowerOfTwo(tags.len))

  # try to parse each of the tags to see if they look like a version
  for tag, thing in tags.pairs:
    let parsed = parseVersionLoosely(tag)
    # if we were able to parse a release and it looks like
    # a simple version, then we'll add that to our sequence
    if parsed.isSome:
      if parsed.get.kind == Equal:
        order.add (tag: tag, version: parsed.get.version, thing: thing)
        continue
    # if the tag isn't parsable as a version, store it in the result
    result.add tag, thing

  # now sort the sequence and add the tags with versions to the result
  for trio in order.sortedByIt(it.version):
    result.add trio.tag, trio.thing

proc fetchTagTable*(project: var Project) =
  ## retrieve the tags for a project from its git repository
  block:
    if project.dist != Git:
      break
    repository := repositoryOpen(project.gitDir):
      error &"Cannot fetch tag table - unable to open repo at `{project.repo}`: {code.dumpError}"
      break
    let
      tags = repository.tagTable
    if tags.isErr:
      warn &"unable to read tags at `{project.repo}`: {tags.error.dumpError}"
      break
    project.tags = tags.get.sortByVersion

proc releaseSummary*(project: Project): string =
  ## summarize a project's tree using whatever we can
  if project.dist != Git:
    result = "⚠️(not in git repository)"
  elif not project.release.isValid:
    result = "⚠️(invalid release)"
  elif project.release.kind != Tag:
    # if it's not a tag, just dump the release
    result = $project.release
  else:
    # else, lookup the summary for the tag or commit
    block:
      repository := openRepository(project.gitDir):
        error &"Cannot get release summary - unable to open repo at `{project.repo}`: {code.dumpError}"
        break
      thing := repository.lookupThing(project.release.reference):
        warn &"error reading reference `{project.release.reference}`"
        break
      # we really only need the first line, at most
      result = thing.summary.splitLines[0]

proc cuteRelease*(project: Project): string =
  ## a very short summary of a release; ie. a git commit or version
  const
    shorties = 6 # size of short oids
  if project.dist == Git and project.release.isValid:
    let
      head = project.getHeadOid
    # free the oid if necessary
    if head.isOk:
      defer:
        free head.get

    # assign a useful release string using the head
    if head.isErr:
      result = "⚠️"
    elif project.tags == nil:
      error "unable to determine tags without fetching them from git"
      result = shortOid(head.get, size = shorties)
    else:
      block search:
        for tag, target in project.tags.pairs:
          if target.oid == head.get:
            result = $tag
            break search
        result = shortOid(head.get, size = shorties)
  elif project.version.isValid:
    result = $project.version
  else:
    result = "???"

proc findCurrentTag*(project: Project): Release =
  ## find the current release tag of a project
  let
    head = project.getHeadOid
  # free the oid if necessary
  if head.isOk:
    defer:
      free head.get
  var
    name: string
  if head.isErr:
    name = ""
  elif project.tags == nil:
    error "unable to determine tags without fetching them from git"
    name = $head.get
  else:
    block search:
      # if there's a tag for our head, use that
      for tag, target in project.tags.pairs:
        if target.oid == head.get:
          name = $tag
          break search
      # otherwise, just use our head reference
      name = $head.get
  result = newRelease(name, operator = Tag)

proc findCurrentTag*(project: var Project): Release =
  ## convenience to fetch tags and then find the current release tag
  let
    readonly = project
  if project.tags == nil:
    project.fetchTagTable
  result = readonly.findCurrentTag

proc inventRelease*(project: var Project) =
  ## compute the most accurate release specification for the project
  var
    release: Release
  block found:
    if project.dist == Git:
      release = project.findCurrentTag
      if release.isValid:
        project.release = release
        break found
    # if we have a url for the project, try to use its anchor
    if project.url.anchor.len > 0:
      project.release = newRelease(project.url.anchor, operator = Tag)
    # else if we have a version for the project, use that
    elif project.version.isValid:
      project.release = newRelease(project.version)
    else:
      # grab the directory name
      let name = repo(project).lastPathPart
      # maybe it's package-something
      var prefix = project.name & "-"
      if name.startsWith(prefix):
        # i'm lazy; this will parse the release if it's #foo or 1.2.3
        release = newRelease(name.split(prefix)[^1])
        if release.kind in {Tag, Equal}:
          warn &"had to resort to parsing reference from directory `{name}`"
          project.release = release
        else:
          warn &"unable to parse reference from directory `{name}`"

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

  # perform the search with our cleverly-constructed extensions
  result = LinkedSearchResult()
  result.search = findTarget(dir, extensions = extensions,
                             target = target, ascend = ascend)

  # if we found nothing, or we found a dotNimble, then we're done
  let found = result.search.found
  if found.isNone or found.get.ext != dotNimbleLink:
    return

  # now we need to parse this dotNimbleLink and recurse on the target
  try:
    let parsed = parseNimbleLink($found.get)
    if fileExists(parsed.nimble):
      result.source = parsed.source
    # specify the path to the .nimble and the .nimble filename itself
    var recursed = linkedFindTarget(parsed.nimble.parentDir, nimToo = nimToo,
                                    target = parsed.nimble.extractFilename,
                                    ascend = ascend)
    # if the recursion was successful, add ourselves to the chain and return
    if recursed.search.found.isSome:
      recursed.via = result
      return recursed

    # a failure mode yielding a useful explanation
    result.search.message = &"{found.get} didn't lead to a {dotNimble}"
  except ValueError as e:
    # a failure mode yielding a less-useful explanation
    result.search.message = e.msg

  # critically, set the search to none because ultimately, we found nothing
  result.search.found = none(Target)

proc findRepositoryUrl*(project: Project; name = defaultRemote): Option[Uri] =
  ## find the (remote?) url to a given local repository
  block complete:
    block found:
      repository := openRepository(project.gitDir):
        error &"Cannot find repository url - unable to open repo at `{project.repo}`: {code.dumpError}"
        break found
      let
        remote = repository.remoteLookup(name)
      if remote.isErr:
        case remote.error:
        of GIT_ENOTFOUND:
          # "not found" doesn't seem like something we need to warn of
          discard
        else:
          warn &"{remote.error}: unable to fetch remote `{name}` " &
               &"in {project.repo}"
          warn remote.error.dumpError
        break found
      # the lookup populated remote, so remember to free it
      defer:
        free remote.get

      try:
        let url = remote.get.url.normalizeUrl
        if url.isValid:
          # this is our only success scenario
          result = url.some
          break complete
        else:
          warn &"bad git url in {project.repo}: {url}"
      except:
        warn &"unable to parse url from remote `{name}` from {project.repo}"

    # this is a not-found (or error) condition; return a local url
    result = Uri(scheme: "file", path: ///project.repo).some
    break complete

proc createUrl*(project: Project; refresh = false): Uri =
  ## determine the source url for a project which may be local
  if not refresh and project.url.isValid:
    result = project.url
  else:
    # make something up
    case project.dist:
    of Local:
      # sometimes nimble provides a url during installation
      if project.meta.hasUrl:
        # sometimes...
        result = project.meta.url
    of Git:
      # try looking at remotes
      let url = findRepositoryUrl(project, defaultRemote)
      if url.isSome:
        result = url.get
      # if we have a result, we may want to overlook a fork...
      if result.scheme in ["file", "ssh"]:
        let fork = findRepositoryUrl(project, upstreamRemote)
        if fork.isSome and fork.get.scheme notin ["file", "ssh"]:
          result = fork.get
    else:
      raise newException(Defect, "not implemented")

    # if something bad happens, fall back to a useful url
    if not result.isValid:
      result = Uri(scheme: "file", path: project.repo)
    assert result.isValid

proc createUrl*(project: var Project; refresh = false): Uri =
  ## if we come up with a new url for the project, write it to a nimblemeta.json
  let
    readonly = project
  result = readonly.createUrl(refresh = refresh)
  if result != project.url:
    # update the nimble metadata with this new url
    if not writeNimbleMeta(project.repo, result, result.anchor):
      warn &"unable to update {project.name}'s {nimbleMeta}"

  # cache the result if the project is mutable
  project.url = result

proc refresh*(project: var Project) =
  ## appropriate to run to scan for and set some basic project data
  let
    mycfg = parseConfigFile($project.nimCfg)
  if mycfg.isSome:
    project.mycfg = mycfg.get
  project.url = project.createUrl(refresh = true)
  project.dump = nil
  project.version = project.knowVersion
  project.inventRelease

proc findProject*(project: var Project; dir: string;
                  parent: Project = nil): bool =
  ## locate a project starting from `dir` and set its parent if applicable
  block complete:
    let
      target = linkedFindTarget(dir, ascend = true)
    # a failure lets us out early
    if target.search.found.isNone:
      if target.search.message != "":
        error target.search.message
      break complete

    elif target.via != nil:
      var
        target = target  # shadow linked search result
      # output some debugging data to show how we got from here to there
      while target.via != nil:
        debug &"--> via {target.via.search.found.get}"
        target = target.via

    # there's really no scenario in which we need to instantiate a
    # new parent project when looking for children...
    if parent != nil:
      if parent.nimble == target.search.found.get:
        break complete

    # create an instance and setup some basic (cheap) data
    project = newProject(target.search.found.get)
    # the parent will be set on child dependencies
    project.parent = parent
    # this is the nimble-link chain that we might have a use for
    project.develop = target.via
    project.meta = fetchNimbleMeta(project.repo)
    project.dist = project.guessDist
    # load configs, create urls, set version and release, etc.
    project.refresh

    # if we cannot determine what release this project is, just bail
    if not project.release.isValid:
      # but make sure to zero out the result so as not to confuse the user
      project = nil
      error &"unable to determine reference for {project}"
      break complete

    # otherwise, we're golden
    debug &"{project} version {project.version}"
    result = true

iterator packageDirectories(project: Project): string =
  ## yield directories according to the project's path configuration
  if project.parent != nil:
    raise newException(Defect, "nonsensical outside root project")
  elif project.cfg == nil:
    raise newException(Defect, "fetch yourself a configuration first")
  for directory in project.cfg.packagePaths(exists = true):
    yield directory

proc newProjectGroup*(flags: set[Flag] = defaultFlags): ProjectGroup =
  const mode =
    when FilesystemCaseSensitive:
      modeCaseSensitive
    else:
      modeCaseInsensitive
  result = ProjectGroup(flags: flags)
  result.init(flags, mode = mode)

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

proc removeSearchPath*(project: var Project; path: string): bool =
  ## remove a search path from the project's nim.cfg; reload config
  let
    readonly = project
  result = readonly.removeSearchPath(path)
  if result:
    if not project.fetchConfig(force = true):
      warn &"unable to read config for {project}"

proc excludeSearchPath*(project: Project; path: string): bool =
  ## exclude a search path from the project's nim.cfg
  result = project.cfg.excludeSearchPath(project.nimCfg, path)

proc excludeSearchPath*(project: var Project; path: string): bool =
  ## exclude a search path from the project's nim.cfg; reload config
  let
    readonly = project
  result = readonly.excludeSearchPath(path)
  if result:
    if not project.fetchConfig(force = true):
      warn &"unable to read config for {project}"

proc addSearchPath*(project: Project; path: string): bool =
  ## add a search path to the given project's configuration;
  ## true if we added the search path
  block complete:
    for exists in project.packageDirectories:
      if exists == path:
        break complete
    if project.cfg == nil:
      raise newException(Defect, "load a configuration first")
    result = project.cfg.addSearchPath(project.nimCfg, path)

proc addSearchPath*(project: var Project; path: string): bool =
  ## add a search path to the project's nim.cfg; reload config
  let
    readonly = project
  result = readonly.addSearchPath(path)
  if result:
    if not project.fetchConfig(force = true):
      warn &"unable to read config for {project}"

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
        if result.dirExists:
          break
    result = project.repo
  result = ///result

iterator missingSearchPaths*(project: Project; target: Project): string =
  ## one (or more?) paths to the target package which are
  ## apparently missing from the project's search paths
  let
    path = ///determineSearchPath(target)
  block found:
    if not path.dirExists:
      warn &"search path for {project.name} doesn't exist"
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

proc addMissingSearchPathsTo*(project: var Project; cloned: var Project) =
  ## point the project at a fresh clone if necessary

  #[

   reload the project's config to see if we capture a new search path.
   we have to reload it here because the new path might be caught by the
   compiler's --nimblePath settings; we cannot simply add it via compiler
   code because the order of manual --path entries from the config will
   then vary.

  ]#
  project.cfg = loadAllCfgs(project.repo)
  # a future relocation will break this, of course
  for path in project.missingSearchPaths(cloned):
    if project.addSearchPath(path):
      info &"added path `{path}` to `{project.nimcfg}`"
    else:
      warn &"couldn't add path `{path}` to `{project.nimcfg}`"

proc relocateDependency*(parent: var Project; project: var Project) =
  ## try to rename a project to more accurately reflect tag or version
  if project.parent == nil:
    raise newException(Defect, "we don't rename parent project repositories")

  # tags are quite useful for choosing a name
  project.fetchTagTable

  let
    repository = project.repo
    current = repository.lastPathPart
    name = project.nameMyRepo
    splat = repository.splitFile
    future = splat.dir / name

  block:
    if current == name:
      break

    if fileExists(project.gitDir):
      debug &"not renaming `{current}` to `{name}` -- it's a submodule"
      break

    if dirExists(future):
      warn &"cannot rename `{current}` to `{name}` -- already exists"
      break

    # we'll need the dump in order to determine the search path
    if not project.fetchDump:
      notice &"error determining search path for {project.name}; dump failed"
      break

    let
      previous = project.determineSearchPath
      nimble = future / project.nimble.package.addFileExt(project.nimble.ext)

    # now we can actually move the repo...
    moveDir(repository, future)
    # reset the package configuration target
    project.nimble = newTarget(nimble)
    # the path changed, so remove the old path (if you can)
    discard parent.removeSearchPath(previous)
    # and point the parent to the new one
    parent.addMissingSearchPathsTo(project)

proc addMissingUpstreams*(project: Project) =
  ## review the local branches and add any missing tracking branches
  block:
    repository := openRepository(project.gitDir):
      error &"unable to open repo at `{project.repo}`: {code.dumpError}"
      break

    for result in repository.branches({GIT_BRANCH_LOCAL}):
      if result.isErr:
        warn &"error fetching branches: {result.error}"
        warn result.error.dumpError
      else:
        var
          branch = result.get
        # free the reference when we're done with it
        defer:
          free branch
        let
          name = branch.branchName
        debug &"branch: {name}"
        found := branch.branchUpstream:
          case code:
          of GIT_ENOTFOUND:
            case branch.setBranchUpstream(name):
            of GIT_OK:
              info &"added upstream tracking branch for {name}"
            else:
              warn &"unable to add upstream tracking branch for {name}"
              warn GIT_OK.dumpError
          else:
            warn &"error fetching upstream for {name}: {code}"
            warn code.dumpError

proc clone*(project: var Project; url: Uri; name: string;
            cloned: var Project): bool =
  ## clone a package into the project's nimbleDir
  var
    bare = url
    tag: string
    directory = project.nimbleDir.stripPkgs / PkgDir

  if bare.anchor != "":
    tag = bare.anchor
  bare.anchor = ""

  {.warning: "clone into a temporary directory".}
  # we have to strip the # from a version tag for the compiler's benefit
  let loose = parseVersionLoosely(tag)
  if loose.isSome and loose.get.isValid:
    directory = directory / name & "-" & $loose.get
  elif tag.len != 0:
    directory = directory / name & "-#" & tag
  else:
    directory = directory / name & "-#head"

  if directory.dirExists:
    error &"tried to clone into {directory}, but it already exists"
    return

  # don't clone the compiler when we're debugging nimph
  when defined(debug):
    if "github.com/nim-lang/Nim" in $bare:
      raise newException(Defect, "won't clone the compiler when debugging nimph")

  fatal &"👭cloning {bare}..."
  info &"... into {directory}"

  # clone the bare url into the given directory, yielding a repository object
  repository := clone(bare, directory):
    # or, if there was a problem, dump some error messages and bail out
    error &"unable to clone into `{directory}`: {code.dumpError}"
    return

  # make sure the project we find is in the directory we cloned to;
  # this could differ if the repo does not feature a dotNimble file
  if findProject(cloned, directory, parent = project) and
                 cloned.repo == directory:
    {.warning: "gratuitous nimblemeta write?".}
    let
      oid = repository.demandHead
    if not writeNimbleMeta(directory, bare, oid):
      warn &"unable to write {nimbleMeta} in {directory}"

    # review the local branches and add any missing tracking branches
    cloned.addMissingUpstreams

    result = true
  else:
    error "couldn't make sense of the project i just cloned"

  # if we're gonna fail, ensure that failure is felt
  if not result:
    cloned = nil

proc allImportTargets*(config: ConfigRef; repo: string):
  OrderedTableRef[Target, LinkedSearchResult] =
  ## yield projects from the group in the same order that they may be
  ## resolved by the compiler, if at all, given a particular configuration
  result = newOrderedTable[Target, LinkedSearchResult]()

  for path in config.extantSearchPaths:
    let
      target = linkedFindTarget(path, target = path.pathToImport.importName,
                                nimToo = true, ascend = false)
      found = target.search.found
    if found.isNone:
      continue
    result.add found.get, target

iterator asFoundVia*(group: var ProjectGroup; config: ConfigRef;
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
    # see if the target project is in our group
    for project in group.mvalues:
      if found.get == project.nimble:
        # if it is, put it in the dedupe and yield it
        if project.importName notin dedupe:
          dedupe.add project.importName, project
          yield project
        break

  # now report on anything we weren't able to discover
  for project in group.values:
    if project.importName notin dedupe:
      notice &"no path to {project.repo} as `{project.importName}`"

proc countNimblePaths*(project: Project):
  tuple[local: int; global: int; paths: seq[string]] =
  ## try to count the effective number of --nimblePaths
  let
    repository = project.repo
  # we start with looking for the most-used directories and then resort to the
  # least-frequently used entries, eventually settling for *any* lazy path at all
  for iteration in countDown(2, 0):
    for path in likelyLazy(project.cfg, repository, least = iteration):
      # we'll also differentiate between lazy
      # paths inside/outside the project tree
      if path.startsWith(repository):
        result.local.inc
      else:
        result.global.inc
      # and record the path for whatever that's worth
      result.paths.add path
    # as soon as the search catches results, we're done
    if result.local + result.global != 0:
      break

proc numberOfNimblePaths*(project: Project): int =
  ## simpler count of effective --nimblePaths
  result = project.countNimblePaths.paths.len

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

proc promoteRemoteLike*(project: Project; url: Uri; name = defaultRemote): bool =
  ## true if we were able to promote a url to be our new ssh origin
  let
    path = project.repo
    ssh = url.convertToSsh
    target = ssh.forkTarget

  # make sure the programmer isn't an idiot
  if project.dist != Git:
    let emsg = &"nonsensical promotion on {project.dist} distribution" # noqa
    raise newException(Defect, emsg)

  # we'll add missing upstreams after this block
  block donehere:
    repository := openRepository(project.gitDir):
      error &"unable to open repo at `{path}`: {code.dumpError}"
      break

    remote := repository.remoteLookup(name):
      case code:
      of GIT_ENOTFOUND:
        discard
      else:
        warn &"unable to fetch remote `{name}` from repo in {path}"
      break

    try:
      # maybe we've already pointed at the repo via ssh?
      if remote.url == ssh:
        result = true
        break
      # maybe we've already pointed at the repo, but we wanna upgrade the url
      if remote.url.forkTarget == target:
        info &"upgrading remote to ssh..."
    except:
      warn &"unparseable remote `{name}` from repo in {path}"
    var
      upstream = repository.remoteLookup(upstreamRemote)
    if upstream.isErr:
      # there's no upstream remote; what do we do with origin?
      if remote.url.forkTarget == target:
        # the origin isn't an ssh remote; remove it
        gitTrap repository.remoteDelete(name):
          # this should issue warnings of any problems...
          break
      else:
        # there's no upstream remote; rename origin to upstream
        let
          warnings = repository.remoteRename(name, upstreamRemote)
        if warnings.isErr:
          error &"{warnings.error}: unable to rename " &
                &"`{name}` to `{upstreamRemote}`:"
          error warnings.error.dumpError
          break
        # these are advisory messages of some sort (from git)
        for message in warnings.get.items:
          warn message
      # and make a new origin remote using the hubrepo's url
      upstream = repository.remoteCreate(defaultRemote, ssh)
      if upstream.isErr:
        warn &"unable to create remote `{defaultRemote}` in {path}"
        warn upstream.error.dumpError
        break
      # success
      result = true
      break

    try:
      # upstream exists, so, i dunno, just warn the user?
      if upstream.get.url.forkTarget != remote.url.forkTarget:
        warn &"remote `{upstreamRemote}` exists for repo in {path}"
      else:
        {.warning: "origin equals upstream; remove upstream and try again?".}
        warn &"remote `{upstreamRemote}` is the same as `{name}` in {path}"
    except:
      warn &"unparseable remote `{upstreamRemote}` from repo in {path}"

  # review the local branches and add any missing tracking branches
  project.addMissingUpstreams

proc promote*(project: Project; name = defaultRemote;
             user: HubResult = nil): bool =
  ## promote a project's remote to a user's repo, if it's theirs
  var
    user: HubResult = user
  block:
    try:
      let gotUser = waitfor getGitHubUser()
      if gotUser.isSome:
        user = gotUser.get
      else:
        debug &"unable to fetch github user"
        break
    except Exception as e:
      warn e.msg
      break

    let
      target = project.url.forkTarget
    if target.ok and target.owner == user.login:
      result = project.promoteRemoteLike(project.url, name = name)

proc newRequirementsTags(flags = defaultFlags): RequirementsTags =
  result = RequirementsTags(flags: flags)
  result.init(flags, mode = modeCaseSensitive)

proc requirementChangingCommits*(project: Project): RequirementsTags =
  # a table of the commits that changed the Requirements in a Project's
  # dotNimble file
  result = newRequirementsTags()

proc repoLockReady*(project: Project): bool =
  ## true if a project's git repo is ready to be locked
  if project.dist != Git:
    return

  block:
    repository := openRepository(project.gitDir):
      error &"unable to open repo at `{project.repo}`: {code.dumpError}"
      break

    # this is a high-level state check to ensure the
    # repo isn't in the middle of a merge, bisect, etc.
    let state = repository.repositoryState
    if state != GIT_REPOSITORY_STATE_NONE:
      notice &"{project} repository in invalid {state} state"
    else:
      # it's our game to lose
      result = true

      # an alien file isn't a problem, but virtually anything else is
      for n in repository.status(GIT_STATUS_SHOW_INDEX_AND_WORKDIR):
        result = false
        notice &"{project} repository has been modified"
        break

proc bestRelease*(tags: GitTagTable; goal: RollGoal): Version {.deprecated.} =
  ## the most ideal tagged release parsable as a version; we should probably use
  ## versiontags for this now
  var
    names = toSeq tags.keys
  case goal
  of Downgrade:
    discard
  of Upgrade:
    names.reverse
  of Specific:
    raise newException(Defect, "nonsensical")

  for tagged in names.items:
    let
      parsed = parseVersionLoosely(tagged)
    if parsed.isSome and parsed.get.kind == Equal:
      result = parsed.get.version

proc betterReleaseExists(tags: GitTagTable; goal: RollGoal; version: Version): bool =
  ## true if there is an ideal version available; we should probably use
  ## versiontags for this now
  var
    names = toSeq tags.keys
  case goal
  of Upgrade:
    names.reverse
  of Downgrade, Specific:
    discard

  for name in names.items:
    # skip cases where a commit hash is tagged as itself, ie. head
    let
      parsed = parseVersionLoosely(name)
    if parsed.isSome:
      case goal
      of Upgrade:
        result = parsed.get.effectively > version
      of Downgrade:
        result = parsed.get.effectively < version
      of Specific:
        result = parsed.get.effectively == version
      if result:
        break

proc betterReleaseExists(project: Project; goal: RollGoal): bool =
  ## true if there is a (more) ideal version available; we should probably use
  ## versiontags for this now
  if project.tags == nil:
    let emsg = &"unable to fetch tags for an immutable project {project.name}"
    raise newException(Defect, emsg)

  head := project.getHeadOid:
    # no head means no tags means no upgrades
    return

  # make sure this isn't a nonsensical request
  case goal
  of Upgrade, Downgrade:
    discard
  of Specific:
    raise newException(Defect, "not implemented")

  result = betterReleaseExists(project.tags, goal, project.version)

proc betterReleaseExists*(project: var Project; goal: RollGoal): bool {.deprecated.} =
  ## true if there is a (more) ideal version available
  if project.tags == nil:
    project.fetchTagTable
  let readonly = project
  result = readonly.betterReleaseExists(goal)

proc nextTagFor*(tags: GitTagTable; version: Version): string =
  ## produce a new tag given previous tags
  var latest: string
  # due to sorting, the last tag should be the latest version
  for tag in tags.keys:
    latest = tag
  # add any silly v. prefix as necessary
  result = pluckVAndDot(latest) & $version

proc setHeadToRelease*(project: var Project; release: Release): bool =
  ## advance the head of a project to a particular release
  block:
    # we don't yet know how to roll to non-git releases
    {.warning: "roll to non-git releases".}
    if project.dist != Git:
      break
    # we don't yet know how to roll to arbitrary releases
    {.warning: "roll to arbitrary releases".}
    if not release.isValid or release.kind != Tag:
      break
    repository := openRepository(project.gitDir):
      error &"unable to open repo at `{project.repo}`: {code.dumpError}"
      break
    # we want the code because it'll tell us what went wrong
    let code = repository.checkoutTree(release.reference)
    case code:
    of GIT_OK:
      result = true
      # make sure we invalidate some data
      project.dump = nil
      project.version = (0'u, 0'u, 0'u)
      debug &"roll {project.name} to {release}"
    else:
      debug &"roll {project.name} to {release}: {code}"
      debug code.dumpError

template returnToHeadAfter*(project: var Project; body: untyped) =
  ## run some code in the body if you can, and then return the
  ## project to where it was in git before you left

  block:
    # we may have no head; if that's the case, we have no tags either
    previous := project.getHeadOid:
      break

    # this could just be a bad idea all the way aroun'
    if not project.repoLockReady:
      error "refusing to roll the repo when it's dirty"
      break

    repository := openRepository(project.gitDir):
      error &"unable to open repo at `{project.repo}`: {code.dumpError}"
      break

    # if we have no way to get back, don't even depart
    home := repository.referenceDWIM("HEAD"):
      raise newException(IOError, "i'm lost; where am i?")

    defer:
      # there's no place like home
      if not project.setHeadToRelease(newRelease($previous,
                                                 operator = Tag)):
        raise newException(IOError, "cannot detach head to " & $previous)

      # re-attach the head if we can
      if repository.setHead($home.name) != GIT_OK:
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
    block:
      repository := openRepository(project.gitDir):
        error "Cannot get version changing commits - unable to open repo at" &
          &"`{project.repo}`: {code.dumpError}"

        break
      # iterate over commits to the dotNimble file
      for thing in repository.commitsForSpec(@[package]):
        if thing.isErr:
          error thing.error.dumpError # error error error!
          break
        # compose a new release to the commit and then go there
        let release = newRelease($thing.get.oid, operator = Tag)
        if project.setHeadToRelease(release):
          # freshen project version, release, etc.
          project.refresh
          result[project.version] = thing.get

proc pathForName*(group: ProjectGroup; name: string): Option[string] =
  ## try to retrieve the directory for a given import name in the group
  let name = name.destylize
  for project in group.values:
    if project.importName.destylize == name:
      result = project.repo.some
      break
