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

proc nimph*(args: seq[string]; dry_run = false; log_level = logLevel): int =
  ## cli entry
  var
    project: Project
    sub = ""

  # get subcommand and set log filter
  if args.len >= 1:
    sub = args[0]
    # user's choice, our default
    setLogFilter(log_level)
  else:
    # if the user hasn't specified a log level, kick it up a notch
    if log_level == logLevel:
      setLogFilter(max(0, log_level.ord - 1).Level)

  if not findProject(project):
    crash &"unable to find a project; try `nimble init`?"

  try:
    project.cfg = loadAllCfgs()
  except Exception as e:
    crash "unable to parse nim configuration: " & e.msg

  case sub:
  of "search":
    if args.len == 1:
      crash &"a search was requested but no query parameters were provided"
    else:
      let
        group = waitfor searchHub(args[1..args.high])
      if group.isNone:
        crash &"unable to retrieve search results from github"
      for repo in group.get.reversed:
        fatal "\n" & repo.renderShortly
  of "clone":
      let
        query {.used.} = args[1..args.high].join(" ")
        group = waitfor searchHub(args[1..args.high])
      if group.isNone:
        crash &"unable to retrieve search results from github"
      var
        repository: HubRepo
      block found:
        for repo in group.get.values:
          repository = repo
          break found
        crash &"unable to find a package matching `{query}`"
      if not project.clone(repository.git, repository.name):
        crash &"unable to clone {repository.git}"
      fatal &"👌cloned {repository.git}"
  of "install", "uninstall", "test", "path", "build", "tasks", "dump", "list",
     "refresh", "c", "cc", "cpp", "js":
    let
      nimble = project.runNimble(args)
    if not nimble.ok:
      crash &"nimble didn't like that"
  of "":
    prepareForTheWorst:
      if project.doctor(dry = true):
        fatal &"👌{project.nimble.package} version {project.version} lookin' good"
      else:
        warn "run `nimph doctor` to fix this stuff"
  of "doctor", "fix":
    prepareForTheWorst:
      if project.doctor(dry = dry_run):
        fatal &"👌{project.nimble.package} version {project.version} lookin' good"
      elif not dry_run:
        crash &"the doctor wasn't able to fix everything"

when isMainModule:
  import cligen
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

  dispatch nimph
