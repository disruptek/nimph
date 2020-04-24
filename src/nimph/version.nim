import std/strformat
import std/hashes
import std/strutils
import std/tables
import std/options

import bump
import npeg

import nimph/spec

type
  VersionField* = typeof(Version.major)
  VersionIndex* = range[0 .. 2]
  VersionMaskField* = Option[VersionField]
  VersionMask* = object
    major*: VersionMaskField
    minor*: VersionMaskField
    patch*: VersionMaskField

  Operator* = enum
    Tag = "#"
    Wild = "*"
    Tilde = "~"
    Caret = "^"
    Equal = "=="
    AtLeast = ">="
    Over = ">"
    Under = "<"
    NotMore = "<="

  # the specification of a version, release, or mask
  Release* = object
    case kind*: Operator
    of Tag:
      reference*: string
    of Wild, Caret, Tilde:
      accepts*: VersionMask
    of Equal, AtLeast, Over, Under, NotMore:
      version*: Version

const
  Wildlings* = {Wild, Caret, Tilde}

template starOrDigits(s: string): VersionMaskField =
  ## parse a star or digit as in a version mask
  if s == "*":
    # VersionMaskField is Option[VersionField]
    none(VersionField)
  else:
    some(s.parseUInt)

proc parseDottedVersion*(input: string): Version =
  ## try to parse `1.2.3` into a `Version`
  let
    dotted = input.split('.')
  block:
    if dotted.len < 3:
      break
    try:
      result = (major: dotted[0].parseUInt,
                minor: dotted[1].parseUInt,
                patch: dotted[2].parseUInt)
    except ValueError:
      discard

proc newVersionMask(input: string): VersionMask =
  ## try to parse `1.2` or `1.2.*` into a `VersionMask`
  let
    dotted = input.split('.')
  if dotted.len > 0:
    result.major = dotted[0].starOrDigits
  if dotted.len > 1:
    result.minor = dotted[1].starOrDigits
  if dotted.len > 2:
    result.patch = dotted[2].starOrDigits

proc isValid*(release: Release): bool =
  ## true if the release seems plausible
  const sensible = @[
    [ true, false, false],
    [ true,  true, false],
    [ true,  true, true ],
  ]
  case release.kind:
  of Tag:
    result = release.reference != ""
  of Wild, Caret, Tilde:
    let
      pattern = [release.accepts.major.isSome,
                 release.accepts.minor.isSome,
                 release.accepts.patch.isSome]
    result = pattern in sensible
    # let's say that *.*.* is valid; it could be useful
    if release.kind == Wild:
      result = result or pattern == [false, false, false]
  else:
    result = release.version.isValid

proc newRelease*(version: Version): Release =
  ## create a new release using a version
  if not version.isValid:
    raise newException(ValueError, &"invalid version `{version}`")
  result = Release(kind: Equal, version: version)

proc newRelease*(reference: string; operator = Equal): Release

proc parseVersionLoosely*(content: string): Option[Release] =
  ## a very relaxed parser for versions found in tags, etc.
  ## only valid releases are emitted, however
  var
    release: Release
  let
    peggy = peg "document":
      ver <- +Digit * ('.' * +Digit)[0..2]
      record <- >ver * (!Digit | !1):
        if not release.isValid:
          release = newRelease($1, operator = Equal)
      document <- +(record | 1) * !1
  try:
    let
      parsed = peggy.match(content)
    if parsed.ok and release.isValid:
      result = release.some
  except Exception as e:
    let emsg = &"parse error in `{content}`: {e.msg}" # noqa
    warn emsg

proc newRelease*(reference: string; operator = Equal): Release =
  ## parse a version, mask, or tag with an operator hint from the requirement
  if reference.startsWith("#") or operator == Tag:
    result = Release(kind: Tag, reference: reference)
    removePrefix(result.reference, {'#'})
  elif reference in ["", "any version"]:
    result = Release(kind: Wild, accepts: newVersionMask("*"))
  elif "*" in reference:
    result = Release(kind: Wild, accepts: newVersionMask(reference))
  elif operator in Wildlings:
    # thanks, jasper
    case operator:
    of Wildlings:
      result = Release(kind: operator, accepts: newVersionMask(reference))
    else:
      raise newException(Defect, "inconceivable!")
  elif count(reference, '.') < 2:
    result = Release(kind: Wild, accepts: newVersionMask(reference))
  else:
    result = newRelease(parseDottedVersion(reference))

proc `$`*(field: VersionMaskField): string =
  if field.isNone:
    result = "*"
  else:
    result = $field.get

proc `$`*(mask: VersionMask): string =
  result = $mask.major
  result &= "." & $mask.minor
  result &= "." & $mask.patch

proc omitStars*(mask: VersionMask): string =
  result = $mask.major
  if mask.minor.isSome:
    result &= "." & $mask.minor
  if mask.patch.isSome:
    result &= "." & $mask.patch

proc `$`*(spec: Release): string =
  case spec.kind
  of Tag:
    result = $spec.kind & $spec.reference
  of Equal, AtLeast, Over, Under, NotMore:
    result = $spec.version
  of Wild, Caret, Tilde:
    result = spec.accepts.omitStars

proc `==`*(a, b: VersionMaskField): bool =
  result = a.isNone == b.isNone
  if result and a.isSome:
    result = a.get == b.get

proc `<`*(a, b: VersionMaskField): bool =
  result = a.isNone == b.isNone
  if result and a.isSome:
    result = a.get < b.get

proc `==`*(a, b: VersionMask): bool =
  result = a.major == b.major
  result = result and a.minor == b.minor
  result = result and a.patch == a.patch

