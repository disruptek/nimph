import std/uri except Url
import std/tables
import std/os
import std/strutils
import std/asyncdispatch
import std/options
import std/strformat
import std/sequtils

import bump
import gittyup
import badresults

import nimph/spec
import nimph/paths
import nimph/runner
import nimph/projects
import nimph/doctor
import nimph/thehub
import nimph/config
import nimph/packages
import nimph/dependencies
import nimph/lockers
import nimph/groups
import nimph/requirements

template crash(why: string) =
  ## a good way to exit nimph
  error why
  return 1

method pretty(ex: ref Exception): string {.base.} =
  let
    prefix = $typeof(ex)
  result = prefix.split(" ")[^1] & ": " & ex.msg

template warnException() =
  warn getCurrentException().pretty

const
  logLevel =
    when defined(debug):
      lvlDebug
    elif defined(release):
      lvlNotice
    elif defined(danger):
      lvlNotice
    else:
      lvlInfo

template prepareForTheWorst(body: untyped) =
  when defined(release) or defined(danger):
    try:
      body
    except:
      warnException
      error "crashing because something bad happened"
      quit 1
  else:
    body

proc setupLocalProject(): Project =
  prepareForTheWorst:
    result = findProject(getCurrentDir().toAbsoluteDir)
    if result.isNil:
      error &"unable to find a project; try `git init .`?"
      quit 1
    try:
      debug &"load all configs from {result.root}"
      result.cfg = loadAllCfgs(result.root)
      debug "done loading configs"
    except Exception as e:
      raise newException(ValueError,
                         "unable to parse nim configuration: " & e.msg)

template toggle(flags: set[Flag]; flag: Flag; switch: untyped) =
  when switch is bool:
    if switch:
      flags.incl flag
    else:
      flags.excl flag

template composeFlags(defaults): set[Flag] =
  ## setup flags using cli inputs
  block:
    var
      flags: set[Flag] = defaults
    toggle(flags, Quiet, quiet)
    toggle(flags, Safe, safe_mode)
    toggle(flags, Dry, dry_run)
    toggle(flags, Strict, strict)
    toggle(flags, Force, force)
    toggle(flags, Network, network)
    flags

proc findChildProjectUsing(group: DependencyGroup; name: string;
                           flags: set[Flag]): Result[Project, string] =
  ## search the group for a named project using options specified in flags
  var name = importName name
  let
    found = group.projectForName(name)

  block complete:
    var
      nature = "dependency"
    if found.isSome:
      result.ok get(found)
      break complete
    elif Strict notin flags:
      for child in group.projects.values:
        if child.importName == name:
          result.ok child
          break complete
      nature = "project"
    let emsg = &"couldn't find a {nature} importable as `{name}`" # noqa
    result.err emsg

proc searcher*(args: seq[string]; strict = false;
               log_level = logLevel; safe_mode = false; quiet = true;
               network = true; force = false; dry_run = false): int =
  ## cli entry to search github for nim packages

  # user's choice, our default
  setLogFilter(log_level)

  if args.len == 0:
    crash &"a search was requested but no query parameters were provided"
  let
    group = waitfor searchHub(args)
  if group.isNone:
    crash &"unable to retrieve search results from github"
  for repo in get(group).reversed:
    fatal "\n" & repo.renderShortly
  if get(group).len == 0:
    fatal &"😢no results"

proc fixer*(strict = false;
            log_level = logLevel; safe_mode = false; quiet = false;
            network = true; force = false; dry_run = false): int =
  ## cli entry to evaluate and/or repair the environment

  # user's choice, our default
  setLogFilter(log_level)

  var
    project = setupLocalProject()

  if project.doctor(dry = dry_run):
    fatal &"👌{project.name} version {project.version} lookin' good"
  elif not dry_run:
    crash &"the doctor wasn't able to fix everything"
  else:
    warn "run `nimph doctor` to fix this stuff"

proc nimbler*(args: seq[string]; strict = false;
              log_level = logLevel; safe_mode = false; quiet = true;
              network = true; force = false; dry_run = false): int =
  ## cli entry to pass-through nimble commands with a sane nimbleDir

  # user's choice, our default
  setLogFilter(log_level)

  var
    project = setupLocalProject()

  let
    nimble = project.runSomething("nimble", args)
  if not nimble.ok:
    crash &"nimble didn't like that"

