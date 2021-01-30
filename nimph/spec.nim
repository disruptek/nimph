import std/options
import std/uri
import std/os
import std/times

import bump
import cutelog
export cutelog

import ups/sanitize
import ups/spec

type
  Flag* {.pure.} = enum
    Quiet
    Strict
    Force
    Dry
    Safe
    Network

  FlagStack = seq[set[Flag]]

  RollGoal* = enum
    Upgrade = "upgrade"
    Downgrade = "downgrade"
    Specific = "roll"

const
  hubTokenFn* {.strdefine.} = "".addFileExt("config") / "hub"
  stalePackages* {.intdefine.} = 14
  configFile* {.strdefine.} = "nimph".addFileExt("json")
  # add Safe to defaultFlags to, uh, default to Safe mode
  defaultFlags*: set[Flag] = {Quiet, Strict}
  shortDate* = initTimeFormat "yyyy-MM-dd"
  AndNimble* = false    # when true, try to support nimble

# we track current options as a stack of flags
var flags*: FlagStack = @[defaultFlags]
proc contains*(flags: FlagStack; f: Flag): bool = f in flags[^1]
proc contains*(flags: FlagStack; fs: set[Flag]): bool = fs <= flags[^1]
template push*(flags: var FlagStack; fs: set[Flag]) = flags.add fs
template withFlags*(fs: set[Flag]; body: untyped) =
  try:
    flags.push fs
    var flags {.inject.} = flags[^1]
    body
  finally:
    flags.pop

template timer*(name: string; body: untyped) =
  ## crude timer for debugging purposes
  let clock = epochTime()
  body
  debug name & " took " & $(epochTime() - clock)
