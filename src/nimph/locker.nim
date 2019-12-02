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

type
  Locker* = ref object
    name*: string
    url*: Uri
    requirement*: Requirement
    dist*: DistMethod
    release*: Release
  LockerRoom* = NimphGroup[string, Locker]

proc hash*(locker: Locker): Hash =
  # this is how we'll test equivalence
  var h: Hash = 0
  h = h !& locker.name.hash
  h = h !& locker.release.hash
  result = !$h

proc `==`(a, b: Locker): bool =
  result = a.hash == b.hash

proc newLockerRoom*(): LockerRoom =
  result = LockerRoom()
  result.init(mode = modeStyleInsensitive)

proc newLocker(requirement: Requirement): Locker =
  result = Locker(requirement: requirement)

proc newLocker(req: Requirement; name: string; project: Project): Locker =
  result = req.newLocker
  result.url = project.url
  result.name = name
  result.dist = project.dist
  result.release = project.release

proc add*(room: var LockerRoom; req: Requirement; name: string;
          project: Project) =
  var locker = newLocker(req, name, project)
  block found:
    for existing in room.values:
      if existing == locker:
        error &"unable to add equivalent lock for {name}"
        break found
    room.add name, locker

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
          if room.hasKey(name):
            warn &"clashing import {name}"
            result = false
            continue
          room.add requirement, name, project
        continue
      warn &"shadowed project {project}"
      result = false

proc toJson*(locker: Locker): JsonNode =
  result = newJObject()
  result["name"] = newJString(locker.name)
  result["url"] = locker.url.toJson
  result["release"] = locker.release.toJson
  result["requirement"] = locker.requirement.toJson
  result["dist"] = locker.dist.toJson

proc toJson*(room: LockerRoom): JsonNode =
  result = newJObject()
  for name, locker in room.pairs:
    result[locker.name] = locker.toJson

proc lock*(project: var Project; name: string): bool =
  var
    dependencies = newDependencyGroup(flags = {Flag.Quiet})
    room = newLockerRoom()
  result = project.resolveDependencies(dependencies)
  if not result:
    notice &"unable to resolve all dependencies for {project}"
    return
  result = room.populate(dependencies)
  if not result:
    notice &"not confident enough to lock {project}"
    return
  project.config.addLockerRoom name, room.toJson
