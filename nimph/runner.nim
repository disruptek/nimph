import std/strutils
import std/strformat
import std/logging
import std/os
import std/sequtils
import std/osproc

import nimph/spec
import nimph/paths

type
  RunOutput* = object
    arguments*: seq[string]
    output*: string
    ok*: bool

proc stripPkgs*(nimbleDir: AbsoluteDir): AbsoluteDir =
  ## omit and trailing /PkgDir from a path
  result = nimbleDir
  # the only way this is a problem is if the user stores deps in pkgs/pkgs,
  # but we can remove this hack once we have nimblePaths in nim-1.0 ...
  if endsWith(result, PkgDir):
    result = parentDir(result)

proc runSomething*(exe: string; args: seq[string]; options: set[ProcessOption];
                   nimbleDir = AbsoluteDir""): RunOutput =
  ## run a program with arguments, perhaps with a particular nimbleDir
  var
    command = findExe(exe)
    arguments = args
    opts = options
  block ran:
    if command == "":
      result = RunOutput(output: &"unable to find {exe} in path")
      warn result.output
      break ran

    if exe == "nimble":
      when defined(debug):
        arguments = @["--verbose"].concat arguments
      when defined(debugNimble):
        arguments = @["--debug"].concat arguments

    if not nimbleDir.isEmpty:
      # we want to strip any trailing PkgDir arriving from elsewhere...
      var nimbleDir = stripPkgs(nimbleDir)
      if not dirExists(nimbleDir):
        let emsg = &"{nimbleDir} is missing; can't run {exe}" # noqa
        raise newException(IOError, emsg)
      # the ol' belt-and-suspenders approach to specifying nimbleDir
      if exe == "nimble":
        arguments = @["--nimbleDir=" & $nimbleDir].concat arguments
      putEnv("NIMBLE_DIR", $nimbleDir)

    if poParentStreams in opts or poInteractive in opts:
      # sorry; i just find this easier to read than union()
      opts.incl poInteractive
      opts.incl poParentStreams
      # the user wants interactivity
      timer command & arguments.join(" "):
        let
          process = startProcess(command, args = arguments, options = opts)
        result = RunOutput(ok: process.waitForExit == 0)
    else:
      # the user wants to capture output
      command &= " " & quoteShellCommand(arguments)
      timer command:
        let
          (output, code) = execCmdEx(command, opts)
        result = RunOutput(output: output, ok: code == 0)

    # for utility, also return the arguments we used
    result.arguments = arguments

    # a failure is worth noticing
    if not result.ok:
      notice exe & " " & arguments.join(" ")
