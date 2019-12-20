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
import nimph/versiontags


proc v(loose: string): Version =
  let
    release = parseVersionLoosely(loose)
  result = release.get.version

suite "tags":
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

    project.fetchTagTable

  test "test basic tag table stuff":
    check project.tags != nil
    check project.tags.len > 0

  test "make sure richen finds a tag":
    block found:
      for release, thing in project.tags.richen:
        checkpoint $release
        checkpoint $thing
        if release == newRelease("0.4.0", operator = Tag):
          break found
      check false
