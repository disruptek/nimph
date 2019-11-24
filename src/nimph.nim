import std/uri
import std/tables
import std/os
import std/strutils
import std/asyncdispatch
import std/options
import std/strformat

import bump

import nimph/spec
import nimph/nimble
import nimph/project
import nimph/doctor
import nimph/thehub
import nimph/config
import nimph/package

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
      crash("crashing because something bad happened")
  else:
    body

template setupLocalProject(project: var Project) =
  if not findProject(project):
    crash &"unable to find a project; try `nimble init`?"
  try:
    project.cfg = loadAllCfgs()
  except Exception as e:
    crash "unable to parse nim configuration: " & e.msg

proc searcher*(args: seq[string]; log_level = logLevel): int =
  # user's choice, our default
  setLogFilter(log_level)

  if args.len == 0:
    crash &"a search was requested but no query parameters were provided"
  let
    group = waitfor searchHub(args)
  if group.isNone:
    crash &"unable to retrieve search results from github"
  for repo in group.get.reversed:
    fatal "\n" & repo.renderShortly

proc fixer*(dry_run = false; log_level = logLevel): int =
  # user's choice, our default
  setLogFilter(log_level)

  var project: Project
  setupLocalProject(project)

  prepareForTheWorst:
    if project.doctor(dry = dry_run):
      fatal &"👌{project.nimble.package} version {project.version} lookin' good"
    elif not dry_run:
      crash &"the doctor wasn't able to fix everything"
    else:
      warn "run `nimph doctor` to fix this stuff"

proc nimbler*(args: seq[string]; log_level = logLevel): int =
  # user's choice, our default
  setLogFilter(log_level)

  var project: Project
  setupLocalProject(project)

  let
    nimble = project.runNimble(args)
  if not nimble.ok:
    crash &"nimble didn't like that"

proc cloner*(args: seq[string]; log_level = logLevel): int =
  # user's choice, our default
  setLogFilter(log_level)

  var
    url: Uri
    name: string

  if args.len == 0:
    crash &"provide a single url, or a github search query"
  elif args.len == 1:
    try:
      let
        uri = parseUri(args[0])
      if uri.isValid:
        url = uri
        name = url.path.naiveName
    except:
      discard

  var project: Project
  setupLocalProject(project)

  if not url.isValid:
    let
      query {.used.} = args.join(" ")
      group = waitfor searchHub(args)
    if group.isNone:
      crash &"unable to retrieve search results from github"

    var
      repository: HubRepo
    block found:
      for repos in group.get.values:
        repository = repos
        url = repository.git
        name = repository.name
        break found
      crash &"unable to find a package matching `{query}`"

  if not url.isValid:
    crash &"unable to determine a valid url to clone"

  if not project.clone(url, name):
    crash &"unable to clone {url}"
  fatal &"👌cloned {url}"

when isMainModule:
  import cligen
  type
    CommandType = proc (cmdline: seq[string], usage: string, prefix: string,
                        parseOnly: bool): int
    SubCommand = enum
      scDoctor = "doctor"
      scSearch = "search"
      scClone = "clone"
      scNimble = "nimble"
      scVersion = "--version"
      scHelp = "--help"

  let
    console = newConsoleLogger(levelThreshold = lvlAll,
                               useStderr = true, fmtStr = "")
    logger = newCuteLogger(console)
  addHandler(logger)

  const
    version = projectVersion()
  if version.isSome:
    clCfg.version = $version.get
  else:
    clCfg.version = "(unknown version)"

  # setup some dispatches for various subcommands
  dispatchGen(searcher, cmdName = $scSearch, dispatchName = "run" & $scSearch,
              doc="search github for packages")
  dispatchGen(fixer, cmdName = $scDoctor, dispatchName = "run" & $scDoctor,
              doc="repair (or report) env issues")
  dispatchGen(cloner, cmdName = $scClone, dispatchName = "run" & $scClone,
              doc="add a package to the env")
  dispatchGen(nimbler, cmdName = $scNimble, dispatchName = "run" & $scNimble,
              doc="Nimble handles other subcommands (with a proper nimbleDir)")

  const
    # these are our subcommands that we want to include in help
    dispatchees = [runsearch, runclone, rundoctor]

    # these are nimble subcommands that we don't need to warn about
    passthrough = ["install", "uninstall", "build", "test", "doc",
                   "path", "doc", "doc2", "refresh", "list", "tasks"]

  var
    # get the command line
    params = commandLineParams()

    # command aliases can go here
    aliases = {
      "fix": scDoctor,
    }.toTable

    # associate commands to dispatchers created by cligen
    dispatchers = {
      scSearch: runsearch,
      scDoctor: rundoctor,
      scClone: runclone,
      #scNimble: runnimble,
    }.toTable

  # obviate the need to run parseEnum
  for sub in SubCommand.low .. SubCommand.high:
    aliases[$sub] = sub

  # don't warn if it's an expected Nimble subcommand
  for sub in passthrough.items:
    aliases[sub] = scNimble

  # maybe just run the nurse
  if params.len == 0:
    let newLog = max(0, logLevel.ord - 1).Level
    quit dispatchers[scDoctor](cmdline = @["--dry-run", "--log-level=" & $newLog])

  # try to parse the subcommand
  var sub: SubCommand
  let first = params[0].strip.toLowerAscii
  if first in aliases:
    sub = aliases[first]
  else:
    # if we couldn't parse it, try passing it to nimble
    warn &"unrecognized subcommand `{first}`; passing it to Nimble..."
    sub = scNimble

  # take action according to the subcommand
  try:
    case sub:
    of scSearch, scDoctor, scClone:
      # invoke the appropriate dispatcher
      quit dispatchers[sub](cmdline = params[1..^1])
    of scNimble:
      # invoke nimble with the original parameters
      quit runnimble(cmdline = params)
    of scVersion:
      # report the version
      echo clCfg.version
    of scHelp:
      # yield some help
      echo "run `nimph` for a non-destructive report, or use a subcommand:"
      for fun in dispatchees.items:
        let use = "\n$command $args\n$doc$options"
        try:
          discard fun(cmdline = @["--help"], prefix = "    ", usage = use)
        except HelpOnly:
          discard
      echo ""
      echo "    " & passthrough.join(", ")
      let nimbleUse = "    $args\n$doc"
      # produce help for nimble subcommands
      discard runnimble(cmdline = @["--help"], prefix = "    ",
                         usage = nimbleUse)
  except HelpOnly:
    discard
  quit 0
