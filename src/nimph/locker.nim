import std/json
import std/hashes
import std/strformat
import std/strtabs
import std/tables
import std/uri

import nimph/spec
import nimph/version
import nimph/group
import nimph/config
import nimph/project
import nimph/dependency
import nimph/package
import nimph/asjson
import nimph/git
import nimph/doctor

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
  var h: Hash = 0
  for name, locker in room.pairs:
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
  result = req.newLocker
  result.url = project.url
  result.name = name
  result.dist = project.dist
  result.release = project.release

proc newLockerRoom*(project: Project; flags = defaultFlags): LockerRoom =
  let
    requirement = newRequirement(project.importName, Equal, project.release)
  result = newLockerRoom(flags = flags)
  result.root = newLocker(requirement, rootName, project)

proc add*(room: var LockerRoom; req: Requirement; name: string;
          project: Project) =
  var locker = newLocker(req, name, project)
  block found:
    for existing in room.values:
      if existing == locker:
        error &"unable to add equivalent lock for `{name}`"
        break found
    room.add name, locker

proc repoLockReady(project: Project): bool =
  ## true if a project's git repo is ready to be locked
  if project.dist != Git:
    return
  result = true
  let state = repositoryState(project.repo)
  if state != GitRepoState.rsNone:
    result = false
    warn &"{project} repository in invalid {state} state"
  for n in status(project.repo, ssIndexAndWorkdir):
    result = false
    warn &"{project} repository has been modified"
    break

proc populate(room: var LockerRoom; dependencies: DependencyGroup): bool =
  ## fill a lockerroom with lockers
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

proc populate(dependencies: var DependencyGroup;
              room: LockerRoom; project: Project): bool =
  result = true
  for name, locker in room.pairs:
    dependencies.add locker.requirement, newDependency(locker.requirement)
    result = result and project.resolve(dependencies, locker.requirement)

proc toJson*(locker: Locker): JsonNode =
  result = newJObject()
  result["name"] = newJString(locker.name)
  result["url"] = locker.url.toJson
  result["release"] = locker.release.toJson
  result["requirement"] = locker.requirement.toJson
  result["dist"] = locker.dist.toJson

proc toLocker*(js: JsonNode): Locker =
  let
    req = js["requirement"].toRequirement
  result = req.newLocker
  result.name = js["name"].getStr
  result.url = js["url"].toUri
  result.release = js["release"].toRelease
  result.dist = js["dist"].toDistMethod

proc toJson*(room: LockerRoom): JsonNode =
  result = newJObject()
  for name, locker in room.pairs:
    result[locker.name] = locker.toJson
  result[room.root.name] = room.root.toJson

proc toLockerRoom*(js: JsonNode; name = ""): LockerRoom =
  result = newLockerRoom(name)
  for name, locker in js.pairs:
    if name == rootName:
      result.root = locker.toLocker
    elif result.hasKey(name):
      error &"ignoring duplicate locker `{name}`"
    else:
      result.add name, locker.toLocker

proc getLockerRoom*(project: Project; name: string; room: var LockerRoom): bool =
  let
    js = project.config.getLockerRoom(name)
  if js == nil or js.kind != JObject:
    return
  room = js.toLockerRoom(name)
  result = true

iterator allLockerRooms*(project: Project): LockerRoom =
  for name, js in project.config.getAllLockerRooms.pairs:
    yield js.toLockerRoom(name)

proc unlock*(project: var Project; name: string; flags = defaultFlags): bool =
  var
    dependencies = project.newDependencyGroup(flags = {Flag.Quiet} + flags)
    room = newLockerRoom(name, flags)

  if not project.getLockerRoom(name, room):
    notice &"unable to find a lock named `{name}`"
    return

  for name, locker in room.pairs:
    if locker.dist != Git:
      warn &"unsafe lock of `{name}` for {locker.requirement} as {locker.release}"

  # perform doctor resolution of dependencies, etc.
  var
    state = DrState(kind: DrRetry)
  while state.kind == DrRetry:
    # resolve dependencies for the lock
    if not dependencies.populate(room, project):
      notice &"unable to resolve all dependencies for `{name}`"
      result = false
      state.kind = DrError
    # see if we can converge the environment to the lock
    elif not project.fixDependencies(dependencies, state):
      result = false
    # if the doctor doesn't want us to try again, we're done
    if state.kind notin {DrRetry}:
      break
    # empty the dependencies and rescan for projects
    dependencies.reset(project)

proc lock*(project: var Project; name: string; flags = defaultFlags): bool =
  var
    dependencies = project.newDependencyGroup(flags = {Flag.Quiet} + flags)
    room = newLockerRoom(project, flags)
  if project.getLockerRoom(name, room):
    notice &"lock `{name}` already exists; choose a new name"
    return
  result = project.resolve(dependencies)
  if not result:
    notice &"unable to resolve all dependencies for {project}"
    return
  result = room.populate(dependencies)
  if not result:
    notice &"not confident enough to lock {project}"
    return
  for exists in project.allLockerRooms:
    if exists == room:
      notice &"already locked these dependencies as `{exists.name}`"
      result = false
      return
  var
    js = room.toJson
  project.config.addLockerRoom name, js
