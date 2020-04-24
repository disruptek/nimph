import std/unittest
import std/uri
import std/tables
import std/strtabs
import std/options

import bump

import nimph/spec
import nimph/package
import nimph/project
import nimph/version
import nimph/requirement

const
  # how we'll render a release requirement like "package"
  anyRelease = "*"

suite "package":
  setup:
    let
      target = findTarget(".")
    var
      project {.used.} = newProject(target.found.get)

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
