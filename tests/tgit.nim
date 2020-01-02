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

  test "roll between versions":
    project.returnToHeadAfter:
      for ver in ["0.5.7", "0.5.6"]:
        let
          release = newRelease(ver, operator = Tag)
          req = newRequirement($project.url, operator = Tag, release)
        if project.rollTowards(req):
          for stat in project.repo.status:
            check stat.isOk
            check gsfIndexModified notin stat.get.flags

  test "commits changing project version":
    let
      versioned = project.versionChangingCommits
      required = project.requirementChangingCommits
    check $versioned[v"0.5.6"].oid == "76e5cc0121cc2f963336abb3f3fc97b01fdc5ed4"
    check $versioned[v"0.5.7"].oid == "60ab6a2776df4dc0a8814d6741a5e560959a8a5f"
