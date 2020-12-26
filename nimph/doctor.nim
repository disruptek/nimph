import std/strtabs
import std/tables
import std/strutils
import std/options
import std/os
import std/strformat

import bump
import gittyup

import nimph/spec
import nimph/project
import nimph/nimble
import nimph/config
import nimph/thehub
import nimph/package
import nimph/dependency
import nimph/group

import nimph/requirement

type
  StateKind* = enum
    DrOkay = "okay"
    DrRetry = "retry"
    DrError = "error"

  DrState* = object
    kind*: StateKind
    why*: string

proc fixTags*(project: var Project; dry_run = true; force = false): bool =
  block:
    if project.dist != Git or not project.repoLockReady:
      info "not looking for missing tags because the repository is unready"
      break

    # you gotta spend money to make money
    project.fetchTagTable
    if project.tags == nil:
      notice "not looking for missing tags because i couldn't fetch any"
      break

    # we're gonna fetch the dump to make sure our version is sane
    if not project.fetchDump:
      notice "not looking for missing tags because my dump failed"
      break
    if "version" notin project.dump or project.dump["version"].count(".") > 2:
      notice &"refusing to tag {project.name} because its version is bizarre"
      break

    # open the repo so we can keep it in memory for tagging purposes
    repository := openRepository(project.gitDir):
      error &"unable to open repo at `{project.repo}`: {code.dumpError}"
      break

    # match up tags to versions to commits; we should probably
    # copy these structures and remove matches, for efficiency...
    var tagsNeeded = 0
    for version, commit in project.versionChangingCommits.pairs:
      block found:
        if $version in project.tags:
          let exists = project.tags[$version]
          debug &"found tag `{exists}` for {version}"
          break found
        for text, tag in project.tags.pairs:
          if commit.oid == tag.oid:
            debug &"found tag `{text}` for {version}"
            break found
        if dry_run:
          notice &"{project.name} is missing a tag for version {version}"
          info &"version {version} arrived in {commit}"
          result = true
          tagsNeeded.inc
        else:
          thing := repository.lookupThing($commit.oid):
            notice &"unable to lookup {commit}"
            continue
          # try to create a tag for this version and commit
          var
            nextTag = project.tags.nextTagFor(version)
            tagged = thing.tagCreate(nextTag, force = force)
          # first, try using the committer's signature
          if tagged.isErr:
            notice &"unable to create signed tag for {version}"
            # fallback to a lightweight (unsigned) tag
            tagged = thing.tagCreateLightweight(nextTag, force = force)
            if tagged.isErr:
              notice &"unable to create new tag for {version}"
              break found
          let
            oid = tagged.get
          # if that worked, let them know we did something
          info &"created new tag {version} as tag-{oid}"
          # the oid created for the tag must be freed
          dealloc oid

    # save our advice 'til the end
    if tagsNeeded > 0:
      notice "use the `tag` subcommand to add missing tags"

