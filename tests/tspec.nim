import std/os
import std/unittest
import std/uri

import nimph/spec

suite "spec":
  test "some url munging":
    let
      sshUrl = parseUri"git@github.com:disruptek/nimph.git"
      gitUrl = parseUri"git://github.com/disruptek/nimph.git"
      webUrl = parseUri"https://github.com/disruptek/nimph"
    check $sshUrl.convertToGit == $gitUrl
    check $gitUrl.convertToGit == $gitUrl
    check $webUrl.convertToGit == $gitUrl
    check $sshUrl.convertToSsh == $sshUrl
    check $gitUrl.convertToSsh == $sshUrl
    check $webUrl.convertToSsh == $sshUrl

  test "fork targets":
    for url in [
      parseUri"git@github.com:disruptek/nimph.git",
      parseUri"git://github.com/disruptek/nimph.git",
      parseUri"https://github.com/disruptek/nimph",
    ].items:
      let fork {.used.} = url.forkTarget
      checkpoint $url
      checkpoint fork.repr
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

    check normUrl1.username == sshUser
    check normUrl1.hostname == sshHost1
    check normUrl1.path == sshPath1
    check normUrl2.username == sshUser
    check normUrl2.hostname == sshHost2
    check normUrl2.path == sshPath2

  test "path joins":
    let
      p = "goats"
      o = "pigs/"
    check ///p == "goats/"
    check ///o == "pigs/"
    check //////p == "/goats/"
    check //////o == "/pigs/"
