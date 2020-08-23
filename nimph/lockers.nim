import std/json
import std/hashes
import std/strformat
import std/strtabs
import std/tables
import std/uri

import nimph/spec
import nimph/versions
import nimph/groups
import nimph/config
import nimph/projects
import nimph/dependencies
import nimph/packages
import nimph/asjson
import nimph/doctor
import nimph/requirements

type
  Locker* = ref object
    name*: string
    url*: Uri
    requirement*: Requirement
    dist*: Dist
    release*: Release
  Lockers* = ref object of Group[string, Locker]
    name*: string
    root*: Locker

const
  # we use "" as a sigil to indicate the root of the project because
  # it's not a valid import name and won't be accepted by Group
  rootName = ""

proc hash*(locker: Locker): Hash =
  # this is how we'll test equivalence
  var h: Hash = 0
  h = h !& locker.name.hash
  h = h !& locker.release.hash
  result = !$h

proc hash*(group: Lockers): Hash =
  ## the hash of a lockers is the hash of its root and all lockers
  var h: Hash = 0
  for locker in group.values:
    h = h !& locker.hash
  h = h !& group.root.hash
  result = !$h

proc `==`(a, b: Locker): bool =
  result = a.hash == b.hash

proc `==`(a, b: Lockers): bool =
  result = a.hash == b.hash

proc newLockers*(name = ""; flags = defaultFlags): Lockers =
  result = Lockers(name: name, flags: flags)
  result.init(flags, mode = modeStyleInsensitive)

proc newLocker(requirement: Requirement): Locker =
  result = Locker(requirement: requirement)

proc newLocker(req: Requirement; name: string; project: Project): Locker =
  ## we use the req's identity and the project's release; this might need
  ## to change to simply use the project name, depending on an option...
  result = newRequirement(req.identity, Equal, project.release).newLocker
  result.url = project.url
  result.name = name
  result.dist = project.dist
  result.release = project.release

proc newLockers*(project: Project; flags = defaultFlags): Lockers =
  ## a new lockers using the project release as the root
  let
    requirement = newRequirement(project.name, Equal, project.release)
  result = newLockers(flags = flags)
  result.root = newLocker(requirement, rootName, project)

proc add*(room: var Lockers; req: Requirement; name: string;
          project: Project) =
  ## create a new locker for the requirement from the project and
  ## safely add it to the lockers
  var locker = newLocker(req, name, project)
  block found:
    for existing in room.values:
      if existing == locker:
        error &"unable to add equivalent lock for `{name}`"
        break found
    room.add name.string, locker

proc fillLockers(room: var Lockers; dependencies: DependencyGroup): bool =
  ## fill a lockers with lockers constructed from the dependency tree;
  ## returns true if there were no missing/unready/shadowed dependencies
  result = true
  for requirement, dependency in dependencies.pairs:
    var shadowed = false
    if dependency.projects.len == 0:
      warn &"missing requirement {requirement}"
      result = false
      continue
    for project in dependency.projects.values:
      if not shadowed:
        shadowed = true
        if dependency.names.len > 1:
          warn &"multiple import names for {requirement}"
        for name in dependency.names.items:
          if project.dist != Git:
            warn &"{project} isn't in git; it's {project.dist} {project.repo}"
          elif not project.repoLockReady:
            result = false
          if room.hasKey(name):
            warn &"clashing import {name}"
            result = false
            continue
          room.add requirement, name, project
        continue
      warn &"shadowed project {project}"
      result = false

proc fillDeps(dependencies: var DependencyGroup;
              room: Lockers; project: Project): bool =
  ## fill a dependency tree with lockers and run dependency resolution
  ## using the project; returns true if there were no resolution failures
  result = true
  for locker in room.values:
    var
      req = newRequirement(locker.requirement.identity, Equal, locker.release)
      dependency = req.newDependency
    discard dependencies.addedRequirements(dependency)
    result = result and project.resolve(dependencies, req)