proc pather*(names: seq[string]; strict = false;
             log_level = logLevel; safe_mode = false; quiet = true;
             network = true; force = false; dry_run = false): int =
  ## cli entry to echo the path(s) of any dependencies

  # user's choice, our default
  setLogFilter(log_level)

  # setup flags for the operation
  let flags = composeFlags(defaultFlags)

  var
    project = setupLocalProject()

  if names.len == 0:
    crash &"give me an import name to retrieve its filesystem path"

  # setup our dependency group
  var group = project.newDependencyGroup(flags = flags)
  if not project.resolve(group):
    notice &"unable to resolve all dependencies for {project}"

  # for convenience, add the project itself if possible
  if not group.hasKey(project.importName):
    let dependency = newDependency(project)
    group.add dependency.requirement, dependency

  for name in names.items:
    var
      child = group.findChildProjectUsing(name, flags = flags)
    if child.isOk:
      echo get(child).root
    else:
      error child.error
      result = 1

proc runion*(args: seq[string]; git = false; strict = false;
             log_level = logLevel; safe_mode = false; quiet = true;
             network = true; force = false; dry_run = false): int =
  ## this is another pather, basically, that invokes the arguments in the path
  let
    exe = args[0]
    args = args[1..^1]

  # user's choice, our default
  setLogFilter(log_level)

  # setup flags for the operation
  let flags = composeFlags(defaultFlags)

  var
    project = setupLocalProject()

  # setup our dependency group
  var group = project.newDependencyGroup(flags = flags)
  if not project.resolve(group):
    notice &"unable to resolve all dependencies for {project}"

  # make sure we visit every project that fits the requirements
  for req, dependency in group.pairs:
    for child in dependency.projects.values:
      if child.dist == Git or not git:
        withinDirectory(child.root):
          info &"running {exe} in {child.root}"
          let
            got = project.runSomething(exe, args)
          if not got.ok:
            error &"{exe} didn't like that in {child.root}"
            result = 1

proc rollChild(child: var Project; requirement: Requirement; goal: RollGoal;
               safe_mode = false; dry_run = false): bool =
  ## try to roll a project to meet the goal inside a given requirement

  # early termination means there's nowhere else to go from here
  result = true

  block:
    if child.dist != Git:
      break
    if child.name.toLowerAscii in ["nim", "compiler"]:
      debug &"ignoring the compiler"
      break

    # if there's no suitable release available, we're done
    case goal:
    of Upgrade, Downgrade:
      if not child.betterReleaseExists(goal):
        debug &"no {goal} available for {child.name}"
        break
    of Specific:
      discard

    # if we're successful in rolling the project, we're done
    result = child.roll(requirement, goal = goal, dry_run = dry_run)
    if result:
      break

    # else let's see if we can offer useful output
    let
      best = child.tags.bestRelease(goal)
    case goal:
    of Upgrade:
      if child.version < best:
        notice &"the latest {child.name} release of {best} is masked"
        break
    of Downgrade:
      if child.version > best:
        notice &"the earliest {child.name} release of {best} is masked"
        break
    of Specific:
      discard

    # the user expected a change and got none
    if not dry_run:
      warn &"unable to {goal} {child.name}"

proc updowner*(names: seq[string]; goal: RollGoal; strict = false;
             log_level = logLevel; safe_mode = false; quiet = true;
             network = true; force = false; dry_run = false): int =
  ## perform upgrades or downgrades of dependencies
  ## within project requirement specifications

  # user's choice, our default
  setLogFilter(log_level)

  # setup flags for the operation
  let flags = composeFlags(defaultFlags)

  var
    project = setupLocalProject()

  # setup our dependency group
  var group = project.newDependencyGroup(flags = flags)
  if not project.resolve(group):
    notice &"unable to resolve all dependencies for {project}"

  # we receive import names (or not) and upgrade or downgrade them to
  # opposite ends of the list of allowable versions, per our requirements
  if names.len == 0:
    for requirement, dependency in group.pairs:
      for child in dependency.projects.mvalues:
        if not child.rollChild(requirement, goal = goal, dry_run = dry_run):
          result = 1
  else:
    for name in names.items:
      let found = group.projectForName(name)
      if found.isSome:
        var child = get(found)
        let require = group.reqForProject(child)
        if require.isNone:
          let emsg = &"found `{name}` but not its requirement" # noqa
          raise newException(ValueError, emsg)
        if not child.rollChild(get(require), goal = goal, dry_run = dry_run):
          result = 1
      else:
        error &"couldn't find `{name}` among our installed dependencies"

  if result == 0:
    fatal &"👌{project.name} is lookin' good"
  else:
    fatal &"👎{project.name} is not where you want it"

