import std/uri

import unittest2

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
