import std/strutils
import std/options
import std/os
import std/strformat

import bump

import nimph/spec
import nimph/project
import nimph/nimble
import nimph/config
import nimph/thehub
import nimph/package
import nimph/git as git

proc doctor*(project: var Project; dry = true): bool =
  ## perform some sanity tests against the project and
  ## try to fix any issues we find unless `dry` is true

  block whoami:
    # check our project version
    let
      version = project.knowVersion
    # contextual errors are output by knowVersion
    result = version.isValid
    if result:
      debug &"{project.name} version {version}"

  block dependencies:
    # check our deps dir
    let
      depsDir = project.nimbleDir
      #absolutePath(project.nimble.repo / DepDir).normalizedPath
      envDir = getEnv("NIMBLE_DIR", "")
    if not dirExists(depsDir):
      if dry:
        info &"you don't have a local dependencies directory: {depsDir}"
      else:
        createDir(depsDir)
        info &"created directory for local dependencies: {depsDir}"

    # $NIMBLE_DIR could screw with our head
    if envDir != "":
      if absolutePath(envDir).normalizedPath != depsDir:
        notice "i'm not sure what to do with an alternate $NIMBLE_DIR set"
        result = false
      else:
        info "your $NIMBLE_DIR is set, but it's set correctly"


  block checknimble:
    # make sure nimble is a thing
    if findExe("nimble") == "":
      error "i can't find nimble in the path"
      result = false

    # make sure we can dump our project
    let
      damp = fetchNimbleDump(project.nimble.repo)
    if not damp.ok:
      error damp.why
      result = false
    else:
      project.dump = damp.table

  block configuration:
    let
      nimcfg = project.nimCfg
    # try a compiler parse of nim.cfg
    if not fileExists($nimcfg):
      warn &"there wasn't a {NimCfg} in {project.nimble.repo}"
      if not dry:
        if nimcfg.appendConfig("--clearNimblePath"):
          info "i created a new one"
        else:
          error "and i wasn't able to make a new one"
    else:
      let
        parsed = loadProjectCfg($nimcfg)
      if parsed.isNone:
        error &"i had some issues trying to parse {nimcfg}"
        result = false
      else:
        debug &"the compiler parsed {nimcfg} without incident"

    # try a naive parse of nim.cfg
    if fileExists($project.nimCfg):
      let
        nimcfg = project.nimCfg
        parsed = parseProjectCfg(project.nimCfg)
      if not parsed.ok:
        error &"i had some issues trying to parse {nimcfg}:"
        error parsed.why
        result = false
      else:
        debug &"a naive parse of {nimcfg} was fine"

    # try to parse all nim configuration files
    try:
      let
        global = loadAllCfgs()
      debug "parsing global nim configuration worked fine"
    except Exception as e:
      error "unable to parse nim configuration: " & e.msg

  # see if we can find a github token
  block github:
    let
      token = findGithubToken()
    if token.isNone:
      notice &"i wasn't able to discover a github token"
      warn &"please add a GitHub OAUTH token to your $NIMPH_TOKEN"
      result = false

  # see if git works
  block nimgit:
    if not git.init():
      error "i'm not able to initialize nimgit2 for git operations"
      result = false
    elif not git.shutdown():
      error "i'm not able to shutdown nimgit2 after initialization"
      result = false
    else:
      debug "git init/shut seems to be working"

  # see if we can get the packages list; try to refresh it if necessary
  block packages:
    while true:
      let
        packs = getOfficialPackages(project.nimbleDir)
      once:
        block skiprefresh:
          if not packs.ok:
            if packs.why != "":
              error packs.why
            notice &"couldn't get nimble's package list from {project.nimbleDir}"
          elif packs.packages.ageInDays > stalePackages:
            notice &"the nimble package list in {project.nimbleDir} is stale"
          elif packs.packages.ageInDays > 0:
            info "the nimble package list is " &
                   &"{packs.packages.ageInDays} days old"
            break skiprefresh
          else:
            break skiprefresh
          if not dry:
            let refresh = project.runNimble(@["refresh", "--accept"])
            if refresh.ok:
              info "nimble refreshed the package list"
              continue
          result = false
      if packs.ok:
        let packages {.used.} = packs.packages
        debug &"loaded {packages.len} packages from nimble"
      break

  # check dependencies and maybe install some
  block dependencies:
    var
      tryAgain = false
    for iteration in 0 .. 1:
      var
        group = newPackageGroup()
      if project.resolveDependencies(group):
        debug &"all dependencies resolved for {project}"
      else:
        notice &"unable to resolve all dependencies for {project}"
      for name, package in group.pairs:
        # a hackish solution for now: the keys are set to the repo path...
        if name.startsWith("/"):
          continue
        if dry:
          notice &"{name} missing"
          result = false
        elif iteration == 0:
          if project.clone(package.url, package.name):
            tryAgain = true
          else:
            error &"error cloning {package}"
            result = false
        else:
          error &"missing {name} package"
          result = false
      if not tryAgain:
        break
