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
      # at the moment, we support any combination of local/user/global deps
      if false:
        # strictly speaking, this isn't a problem
        warn &"there wasn't a {NimCfg} in {project.nimble.repo}"
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

    # try a naive parse of nim.cfg
    if fileExists($project.nimCfg):
      let
        nimcfg = project.nimCfg
        parsed = parseProjectCfg(project.nimCfg)
      if not parsed.ok:
        error &"i had some issues trying to parse {nimcfg}:"
        error parsed.why
        result = false

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
        fatal ""
        fatal "👍environment changed; re-examining dependencies..."
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

  # remove missing paths from nim.cfg if possible
  block missingpaths:
    # search paths that are missing should be removed/excluded
    for path in likelySearch(project.cfg, project.repo):
      if dirExists(path):
        continue
      if dry:
        warn &"search path {path} does not exist"
      elif project.removeSearchPath(path):
        info &"removed missing search path {path}"
      elif excludeMissingPaths and project.excludeSearchPath(path):
        info &"excluded missing search path {path}"
      else:
        warn &"unable to remove search path {path}"

    # lazy paths that are missing can be explicitly removed/ignored
    for path in likelyLazy(project.cfg, project.repo, least = 0):
      if dirExists(path):
        continue
      if dry:
        warn &"nimblePath {path} does not exist"
      elif project.removeSearchPath(path):
        info &"removed missing nimblePath {path}"
      elif excludeMissingPaths and project.excludeSearchPath(path):
        info &"excluded missing nimblePath {path}"
      else:
        warn &"unable to remove nimblePath {path}"

  # if dependencies are available via --nimblePath, then warn of any
  # dependencies that aren't recorded as part of the dependency graph;
  # this might be usefully toggled in spec.  this should only issue a
  # warning if local deps exist or multiple nimblePaths are found
  block extradeps:
    {.warning: "extra deps needs implementing".}

  # if a dependency (local or otherwise) is shadowed by another dependency
  # in one of the nimblePaths, then we should warn that a removal of one
  # dep will default to the other
  #
  # if a dependency is shadowed with a manual path specification, we should
  # call that a proper error and offer to remove the weakest member
  #
  # we should calculate shadowing by name and version according to the way
  # the compiler compares versions
  block shadoweddeps:
    {.warning: "shadowed deps needs implementing".}

  # if a package exists and is local to the project and picked up by the
  # config (search paths or lazy paths) and it isn't listed in the
  # requirements, then we should warn about it
  block unspecifiedrequirement:
    {.warning: "unspecified requirements needs implementing".}

  # warn if the user appears to have multiple --nimblePaths in use
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