proc toJson*(locker: Locker): JsonNode =
  ## convert a Locker to a JObject
  result = newJObject()
  result["name"] = newJString(locker.name)
  result["url"] = locker.url.toJson
  result["release"] = locker.release.toJson
  result["requirement"] = locker.requirement.toJson
  result["dist"] = locker.dist.toJson

proc toLocker*(js: JsonNode): Locker =
  ## convert a JObject to a Locker
  let
    req = js["requirement"].toRequirement
  result = req.newLocker
  result.name = js["name"].getStr
  result.url = js["url"].toUri
  result.release = js["release"].toRelease
  result.dist = js["dist"].toDist

proc toJson*(room: Lockers): JsonNode =
  ## convert a Lockers to a JObject
  result = newJObject()
  for name, locker in room.pairs:
    result[locker.name] = locker.toJson
  result[room.root.name] = room.root.toJson

proc toLockers*(js: JsonNode; name = ""): Lockers =
  ## convert a JObject to a Lockers
  result = newLockers(name)
  for name, locker in js.pairs:
    if name == rootName:
      result.root = locker.toLocker
    elif result.hasKey(name):
      error &"ignoring duplicate locker `{name}`"
    else:
      result.add name, locker.toLocker

proc getLockers*(project: Project; name: string; room: var Lockers): bool =
  ## true if we pulled the named lockers out of the project's configuration
  let
    js = project.config.getLockers(name)
  if js != nil and js.kind == JObject:
    room = js.toLockers(name)
    result = true

iterator allLockers*(project: Project): Lockers =
  ## emit each lockers in the project's configuration
  for name, js in project.config.getAllLockers.pairs:
    yield js.toLockers(name)

proc unlock*(project: var Project; name: string; flags = defaultFlags): bool =
  ## unlock a project using the named lockfile
  var
    dependencies = project.newDependencyGroup(flags = {Flag.Quiet} + flags)
    room = newLockers(name, flags)

  block unlocked:
    if not project.getLockers(name, room):
      notice &"unable to find a lock named `{name}`"
      break unlocked

    # warn about any locks performed against non-Git distributions
    for name, locker in room.pairs:
      if locker.dist != Git:
        let emsg = &"unsafe lock of `{name}` for " &
                   &"{locker.requirement} as {locker.release}" # noqa
        warn emsg

    # perform doctor resolution of dependencies, etc.
    var
      state = DrState(kind: DrRetry)
    while state.kind == DrRetry:
      # it's our game to lose
      result = true
      # resolve dependencies for the lock
      if not dependencies.fillDeps(room, project):
        notice &"unable to resolve all dependencies for `{name}`"
        result = false
        state.kind = DrError
      # see if we can converge the environment to the lock
      elif not project.fixDependencies(dependencies, state):
        notice "failed to fix all dependencies"
        result = false
      # if the doctor doesn't want us to try again, we're done
      if state.kind notin {DrRetry}:
        break
      # empty the dependencies and rescan for projects
      dependencies.reset(project)

proc lock*(project: var Project; name: string; flags = defaultFlags): bool =
  ## store a project's dependencies into the named lockfile
  var
    dependencies = project.newDependencyGroup(flags = {Flag.Quiet} + flags)
    room = newLockers(project, flags)

  block locked:
    if project.getLockers(name, room):
      notice &"lock `{name}` already exists; choose a new name"
      break locked

    # if we cannot resolve our dependencies, we can't lock the project
    result = project.resolve(dependencies)
    if not result:
      notice &"unable to resolve all dependencies for {project}"
      break locked

    # if the lockers isn't confident, we can't lock the project
    result = room.fillLockers(dependencies)
    if not result:
      notice &"not confident enough to lock {project}"
      break locked

    # compare this lockers to pre-existing lockers and don't dupe it
    for exists in project.allLockers:
      if exists == room:
        notice &"already locked these dependencies as `{exists.name}`"
        result = false
        break locked

    # write the lockers to the project's configuration
    project.config.addLockers name, room.toJson
