import std/options
import std/uri

import unittest2

import nimph/spec
import nimph/project
import nimph/version
import nimph/dependency
import nimph/config
import nimph/git


suite "git":
  setup:
    var
      project: Project
    check project.findProject(".")
    project.cfg = loadAllCfgs(project.repo)
    var
      deps {.used.} = project.newDependencyGroup({Dry})
    check project.resolve(deps)

    var
      path = deps.pathForName("cutelog")
    check path.isSome
    var
      cute = deps.projectForPath(path.get)

  test "roll a dep":
    let
      future = newRelease("1.0.2", operator = Tag)
      req = newRequirement("cutelog", operator = Tag, future)
    check cute.rollTowards(req)
    for stat in cute.repo.status:
      checkpoint $stat
      check gsfIndexModified notin stat.flags