proc roller*(names: seq[string]; strict = false;
             log_level = logLevel; safe_mode = false; quiet = false;
             network = true; force = false; dry_run = false): int =
  ## roll a project's dependencies to specific requirements

  # user's choice, our default
  setLogFilter(log_level)

  # setup flags for the operation
  let flags = composeFlags(defaultFlags)

  var
    project = setupLocalProject()

  # setup our dependency group
  var group = project.newDependencyGroup(flags = flags)
  if not project.resolve(group):
    notice &"unable to resolve all dependencies for {project}"

  # we receive requirements and add them to the group, then
  # we run fixDependencies to resolve them as best as can
  if names.len == 0:
    notice &"give me requirements as string arguments; eg. 'foo > 2.*'"
    result = 1
    return

  block doctor:
    # parse the requirements as if we pulled them right outta a .nimble
    let
      requires = parseRequires(names.join(", "))
    if requires.isNone:
      notice &"unable to parse requirements statement(s)"
      result = 1
      break doctor

    # perform our usual dependency fixups using the doctor
    var
      state = DrState(kind: DrRetry)
    while state.kind == DrRetry:
      # everything seems groovy at the beginning
      result = 0
      # add each requirement to the dependency tree
      for requirement in get(requires).values:
        var
          dependency = newDependency(requirement)
        # we really don't care if requirements are added here
        discard group.addedRequirements(dependency)
        # make sure we can resolve the requirement
        if not project.resolve(group, requirement):
          notice &"unable to resolve dependencies for `{requirement}`"
          result = 1
          state.kind = DrError
          # this is game over
          break doctor
      if not project.fixDependencies(group, state):
        notice "failed to fix all dependencies"
        result = 1
      if state.kind notin {DrRetry}:
        break
      # reset the tree
      group.reset(project)

  if result == 0:
    fatal &"👌{project.name} is lookin' good"
  else:
    fatal &"👎{project.name} is not where you want it"

proc graphProject(project: var Project; path: AbsoluteDir;
                  log_level = logLevel) =
  fatal "  directory: " & $path
  fatal "    project: " & $project
  if project.dist == Git:
    # show tags for info or less
    if log_level <= lvlInfo:
      project.fetchTagTable
      if project.tags != nil and project.tags.len > 0:
        info "tagged release commits:"
        for tag, thing in project.tags.pairs:
          info &"    tag: {tag:<20} {thing}"
    # show versions for info or less
    if log_level <= lvlInfo:
      let versions = project.versionChangingCommits
      if versions != nil and versions.len > 0:
        info "untagged version commits:"
        for ver, thing in versions.pairs:
          if not project.tags.hasThing(thing):
            info &"    ver: {ver:<20} {thing}"

proc graphDep(dependency: var Dependency; log_level = logLevel) =
  ## dump something vaguely useful to describe a dependency
  for pack in dependency.packages.keys:
    fatal "    package: " & $pack
  for directory, project in dependency.projects.mpairs:
    graphProject(project, directory, log_level = log_level)

proc graphDep(dependency: var Dependency; requirement: Requirement;
              log_level = logLevel) =
  ## dump something vaguely useful to describe a dependency
  for req in requirement.orphans:
    fatal "requirement: " & req.describe
  dependency.graphDep(log_level = log_level)

proc grapher*(names: seq[string]; strict = false;
              log_level = logLevel; safe_mode = false; quiet = true;
              network = true; force = false; dry_run = false): int =
  ## graph requirements for the project or any of its dependencies

  # user's choice, our default
  setLogFilter(log_level)

  # setup flags for the operation
  let flags = composeFlags(defaultFlags)

  var
    project = setupLocalProject()

  # setup our dependency group
  var group = project.newDependencyGroup(flags = flags)
  if not project.resolve(group):
    notice &"unable to resolve all dependencies for {project}"

  # for convenience, add the project itself if possible
  if not group.hasKey(project.importName):
    let dependency = newDependency(project)
    group.add dependency.requirement, dependency

  if names.len == 0:
    for requirement, dependency in group.mpairs:
      fatal ""
      dependency.graphDep(requirement, log_level = log_level)
  else:
    for name in names.items:
      var
        child = group.findChildProjectUsing(name, flags = flags)
      if child.isErr:
        error child.error
        result = 1
      else:
        fatal ""
        let require = group.reqForProject(get child)
        if require.isNone:
          notice &"found `{name}` but not its requirement" # noqa
          get(child).graphProject(get(child).root, log_level = log_level)
        else:
          {.warning: "nim bug #12818".}
          for requirement, dependency in group.mpairs:
            if requirement == get(require):
              dependency.graphDep(requirement, log_level = log_level)