proc fixDependencies*(project: var Project; group: var DependencyGroup;
                      state: var DrState): bool =
  ## try to fix any outstanding issues with a set of dependencies

  # by default, everything is fine
  result = true
  # but don't come back here
  state.kind = DrError
  for requirement, dependency in group.mpairs:
    # if the dependency is being met,
    if dependency.isHappy:
      # but the version is not suitable,
      if not dependency.isHappyWithVersion:
        # try to roll any supporting project to a version that'll work
        for child in dependency.projects.mvalues:
          # if we're allowed to, i mean
          if Dry notin group.flags:
            # and if it was successful,
            if child.rollTowards(requirement):
              # report success
              notice &"rolled to {child.release} to meet {requirement}"
              break
          # else report the problem and set failure
          for req in requirement.orphans:
            if not req.isSatisfiedBy(child, child.release):
              notice &"{req.describe} unmet by {child}"
              result = false

      # the dependency is fine, but maybe we don't have it in our paths?
      for child in dependency.projects.mvalues:
        for path in project.missingSearchPaths(child):
          # report or update the paths
          if Dry in group.flags:
            notice &"missing path `{path}` in `{project.nimcfg}`"
            result = false
          elif project.addSearchPath(path):
            info &"added path `{path}` to `{project.nimcfg}`"
            # yay, we get to reload again
            project.cfg = loadAllCfgs(project.repo)
          else:
            warn &"couldn't add path `{path}` to `{project.nimcfg}`"
            result = false
      # dependency is happy and (probably) in a search path now
      continue

    # so i just came back from lunch and i was in the drive-thru and
    # reading reddit and managed to bump into the truck in front of me. 🙄
    #
    # this tiny guy pops out the door of the truck and practically tumbles
    # down the running board before arriving at the door to my car.  he's
    # so short that all i can see is his little balled-up fist raised over
    # his head.
    #
    # i roll the window down, and he immediately yells, "I'M NOT HAPPY!"
    # to which my only possible reply was, "Well, which one ARE you, then?"
    #
    # anyway, if we made it this far, we're not happy...
    if Dry in group.flags:
      notice &"{dependency.name} ({requirement}) missing"
      result = false
    # for now, we'll force trying again even though it's a security risk,
    # because it will make users happy sooner, and we love happy users
    else:
      block cloneokay:
        for package in dependency.packages.mvalues:
          var cloned: Project
          if project.clone(package.url, package.name, cloned):
            if cloned.rollTowards(requirement):
              notice &"rolled to {cloned.release} to meet {requirement}"
            else:
              # we didn't roll, so we may need to relocate
              project.relocateDependency(cloned)
            state.kind = DrRetry
            break cloneokay
          else:
            error &"error cloning {package}"
            # a subsequent iteration could clone successfully
        # no package was successfully cloned
        notice &"unable to satisfy {requirement.describe}"
        result = false

    # okay, we did some stuff...  let's see where we are now
    if state.kind == DrRetry:
      discard
    elif result:
      state.kind = DrOkay
    else:
      state.kind = DrError

