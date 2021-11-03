import std/os
import std/strutils
import std/options
import std/uri

import pkg/bump
import pkg/balls

import nimph/spec
import nimph/version

suite "welcome to the nimph-o-matic 9000":
  proc v(loose: string): Version =
    let release = parseVersionLoosely(loose)
    result = release.get.version

  test "some url munging":
    let
      sshUrl = parseUri"git@github.com:disruptek/nimph.git"
      gitUrl = parseUri"git://github.com/disruptek/nimph.git"
      webUrl = parseUri"https://github.com/disruptek/nimph"
      bigUrl = parseUri"https://github.com/Vindaar/ginger"
      bagUrl = parseUri"https://githob.com/Vindaar/ginger"
    check "convert to git":
      $sshUrl.convertToGit == $gitUrl
      $gitUrl.convertToGit == $gitUrl
      $webUrl.convertToGit == $webUrl & ".git"  # !!!
    #check "convert to ssh":
    checkpoint $sshUrl.convertToSsh
    checkpoint $gitUrl.convertToSsh
    checkpoint $webUrl.convertToSsh
    check $sshUrl.convertToSsh == $sshUrl
    check $gitUrl.convertToSsh == $sshUrl
    check $webUrl.convertToSsh == $sshUrl
    check "normalize path case (only) for github":
      $bigUrl.normalizeUrl == ($bigUrl).toLowerAscii
      $bagUrl.normalizeUrl == $bagUrl
    check $gitUrl.prepareForClone == $webUrl & ".git" # !!!

  test "fork targets":
    for url in [
      parseUri"git@github.com:disruptek/nimph.git",
      parseUri"git://github.com/disruptek/nimph.git",
      parseUri"https://github.com/disruptek/nimph",
    ].items:
      let fork {.used.} = url.forkTarget
      checkpoint $url
      #checkpoint fork.repr
      check fork.ok
      check fork.owner == "disruptek" and fork.repo == "nimph"

  test "url normalization":
    let
      sshUser = "git"
      sshUrl1 = "git@git.sr.ht:~kungtotte/dtt"
      sshHost1 = "git.sr.ht"
      sshPath1 = "~kungtotte/dtt"
      sshUrl2 = "git@github.com:disruptek/nimph.git"
      sshHost2 = "github.com"
      sshPath2 = "disruptek/nimph.git"
      normUrl1 = normalizeUrl(parseUri(sshUrl1))
      normUrl2 = normalizeUrl(parseUri(sshUrl2))

    check "more creepy urls":
      normUrl1.username == sshUser
      normUrl1.hostname == sshHost1
      normUrl1.path == sshPath1
      normUrl2.username == sshUser
      normUrl2.hostname == sshHost2
      normUrl2.path == sshPath2

  test "path joins":
    let
      p = "goats"
      o = "pigs/"
    check "slash attack":
      ///p == "goats/"
      ///o == "pigs/"
      //////p == "/goats/"
      //////o == "/pigs/"