proc dumpLockList(project: Project) =
  for room in project.allLockerRooms:
    once:
      fatal &"here's a list of available locks:"
    fatal &"\t{room.name}"

proc lockfiler*(names: seq[string]; strict = false;
                log_level = logLevel; safe_mode = false; quiet = false;
                network = true; force = false; dry_run = false): int =
  ## cli entry to write a lockfile

  # user's choice, our default
  setLogFilter(log_level)

  var
    project = setupLocalProject()

  block:
    let name = names.join(" ")
    if name == "":
      project.dumpLockList
      fatal &"give me some arguments so i can name the lock"
    else:
      if project.lock(name):
        fatal &"👌locked {project} as `{name}`"
        break
      fatal &"👎unable to lock {project} as `{name}`"
      result = 1

proc unlockfiler*(names: seq[string]; strict = false;
                  log_level = logLevel; safe_mode = false; quiet = false;
                  network = true; force = false; dry_run = false): int =
  ## cli entry to read a lockfile

  # user's choice, our default
  setLogFilter(log_level)

  var
    project = setupLocalProject()

  block:
    let name = names.join(" ")
    if name == "":
      project.dumpLockList
      fatal &"give me some arguments so i can fetch the lock by name"
    else:
      if project.unlock(name):
        fatal &"👌unlocked {project} via `{name}`"
        break
      fatal &"👎unable to unlock {project} via `{name}`"
    result = 1

proc tagger*(strict = false;
             log_level = logLevel; safe_mode = false; quiet = false;
             network = true; force = false; dry_run = false): int =
  ## cli entry to add missing tags

  # user's choice, our default
  setLogFilter(log_level)

  var
    project = setupLocalProject()

  if project.fixTags(dry_run = dry_run, force = force):
    if dry_run:
      warn "run without --dry-run to fix these"
    else:
      crash &"the doctor wasn't able to fix everything"
  else:
    fatal &"👌{project.name} tags are lookin' good"

proc forker*(names: seq[string]; strict = false;
             log_level = logLevel; safe_mode = false; quiet = false;
             network = true; force = false; dry_run = false): int =
  ## cli entry to remotely fork installed packages

  # user's choice, our default
  setLogFilter(log_level)

  # setup flags for the operation
  let flags = composeFlags(defaultFlags)

  var
    project = setupLocalProject()

  # setup our dependency group
  var group = project.newDependencyGroup(flags = flags)
  if not project.resolve(group):
    notice &"unable to resolve all dependencies for {project}"

  # for convenience, add the project itself if possible
  if not group.hasKey(project.importName):
    let dependency = newDependency(project)
    group.add dependency.requirement, dependency

  for name in names.items:
    var
      child = group.findChildProjectUsing(name, flags = flags)
    if child.isErr:
      error child.error
      result = 1
      continue
    let
      fork = get(child).forkTarget
    if not fork.ok:
      error fork.why
      result = 1
      continue
    info &"🍴forking {get(child)}"
    let forked = waitfor forkHub(fork.owner, fork.repo)
    if forked.isNone:
      result = 1
      continue
    fatal &"🔱{get(forked).web}"
    case get(child).dist:
    of Git:
      let name = defaultRemote
      if not get(child).promoteRemoteLike(get(forked).git, name = name):
        notice &"unable to promote new fork to {name}"
    else:
      {.warning: "optionally upgrade a gitless install to clone".}