proc doctor*(project: var Project; dry = true; strict = true): bool =
  ## perform some sanity tests against the project and
  ## try to fix any issues we find unless `dry` is true
  var
    flags: set[Flag] = {}

  template toggle(x: typed; flag: Flag; test: bool) =
    if test: x.incl flag else: x.excl flag

  flags.toggle Dry, dry
  flags.toggle Strict, strict

  block configuration:
    debug "checking compiler configuration"
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
        parsed = parseConfigFile($nimcfg)
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
    when defined(debugPath):
      for path in project.cfg.likelySearch(libsToo = true):
        debug &"\tsearch: {path}"
      for path in project.cfg.likelyLazy:
        debug &"\t  lazy: {path}"

  when AndNimble:
    block whoami:
      debug "checking project version"
      # check our project version
      let
        version = project.knowVersion
      # contextual errors are output by knowVersion
      result = version.isValid
      if result:
        debug &"{project.name} version {version}"

  block dependencies:
    debug "checking dependencies"
    # check our deps dir
    let
      depsDir = project.nimbleDir
      #absolutePath(project.nimble.repo / DepDir).normalizedPath
      envDir = getEnv("NIMBLE_DIR", "")
    if not dirExists(depsDir):
      info &"if you create {depsDir}, i'll use it for local dependencies"

    # $NIMBLE_DIR could screw with our head
    if envDir != "":
      if absolutePath(envDir) != depsDir:
        notice "i'm not sure what to do with an alternate $NIMBLE_DIR set"
        result = false
      else:
        info "your $NIMBLE_DIR is set, but it's set correctly"

  when AndNimble:
    block checknimble:
      debug "checking nimble"
      # make sure nimble is a thing
      if findExe("nimble") == "":
        error "i can't find nimble in the path"
        result = false

      debug "checking nimble dump of our project"
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
    debug "checking for github token"
    let
      token = findGithubToken()
    if token.isNone:
      notice &"i wasn't able to discover a github token"
      warn &"please add a GitHub OAUTH token to your $NIMPH_TOKEN"
      result = false

  # see if git works
  block nimgit:
    if not gittyup.init():
      error "i'm not able to initialize nimgit2 for git operations"
      result = false
    elif not gittyup.shutdown():
      error "i'm not able to shutdown nimgit2 after initialization"
      result = false
    else:
      debug "git init/shut seems to be working"

  when AndNimble:
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
            elif packs.ageInDays > stalePackages:
              notice &"the nimble package list in {project.nimbleDir} is stale"
            elif packs.ageInDays > 1:
              info "the nimble package list is " &
                   &"{packs.ageInDays} days old"
              break skiprefresh
            else:
              break skiprefresh
            if not dry:
              let refresh = project.runSomething("nimble", @["refresh", "--accept"])
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
      group = project.newDependencyGroup(flags)
      state = DrState(kind: DrRetry)

      # we'll cache the old result so we can reset it if we are able to
      # fix all the dependencies
      prior = result

    while state.kind == DrRetry:
      # we need to reload the config each repeat through this loop so that we
      # can correctly identify new search paths after adding new packages
      if not project.resolve(group):
        notice &"unable to resolve all dependencies for {project}"
        result = false
        state.kind = DrError
      elif not project.fixDependencies(group, state):
        result = false
      else:
        # reset the state in the event that dependencies are fixed
        result = prior
      # maybe we're done here
      if state.kind notin {DrRetry}:
        break
      # we need to try again, but first we'll reset the environment
      fatal "👍environment changed; re-examining dependencies..."
      group.reset(project)

    # if dependencies are available via --nimblePath, then warn of any
    # dependencies that aren't recorded as part of the dependency graph;
    # this might be usefully toggled in spec.  this should only issue a
    # warning if local deps exist or multiple nimblePaths are found
    block extradeps:
      if project.hasLocalDeps or project.numberOfNimblePaths > 1:
        let imports = project.cfg.allImportTargets(project.repo)
        for target, linked in imports.pairs:
          if group.isUsing(target):
            continue
          # ignore standard library targets
          if project.cfg.isStdLib(target.repo):
            continue
          let name = linked.importName
          warn &"no `{name}` requirement for {target.repo}"

  when AndNimble:
    # identify packages that aren't named according to their versions;
    # rename local dependencies and merely warn about others
    {.warning: "mislabeled project directories unimplemented".}

  # remove missing paths from nim.cfg if possible
  block missingpaths:
    when defined(debugPath):
      for path in project.cfg.searchPaths.items:
        debug &"\tsearch: {path}"
      for path in project.cfg.lazyPaths.items:
        debug &"\t  lazy: {path}"
    # search paths that are missing should be removed/excluded
    for path in likelySearch(project.cfg, libsToo = false):
      if dirExists(path):
        continue
      if dry:
        warn &"search path {path} does not exist"
        result = false
      elif project.removeSearchPath(path):
        info &"removed missing search path {path}"
      elif excludeMissingSearchPaths and project.excludeSearchPath(path):
        info &"excluded missing search path {path}"
      else:
        warn &"unable to remove search path {path}"
        result = false

    # lazy paths that are missing can be explicitly removed/ignored
    for path in likelyLazy(project.cfg, least = 0):
      if dirExists(path):
        continue
      if dry:
        warn &"nimblePath {path} does not exist"
        result = false
      elif project.removeSearchPath(path):
        info &"removed missing nimblePath {path}"
      elif excludeMissingLazyPaths and project.excludeSearchPath(path):
        info &"excluded missing nimblePath {path}"
      else:
        warn &"unable to remove nimblePath {path}"
        result = false

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

  when AndNimble:
    # if a package exists and is local to the project and picked up by the
    # config (search paths or lazy paths) and it isn't listed in the
    # requirements, then we should warn about it
    block unspecifiedrequirement:
      {.warning: "unspecified requirements needs implementing".}

    # if a required package has a srcDir defined in the .nimble, then it
    # needs to be specified in the search paths
    block unspecifiedsearchpath:
      {.warning: "unspecified search path needs implementing".}

  # warn of tags missing for a particular version/commit pair
  block identifymissingtags:
    if project.fixTags(dry_run = true):
      result = false

  # warn if the user appears to have multiple --nimblePaths in use
  block nimblepaths:
    let
      found = project.countNimblePaths
    # don't distinguish between local or user lazy paths (yet)
    if found.local + found.global > 1:
      fatal "❔it looks like you have multiple --nimblePaths defined:"
      for index, path in found.paths.pairs:
        fatal &"❔\t{index + 1}\t{path}"
      fatal "❔nim and nimph support this, but humans can find it confusing 😏"
