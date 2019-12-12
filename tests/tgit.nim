import std/tables
import std/options

import unittest2
import bump

import nimph/spec
import nimph/project
import nimph/version
import nimph/dependency
import nimph/config
import nimph/git


proc v(loose: string): Version =
  let
    release = parseVersionLoosely(loose)
  result = release.get.version

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

  test "commits changing project version":
    let
      versioned = project.versionChangingCommits
      required = project.requirementChangingCommits
    check versioned[v"0.0.38"].oid == "29b4a67fe348030f118ff4a7d9b9f92c9cdd3a4e"
    check versioned[v"0.0.37"].oid == "aa681bd65e6472c7c65135b535a7cfdbaad314e3"
