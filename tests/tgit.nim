import std/tables
import std/options

import unittest2
import bump
import gittyup

import nimph/spec
import nimph/project
import nimph/version
import nimph/dependency
import nimph/config
import nimph/requirement
import nimph/versiontags


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
      cute = deps.projectForPath(path.get).get

    var
      repository = openRepository(project.repo)

  teardown:
    free repository.get

  test "roll between versions":
    project.returnToHeadAfter:
      for ver in ["0.6.6", "0.6.5"]:
        let
          release = newRelease(ver, operator = Tag)
          req = newRequirement($project.url, operator = Tag, release)
        if project.rollTowards(req):
          for stat in repository.status(ssIndexAndWorkdir):
            check stat.isOk
            check gsfIndexModified notin stat.get.flags

  test "commits changing project version":
    let
      versioned = project.versionChangingCommits
      required = project.requirementChangingCommits
    check $versioned[v"0.6.5"].oid == "8937c0b998376944fd93d6d8e7b3cf4db91dfb9b"
    check $versioned[v"0.6.6"].oid == "5a3de5a5fc9b83d5a9bba23f7e950b37a96d10e6"
