import std/options

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
    for ver in ["1.0.2", "1.1.1"]:
      let
        release = newRelease(ver, operator = Tag)
        req = newRequirement("cutelog", operator = Tag, release)
      check cute.rollTowards(req)
      for stat in cute.repo.status:
        check gsfIndexModified notin stat.flags
