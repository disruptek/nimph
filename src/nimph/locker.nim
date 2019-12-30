import std/json
import std/hashes
import std/strformat
import std/strtabs
import std/tables
import std/uri

import gittyup

import nimph/spec
import nimph/version
import nimph/group
import nimph/config
import nimph/project
import nimph/dependency
import nimph/package
import nimph/asjson
import nimph/doctor
import nimph/requirement

type
  Locker* = ref object
    name*: string
    url*: Uri
    requirement*: Requirement
    dist*: DistMethod
    release*: Release
  LockerRoom* = ref object of Group[string, Locker]
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

proc hash*(room: LockerRoom): Hash =
  ## the hash of a lockerroom is the hash of its root and all lockers
  var h: Hash = 0
  for locker in room.values:
    h = h !& locker.hash
  h = h !& room.root.hash
  result = !$h

proc `==`(a, b: Locker): bool =
  result = a.hash == b.hash

proc `==`(a, b: LockerRoom): bool =
  result = a.hash == b.hash

proc newLockerRoom*(name = ""; flags = defaultFlags): LockerRoom =
  result = LockerRoom(name: name, flags: flags)
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

proc newLockerRoom*(project: Project; flags = defaultFlags): LockerRoom =
  ## a new lockerroom using the project release as the root
  let
    requirement = newRequirement(project.name, Equal, project.release)
  result = newLockerRoom(flags = flags)
  result.root = newLocker(requirement, rootName, project)

proc add*(room: var LockerRoom; req: Requirement; name: string;
          project: Project) =
  ## create a new locker for the requirement from the project and
  ## safely add it to the lockerroom
  var locker = newLocker(req, name, project)
  block found:
    for existing in room.values:
      if existing == locker:
        error &"unable to add equivalent lock for `{name}`"
        break found
    room.add name, locker

proc fillRoom(room: var LockerRoom; dependencies: DependencyGroup): bool =
  ## fill a lockerroom with lockers constructed from the dependency tree;
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
              room: LockerRoom; project: Project): bool =
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
  result.dist = js["dist"].toDistMethod

proc toJson*(room: LockerRoom): JsonNode =
  ## convert a LockerRoom to a JObject
  result = newJObject()
  for name, locker in room.pairs:
    result[locker.name] = locker.toJson
  result[room.root.name] = room.root.toJson

proc toLockerRoom*(js: JsonNode; name = ""): LockerRoom =
  ## convert a JObject to a LockerRoom
  result = newLockerRoom(name)
  for name, locker in js.pairs:
    if name == rootName:
      result.root = locker.toLocker
    elif result.hasKey(name):
      error &"ignoring duplicate locker `{name}`"
    else:
      result.add name, locker.toLocker

proc getLockerRoom*(project: Project; name: string; room: var LockerRoom): bool =
  ## true if we pulled the named lockerroom out of the project's configuration
  let
    js = project.config.getLockerRoom(name)
  if js != nil and js.kind == JObject:
    room = js.toLockerRoom(name)
    result = true

iterator allLockerRooms*(project: Project): LockerRoom =
  ## emit each lockerroom in the project's configuration
  for name, js in project.config.getAllLockerRooms.pairs:
    yield js.toLockerRoom(name)

proc unlock*(project: var Project; name: string; flags = defaultFlags): bool =
  ## unlock a project using the named lockfile
  var
    dependencies = project.newDependencyGroup(flags = {Flag.Quiet} + flags)
    room = newLockerRoom(name, flags)

  block unlocked:
    if not project.getLockerRoom(name, room):
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
    room = newLockerRoom(project, flags)

  block locked:
    if project.getLockerRoom(name, room):
      notice &"lock `{name}` already exists; choose a new name"
      break locked

    # if we cannot resolve our dependencies, we can't lock the project
    result = project.resolve(dependencies)
    if not result:
      notice &"unable to resolve all dependencies for {project}"
      break locked

    # if the lockerroom isn't confident, we can't lock the project
    result = room.fillRoom(dependencies)
    if not result:
      notice &"not confident enough to lock {project}"
      break locked

    # compare this lockerroom to pre-existing lockerrooms and don't dupe it
    for exists in project.allLockerRooms:
      if exists == room:
        notice &"already locked these dependencies as `{exists.name}`"
        result = false
        break locked

    # write the lockerroom to the project's configuration
    project.config.addLockerRoom name, room.toJson