proc cloner*(args: seq[string]; strict = false;
             log_level = logLevel; safe_mode = false; quiet = true;
             network = true; force = false; dry_run = false): int =
  ## cli entry to clone a package into the environment

  # user's choice, our default
  setLogFilter(log_level)

  # setup flags for the operation
  let flags = composeFlags(defaultFlags)

  var
    url: Uri
    name: string

  if args.len == 0:
    crash &"provide a single url, or a github search query"

  # if only one argument was supplied, see if we can parse it as a url
  if args.len == 1:
    try:
      let
        uri = parseUri(args[0])
      if uri.isValid:
        url = uri
        name = url.importName
    except:
      discard

  var
    project = setupLocalProject()

  # if the input wasn't parsed to a url,
  if not url.isValid:
    # search github using the input as a query
    let
      query {.used.} = args.join(" ")
      hubs = waitfor searchHub(args)
    if hubs.isNone:
      crash &"unable to retrieve search results from github"

    # and pluck the first result, presumed to be the best
    block found:
      for repo in get(hubs).values:
        url = repo.git
        name = repo.name
        break found
      crash &"unable to find a package matching `{query}`"

  # if we STILL don't have a url, we're done
  if not url.isValid:
    crash &"unable to determine a valid url to clone"

  # perform the clone
  var
    cloned = project.clone(url, name)
  if cloned.isNil:
    crash &"problem cloning {url}"

  # reset our paths to, hopefully, grab the new project
  project.cfg = loadAllCfgs(project.root)

  # setup our dependency group
  var group = project.newDependencyGroup(flags = flags)
  if not project.resolve(group):
    notice &"unable to resolve all dependencies for {project}"

  # see if we can find this project in the dependencies
  let needed = group.projectForPath(cloned.root)

  # if it's in there, let's get its requirement and roll to meet it
  block relocated:
    if needed.isSome:
      let requirement = group.reqForProject(cloned)
      if requirement.isNone:
        warn &"unable to retrieve requirement for {cloned.name}"
      else:
        # rollTowards will relocate us, too
        if cloned.rollTowards(get requirement):
          notice &"rolled {cloned.name} to {cloned.version}"
          # so skip the tail of this block (and a 2nd relocate)
          break relocated
        notice &"unable to meet {get(requirement)} with {cloned}"
    # rename the directory to match head release
    project.relocateDependency(cloned)

  # try to point it at github if it looks like it's our repo
  if not cloned.promote:
    debug &"did not promote remote to ssh"

template dumpHelp(fun: typed; use: string) =
  try:
    discard fun(cmdline = @["--help"], prefix = "    ",
                usage = use, noHdr = true)
  except HelpOnly:
    discard