proc `==`*(a, b: Release): bool =
  if a.kind == b.kind and a.isValid and b.isValid:
    case a.kind:
    of Tag:
      result = a.reference == b.reference
    of Wild, Caret, Tilde:
      result = a.accepts == b.accepts
    else:
      result = a.version == b.version

proc `<`*(a, b: Release): bool =
  if a.kind == b.kind and a.isValid and b.isValid:
    case a.kind
    of Tag:
      result = a.reference < b.reference
    of Equal:
      result = a.version < b.version
    else:
      raise newException(ValueError, "inconceivable!")

proc `<=`*(a, b: Release): bool =
  result = a == b or a < b

proc `==`*(a: VersionMask; b: Version): bool =
  if a.major.isSome and a.major.get == b.major:
    if a.minor.isSome and a.minor.get == b.minor:
      if a.patch.isSome and a.patch.get == b.patch:
        result = true

proc acceptable*(mask: VersionMaskField; op: Operator;
                 value: VersionField): bool =
  ## true if the versionfield value passes the mask
  case op:
  of Wild:
    result = mask.isNone or value == mask.get
  of Caret:
    result = mask.isNone
    result = result or (value >= mask.get and mask.get > 0'u)
    result = result or (value == 0 and mask.get == 0)
  of Tilde:
    result = mask.isNone or value >= mask.get
  else:
    raise newException(Defect, "inconceivable!")

proc at*[T: Version | VersionMask](version: T; index: VersionIndex): auto =
  ## like [int] but clashless
  case index:
  of 0: result = version.major
  of 1: result = version.minor
  of 2: result = version.patch

proc `[]=`*(mask: var VersionMask;
            index: VersionIndex; value: VersionMaskField) =
  case index:
  of 0: mask.major = value
  of 1: mask.minor = value
  of 2: mask.patch = value

iterator items*[T: Version | VersionMask](version: T): auto =
  for i in VersionIndex.low .. VersionIndex.high:
    yield version.at(i)

iterator pairs*[T: Version | VersionMask](version: T): auto =
  for i in VersionIndex.low .. VersionIndex.high:
    yield (index: i, field: version.at(i))

proc isSpecific*(release: Release): bool =
  ## if the version/match specifies a full X.Y.Z version
  if release.kind in {Equal, AtLeast, NotMore} and release.isValid:
    result = true
  elif release.kind in Wildlings and release.accepts.patch.isSome:
    result = true

proc specifically*(release: Release): Version =
  ## a full X.Y.Z version the release will match
  if not release.isSpecific:
    let emsg = &"release {release} is not specific" # noqa
    raise newException(Defect, emsg)
  if release.kind in Wildlings:
    result = (major: release.accepts.major.get,
              minor: release.accepts.minor.get,
              patch: release.accepts.patch.get)
  else:
    result = release.version

proc effectively*(mask: VersionMask): Version =
  ## replace * with 0 in wildcard masks
  if mask.major.isNone:
    result = (0'u, 0'u, 0'u)
  elif mask.minor.isNone:
    result = (mask.major.get, 0'u, 0'u)
  elif mask.patch.isNone:
    result = (mask.major.get, mask.minor.get, 0'u)
  else:
    result = (mask.major.get, mask.minor.get, mask.patch.get)

proc effectively*(release: Release): Version =
  ## convert a release to a version for rough comparisons
  case release.kind:
  of Tag:
    let parsed = parseVersionLoosely(release.reference)
    if parsed.isNone:
      result = (0'u, 0'u, 0'u)
    elif parsed.get.kind == Tag:
      raise newException(Defect, "inconceivable!")
    result = parsed.get.effectively
  of Wildlings:
    result = release.accepts.effectively
  of Equal:
    result = release.version
  else:
    raise newException(Defect, "not implemented")

proc hash*(field: VersionMaskField): Hash =
  ## help hash version masks
  var h: Hash = 0
  if field.isNone:
    h = h !& '*'.hash
  else:
    h = h !& field.get.hash
  result = !$h

proc hash*(mask: VersionMask): Hash =
  ## uniquely identify a version mask
  var h: Hash = 0
  h = h !& mask.major.hash
  h = h !& mask.minor.hash
  h = h !& mask.patch.hash
  result = !$h

proc hash*(release: Release): Hash =
  ## uniquely identify a release
  var h: Hash = 0
  h = h !& release.kind.hash
  case release.kind:
  of Tag:
    h = h !& release.reference.hash
  of Wild, Tilde, Caret:
    h = h !& release.accepts.hash
  of Equal, AtLeast, Over, Under, NotMore:
    h = h !& release.version.hash
  result = !$h

proc toMask*(version: Version): VersionMask =
  ## populate a versionmask with values from a version
  for i, field in version.pairs:
    result[i] = field.some

proc importName*(target: Target): string =
  ## a uniform name usable in code for imports
  assert target.repo.len > 0
  result = target.repo.pathToImport.importName

iterator likelyTags*(version: Version): string =
  ## produce tags with/without silly `v` prefixes
  let v = $version
  yield        v
  yield "v"  & v
  yield "V"  & v
  yield "v." & v
  yield "V." & v

iterator semanticVersionStrings*(mask: VersionMask): string =
  ## emit 3, 3.1, 3.1.4 (if possible)
  var
    last: string
  if mask.major.isSome:
    last = $mask.major.get
    yield last
    if mask.minor.isSome:
      last &= "." & $mask.minor.get
      yield last
      if mask.patch.isSome:
        yield last & "." & $mask.patch.get

iterator semanticVersionStrings*(version: Version): string =
  ## emit 3, 3.1, 3.1.4
  yield $version.major
  yield $version.major & "." & $version.minor
  yield $version.major & "." & $version.minor & "." & $version.patch
