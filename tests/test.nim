import std/strtabs
import std/os
import std/strutils
import std/options
import std/tables
import std/uri

import bump
import gittyup
import balls

import nimph/spec
import nimph/config
import nimph/project
import nimph/nimble
import nimph/package
import nimph/version
import nimph/requirement
import nimph/dependency
import nimph/versiontags

proc v(loose: string): Version =
  ## convenience
  let release = parseVersionLoosely(loose)
  result = release.get.version

block:
  # let us shadow `project`
  suite "welcome to the nimph-o-matic 9000":
    const
      sample = "tests/sample.cfg"
      testcfg = newTarget(sample)
      was = staticRead(sample.extractFilename)

    var project: Project
    var deps: DependencyGroup

    test "open the project":
      let target = findTarget(".")
      check "finding targets":
        target.found.isSome
        findProject(project, (get target.found).repo)

    test "load a nim.cfg":
      let loaded = parseConfigFile(sample)
      check loaded.isSome

    test "naive parse":
      let parsed = parseProjectCfg(testcfg)
      check parsed.ok
      check "nimblePath" in parsed.table
      checkpoint $parsed.table
      check parsed.table["path"].len == 1
      check parsed.table["path"][0].len > 1
      for find in ["test4", "test3:foo", "test2=foo"]:
        block found:
          for values in parsed.table.values:
            for value in values.items:
              if value == find:
                break found
          fail "missing config values from parse"

    test "add a line to a config":
      check testcfg.appendConfig("--clearNimblePath")
      let now = readFile(sample)
      check "splitlines":
        # check for empty trailing line
        was.splitLines.len + 2 == now.splitLines.len
        now.splitLines[^1] == ""
      writeFile(sample, was)

    test "parse some dump output":
      let text = """oneline: "is fine"""" & "\n"
      let parsed = parseNimbleDump(text)
      check parsed.isSome

    test "via subprocess capture":
      let dumped = fetchNimbleDump(project.nimble.repo)
      check dumped.ok == true
      if dumped.ok:
        check dumped.table["Name"] == "nimph"

    const
      # how we'll render a release requirement like "package"
      anyRelease = "*"

    test "parse simple requires statements":
      let
        text1 = "nim >= 0.18.0, bump 1.8.6, github < 2.0.0"
        text2 = ""
        text3 = "nim #catsAndDogsLivingTogether"
        text4 = "goats"
        text5 = "goats ^1.2.3"
        text6 = "nim#catsAndDogsLivingTogether"
        text7 = "pigs 2.*.*"
        text8 = "git://github.com/disruptek/bump.git#1.8.8"
        text9 = "git://github.com/disruptek/bump.git"
        text10 = "pigs 2.*"
        text11 = "dogs ^3.2"
        text12 = "owls ~4"
        text13 = "owls any version"
        text14 = "owls >=1.0.0 &< 2"
        parsed1 = parseRequires(text1)
        parsed2 = parseRequires(text2)
        parsed3 = parseRequires(text3)
        parsed4 = parseRequires(text4)
        parsed5 = parseRequires(text5)
        parsed6 = parseRequires(text6)
        parsed7 = parseRequires(text7)
        parsed8 = parseRequires(text8)
        parsed9 = parseRequires(text9)
        parsed10 = parseRequires(text10)
        parsed11 = parseRequires(text11)
        parsed12 = parseRequires(text12)
        parsed13 = parseRequires(text13)
        parsed14 = parseRequires(text14)
      check parsed1.isSome
      check parsed2.isSome
      check parsed3.isSome
      check parsed4.isSome
      for req in parsed4.get.values:
        check $req.release == anyRelease
      check parsed5.isSome
      check parsed6.isSome
      for req in parsed6.get.values:
        check req.release.reference == "catsAndDogsLivingTogether"
      check parsed7.isSome
      for req in parsed7.get.values:
        check $req.release == "2"
      check parsed8.isSome
      for req in parsed8.get.values:
        check req.identity == "git://github.com/disruptek/bump.git"
        check req.release.reference == "1.8.8"
      for req in parsed9.get.values:
        check req.identity == "git://github.com/disruptek/bump.git"
        check $req.release == anyRelease
      for req in parsed10.get.values:
        check req.identity == "pigs"
      for req in parsed11.get.values:
        check req.identity == "dogs"
      for req in parsed12.get.values:
        check req.identity == "owls"
        check not req.isSatisfiedBy newRelease"1.8.8"
      for req in parsed13.get.values:
        check $req.release == anyRelease
        check req.isSatisfiedBy newRelease"1.8.8"
      check parsed14.get.len == 2
      for req in parsed14.get.values:
        checkpoint $req

    test "parse nimph requires statement":
      project.fetchDump()
      let
        text = project.dump["requires"]
        parsed = parseRequires(text)
      check parsed.isSome

    test "naive package naming":
      check "nim_Somepack" == importName(parseUri"git@github.com:some/nim-Somepack.git/")
      check "nim_Somepack" == importName(parseUri"git@github.com:some/nim-Somepack.git")
      check "somepack" == importName("/some/other/somepack-1.2.3".pathToImport)

    test "get the official packages list":
      let
        parsed = getOfficialPackages(project.nimbleDir)
      check parsed.ok == true
      check "release" in parsed.packages["bump"].tags

    test "requirements versus versions":
      let
        works = [
          newRequirement("a", Equal, "1.2.3"),
          newRequirement("a", AtLeast, "1.2.3"),
          newRequirement("a", NotMore, "1.2.3"),
          newRequirement("a", Caret, "1"),
          newRequirement("a", Caret, "1.2"),
          newRequirement("a", Caret, "1.2.3"),
          newRequirement("a", Tilde, "1"),
          newRequirement("a", Tilde, "1.2"),
          newRequirement("a", Tilde, "1.2.0"),
        ]
        breaks = [
          newRequirement("a", Equal, "1.2.4"),
          newRequirement("a", AtLeast, "1.2.4"),
          newRequirement("a", NotMore, "1.2.2"),
          newRequirement("a", Caret, "2"),
          newRequirement("a", Caret, "1.3"),
          newRequirement("a", Caret, "1.2.4"),
          newRequirement("a", Tilde, "0"),
          newRequirement("a", Tilde, "1.1"),
          newRequirement("a", Tilde, "1.1.2"),
        ]
        one23 = newRelease("1.2.3")
      for req in works.items:
        check req.isSatisfiedBy one23
      for req in breaks.items:
        check not req.isSatisfiedBy one23

    test "parse version loosely":
      let
        works = [
          "v1.2.3",
          "V. 1.2.3",
          "1.2.3-rc2",
          "1.2.3a",
          "1.2.3",
          "1.2.3.4",
          "mary had a little l1.2.3mb whose fleece... ah you get the picture"
        ]
      for v in works.items:
        let parsed = v.parseVersionLoosely
        check parsed.isSome
        check $parsed.get == "1.2.3"
      check "".parseVersionLoosely.isNone

    block:
      ## load project config
      project.cfg = loadAllCfgs project.repo

    block:
      ## dependencies, path-for-name, project-for-path
      deps = newDependencyGroup(project, {Dry})
      check project.resolve(deps)
      var path = deps.pathForName "cutelog"
      check path.isSome
      check dirExists(get path)
      var proj = deps.projectForPath path.get
      check proj.isSome
      check (get proj).name == "cutelog"

    repository := openRepository project.gitDir:
      fail"unable to open the repo"

    test "roll between versions":
      returnToHeadAfter project:
        for ver in ["0.6.6", "0.6.5"]:
          let release = newRelease(ver, operator = Tag)
          let req = newRequirement($project.url, operator = Tag, release)
          if project.rollTowards(req):
            for stat in repository.status(GIT_STATUS_SHOW_INDEX_AND_WORKDIR):
              check stat.isOk
              check GIT_STATUS_INDEX_MODIFIED notin stat.get.flags

    test "project version changes":
      returnToHeadAfter project:
        let versioned = project.versionChangingCommits
        let required = project.requirementChangingCommits
        when false:
          for key, value in versioned.pairs:
            checkpoint "versioned ", key
          for key, value in required.pairs:
            checkpoint "required ", key
        check "version oids as expected":
          $versioned[v"0.6.5"].oid == "8937c0b998376944fd93d6d8e7b3cf4db91dfb9b"
          $versioned[v"0.6.6"].oid == "5a3de5a5fc9b83d5a9bba23f7e950b37a96d10e6"

    test "basic tag table fetch":
      fetchTagTable project
      check project.tags != nil, "tag fetch yielded no table"
      check project.tags.len > 0, "tag fetch created empty table"

    test "make sure richen finds a tag":
      check not project.tags.isNil, "tag fetch unsuccessful"
      block found:
        for release, thing in project.tags.richen:
          when false:
            checkpoint $release
            checkpoint $thing
          if release == newRelease("0.6.14", operator = Tag):
            break found
        fail"tag for 0.6.14 was not found"