when isMainModule:
  import cligen
  type
    SubCommand = enum
      scHelp = "--help"
      scDoctor = "doctor"
      scSearch = "search"
      scClone = "clone"
      scNimble = "nimble"
      scPath = "path"
      scFork = "fork"
      scLock = "lock"
      scUnlock = "unlock"
      scTag = "tag"
      scRun = "run"
      scRoll = "roll"
      scUpDown = "outdated"
      scGraph = "graph"
      scVersion = "--version"

    AliasTable = Table[string, seq[string]]

  let
    logger = newCuteConsoleLogger()
  addHandler(logger)

  const
    release = projectVersion()
  if release.isSome:
    clCfg.version = $get(release)
  else:
    clCfg.version = "(unknown version)"

  # setup some dispatchers for various subcommands
  dispatchGen(searcher, cmdName = $scSearch, dispatchName = "run" & $scSearch,
              doc="search github for packages")
  dispatchGen(fixer, cmdName = $scDoctor, dispatchName = "run" & $scDoctor,
              doc="repair (or report) env issues")
  dispatchGen(cloner, cmdName = $scClone, dispatchName = "run" & $scClone,
              doc="add a package to the env")
  dispatchGen(pather, cmdName = $scPath, dispatchName = "run" & $scPath,
              doc="fetch package path(s) by import name(s)")
  dispatchGen(forker, cmdName = $scFork, dispatchName = "run" & $scFork,
              doc="fork a package to your GitHub profile")
  dispatchGen(lockfiler, cmdName = $scLock, dispatchName = "run" & $scLock,
              doc="lock dependencies")
  dispatchGen(unlockfiler, cmdName = $scUnlock, dispatchName = "run" & $scUnlock,
              doc="unlock dependencies")
  dispatchGen(tagger, cmdName = $scTag, dispatchName = "run" & $scTag,
              doc="tag versions")
  dispatchGen(roller, cmdName = $scRoll, dispatchName = "run" & $scRoll,
              doc="roll project dependency versions")
  dispatchGen(updowner, cmdName = $scUpDown, dispatchName = "run" & $scUpDown,
              doc="upgrade or downgrade project dependencies")
  dispatchGen(grapher, cmdName = $scGraph, dispatchName = "run" & $scGraph,
              doc="graph project dependencies")
  dispatchGen(nimbler, cmdName = $scNimble, dispatchName = "run" & $scNimble,
              doc="Nimble handles other subcommands (with a proper nimbleDir)")
  dispatchGen(runion, cmdName = $scRun, dispatchName = "run" & $scRun,
              stopWords = @["--"],
              doc="execute the program & arguments in every dependency directory")
  const
    # these commands exist only as aliases to other commands
    trueAliases = {
      # the nurse is aka `nimph` without arguments...
      "nurse":       @[$scDoctor, "--dry-run"],
      "fix":         @[$scDoctor],
      "fetch":       @[$scRun, "--git", "--", "git", "fetch"],
      "pull":        @[$scRun, "--git", "--", "git", "pull"],
      "roll":        @[$scRoll],
      "downgrade":   @[$scUpDown, "--goal=downgrade"],
      "upgrade":     @[$scUpDown, "--goal=upgrade"],
      "outdated":    @[$scUpDown, "--goal=upgrade", "--dry-run"],
    }.toTable

  proc makeAliases(passthrough: openArray[string]): AliasTable {.compileTime.} =
    # command aliases can go here
    result = trueAliases

    # add in the default subcommands
    for sub in SubCommand.low .. SubCommand.high:
      if $sub notin result:
        result[$sub] = @[$sub]

    # associate known nimble subcommands
    for sub in passthrough.items:
      if sub notin result:
        result[sub] = @[$scNimble, sub]

  const
    # these are our subcommands that we want to include in help
    dispatchees = [scDoctor, scSearch, scClone, scPath, scFork, scLock,
                   scUnlock, scTag, scUpDown, scRoll, scGraph, scRun]

    # these are nimble subcommands that we don't need to warn about
    passthrough = ["install", "uninstall", "build", "test", "doc", "dump",
                   "refresh", "list", "tasks"]

    # associate commands to dispatchers created by cligen
    dispatchers = {
      scSearch: runsearch,
      scDoctor: rundoctor,
      scClone: runclone,
      scPath: runpath,
      scFork: runfork,
      scLock: runlock,
      scUnlock: rununlock,
      scTag: runtag,
      scRun: runrun,
      scRoll: runroll,
      scGraph: rungraph,
      scUpDown: runoutdated,
    }.toTable

    # setup the mapping between subcommand and expanded parameters
    aliases = makeAliases(passthrough)

  var
    # get the command line
    params = commandLineParams()

  # get the subcommand one way or another
  if params.len == 0:
    params = @["nurse"]
  let first = params[0].strip.toLowerAscii

  # try to parse the subcommand
  var sub: SubCommand
  if first in aliases:
    # expand the alias
    params = aliases[first].concat params[1..^1]
    # and then parse the subcommand
    sub = parseEnum[SubCommand](params[0])
  else:
    # if we couldn't parse it, try passing it to nimble
    warn &"unrecognized subcommand `{first}`; passing it to Nimble..."
    sub = scNimble

  # take action according to the subcommand
  try:
    case sub:
    of scNimble:
      # remove any gratuitous `nimble` specified by user or alias
      if params[0] == "nimble":
        params = @["--"] & params[1..^1]
      # invoke nimble with the remaining parameters
      prepareForTheWorst:
        quit runnimble(cmdline = params)
    of scVersion:
      # report the version
      echo clCfg.version
    of scHelp:
      # yield some help
      echo "run `nimph` for a non-destructive report, or use a subcommand;"
      for command in dispatchees.items:
        let fun = dispatchers[command]
        once:
          fun.dumpHelp("all subcommands accept (at least) the following options:\n$options")
        case command:
        of scRun:
          fun.dumpHelp("\n$command --git $args\n$doc")
        of scUpDown:
          fun.dumpHelp("\n$command --goal=upgrade|downgrade $args\n$doc")
        else:
          fun.dumpHelp("\n$command $args\n$doc")
      echo ""
      echo "    " & passthrough.join(", ")
      let nimbleUse = "    $args\n$doc"
      # produce help for nimble subcommands
      runnimble.dumpHelp(nimbleUse)

      echo "\n    Some additional subcommands are implemented as aliases:"
      for alias, arguments in trueAliases.pairs:
        # don't report aliases that are (trivial) aliases of themselves 😜
        if alias == arguments[0] and arguments.len == 1:
          continue
        let alias = "nimph " & alias
        echo &"""    {alias:>16} -> nimph {arguments.join(" ")}"""
    else:
      # we'll enhance logging for these subcommands
      if first in ["outdated", "nurse"]:
        let newLog = max(0, logLevel.ord - 1).Level
        params = params.concat @["--log-level=" & $newLog]
      # invoke the appropriate dispatcher
      prepareForTheWorst:
        quit dispatchers[sub](cmdline = params[1..^1])
  except HelpOnly:
    discard
  quit 0
