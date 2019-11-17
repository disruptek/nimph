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
import nimph/dependency
import nimph/git as git

proc doctor*(project: var Project; dry = true): bool =
  ## perform some sanity tests against the project and
  ## try to fix any issues we find unless `dry` is true

  block configuration:
    let
      nimcfg = project.nimCfg
    # try a compiler parse of nim.cfg
    if not fileExists($nimcfg):
      warn &"there wasn't a {NimCfg} in {project.nimble.repo}"
      # at the moment, we support any combination of local/user/global deps
      if false:
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
    block globalconfig:
      when defined(debug):
        for path in project.cfg.likelySearch(project.repo):
          debug &"\tsearch: {path}"
        for path in project.cfg.likelyLazy(project.repo):
          debug &"\t  lazy: {path}"
      else:
        ## this space intentionally left blank

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
          elif packs.packages.ageInDays > 1:
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
      # we need to reload the config each repeat through this loop so that we
      # can correctly identify new search paths after adding new packages
      if iteration > 0:
        project.cfg = loadAllCfgs()

      var
        group = newPackageGroup()
      if not project.resolveDependencies(group):
        notice &"unable to resolve all dependencies for {project}"
      for name, package in group.pairs:
        if package.local:
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

  # warn if the user appears to have multiple --nimblePaths
  block nimblepaths:
    var
      inRepo, outRepo: int
      found: seq[string]
    for path in likelyLazy(project.cfg, project.repo, least = 2):
      found.add path
      if path.startsWith(project.repo):
        inRepo.inc
      else:
        outRepo.inc
    if inRepo + outRepo > 1:
      fatal "❔it looks like you have multiple --nimblePaths defined:"
      for count, path in found.pairs:
        fatal &"❔\t{count + 1}\t{path}"
      fatal "❔nim and nimph support this, but humans may find it confusing 😏"
