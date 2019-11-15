import std/uri
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
    major: VersionMaskField
    minor: VersionMaskField
    patch: VersionMaskField

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

  # the specification of a package requirement
  Requirement* = object
    identity*: string
    operator*: Operator
    release*: Release

  Requires* = OrderedTableRef[Requirement, Requirement]

const
  Wildlings = {Wild, Caret, Tilde}

proc `$`*(field: VersionMaskField): string =
  if field.isNone:
    result = "*"
  else:
    result = $field.get

proc `$`*(mask: VersionMask): string =
  result = $mask.major
  result &= "." & $mask.minor
  result &= "." & $mask.patch

proc `omitStars`*(mask: VersionMask): string =
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
  of Wild:
    result = $spec.accepts
  of Caret, Tilde:
    result = spec.accepts.omitStars

proc `$`*(req: Requirement): string =
  result = &"{req.identity}{req.operator}{req.release}"

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

proc isValid*(req: Requirement): bool =
  ## true if the requirement seems sensible
  result = req.release.isValid
  if not result:
    return
  case req.operator:

  # if the operator is Tag, it's essentially a #== test
  of Tag:
    result = req.release.kind in {Tag}
  # if the operator supports a mask, then so might the release
  of Caret, Tilde, Wild:
    result = req.release.kind in {Wild, Equal}
  # if the operator supports only equality, apply it to tags, versions
  of Equal:
    result = req.release.kind in {Tag, Equal}
  # else it can only be a relative comparison to a complete version spec
  else:
    result = req.release.kind in {Equal}

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
    case a.kind
    of Tag:
      result = a.reference == b.reference
    of Equal:
      result = a.version == b.version
    of Wild, Caret, Tilde:
      result = a.accepts == b.accepts
    else:
      raise newException(ValueError, "inconceivable!")

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
    result = result or (value >= mask.get and mask.get > 0)
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

proc `[]`*[T: Version | VersionMask](version: T; index: VersionIndex): auto {.deprecated.} =
  ## deprecated because it doesn't seem to work consistently
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
  result = release.kind in {Equal, AtLeast, NotMore} and release.isValid
  result = result or (release.kind in Wildlings and release.accepts.patch.isSome)

proc specifically*(release: Release): Version =
  ## a full X.Y.Z version the release will match
  if release.isSpecific:
    if release.kind in Wildlings:
      result = (major: release.accepts.major.get,
                minor: release.accepts.minor.get,
                patch: release.accepts.patch.get)
    else:
      result = release.version
  else:
    raise newException(ValueError, &"release {release} is not specific")

proc contains(requirement: Requirement; version: Version): bool =
  ## true if the version satisfies the requirement
  let
    op = requirement.operator
    accepts = requirement.release.accepts
  case op:
  of Caret:
    # i know, this looks nuts
    for index, field in accepts.pairs:
      if field.isNone:
        break
      if result == false:
        if field.get != 0:
          if field.get != version.at(index):
            return false
          result = true
      elif field.get > version.at(index):
        return false
  of Tilde:
    for index, field in accepts.pairs:
      if field.isNone or index == VersionIndex.high:
        break
      if field.get != version.at(index):
        return false
    return true
  of Wild:
    result = acceptable(accepts.major, op, version.major)
    result = result and acceptable(accepts.minor, op, version.minor)
    result = result and acceptable(accepts.patch, requirement.operator,
                                   version.patch)
  else:
    raise newException(Defect, "unexpected (yet)")

proc contains*(kinds: set[Operator]; spec: Release): bool =
  ## convenience
  result = spec.kind in kinds

proc contains*(req: Requirement; spec: Release): bool =
  ## true if the requirement is satisfied by the specification
  case req.operator:
  of Tag:
    result = spec.reference == req.release.reference
  of Equal:
    result = spec == req.release
  of AtLeast:
    result = spec >= req.release
  of NotMore:
    result = spec <= req.release
  of Under:
    result = spec < req.release
  of Over:
    result = spec > req.release
  of Tilde, Caret, Wild:
    # check if the wildcard matches everything (only Wild, in theory)
    if req.release.accepts.major.isNone:
      result = true
    # otherwise, we have to compare it to a version
    elif spec.isSpecific:
      result = spec.version in req
    else:
      raise newException(Defect, &"unimplemented for {spec.kind} release")

template starOrDigits(s: string): VersionMaskField =
  ## parse a star or digit as in a version mask
  if s == "*":
    # VersionMaskField is Option[VersionField]
    none(VersionField)
  else:
    some(s.parseUInt)

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

proc parseDottedVersion(input: string): Version =
  ## try to parse `1.2.3` into a `Version`
  let
    dotted = input.split('.')
  if dotted.len != 3:
    return
  try:
    result = (major: dotted[0].parseUInt,
              minor: dotted[1].parseUInt,
              patch: dotted[2].parseUInt)
  except ValueError:
    discard

proc newRelease*(version: Version): Release =
  if not version.isValid:
    raise newException(ValueError, &"invalid version `{version}`")
  result = Release(kind: Equal, version: version)

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
    try:
      result = newRelease(parseDottedVersion(reference))
    except ValueError:
      raise newException(ValueError, &"parse error on version `{reference}`")

proc hash(field: VersionMaskField): Hash =
  ## help hash version masks
  var h: Hash = 0
  if field.isNone:
    h = h !& '*'.hash
  else:
    h = h !& field.get.hash
  result = !$h

proc hash(mask: VersionMask): Hash =
  ## uniquely identify a version mask
  var h: Hash = 0
  h = h !& mask.major.hash
  h = h !& mask.minor.hash
  h = h !& mask.patch.hash
  result = !$h

proc hash(release: Release): Hash =
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

proc hash(req: Requirement): Hash =
  ## uniquely identify a requirement
  var h: Hash = 0
  h = h !& req.identity.hash
  h = h !& req.operator.hash
  h = h !& req.release.hash
  result = !$h

proc toMask*(version: Version): VersionMask =
  for i, field in version.pairs:
    result[i] = field.some

proc newRequirement*(id: string; operator: Operator; spec: string): Requirement =
  ## parse a requirement
  when defined(debug):
    if id != id.strip:
      warn &"whitespace around requirement identity: `{id}`"
      result.identity = id
  result.identity = id.strip
  result.release = newRelease(spec, operator = operator)
  # if it parsed as Caret, Tilde, or Wild, then paint the requirement as such
  if result.release in Wildlings:
    result.operator = result.release.kind
  elif result.release in {Tag}:
    # eventually, we'll support tag comparisons...
    result.operator = result.release.kind
  else:
    result.operator = operator

proc newRequirement(id: string; operator: string; spec: string): Requirement =
  ## parse a requirement
  var
    op = Equal
  # using "" to mean "==" was retarded and i refuse to map my Equal
  # enum to "" in capitulation; nil carborundum illegitimi
  if operator != "":
    op = parseEnum[Operator](operator)
  result = newRequirement(id, op, spec)

proc parseRequires*(input: string): Option[Requires] =
  ## parse a `requires` string output from `nimble dump`
  ## also supports `~` and `^` operators a la cargo
  var
    requires = Requires()

  let
    peggy = peg "document":
      white <- {'\t', ' '}
      url <- +Alnum * "://" * +(1 - white - ending - '#')
      name <- url | +(Alnum | '_')
      ops <- ">=" | "<=" | ">" | "<" | "==" | "~" | "^" | 0
      dstar <- +Digit | '*'
      ver <- (dstar * ('.' * dstar)[0..2]) | "any version"
      ending <- ", " | !1
      tag <- '#' * +(1 - ending)
      spec <- tag | ver
      anyrecord <- >name:
        let req = newRequirement(id = $1, operator = Wild, spec = "*")
        if req notin requires:
          requires[req] = req
      inrecord <- >name * *white * >ops * *white * >spec:
        let req = newRequirement(id = $1, operator = $2, spec = $3)
        if req notin requires:
          requires[req] = req
      record <- (inrecord | anyrecord) * ending
      document <- *record
    parsed = peggy.match(input)
  if parsed.ok:
    result = requires.some

proc isVirtual*(requirement: Requirement): bool =
  result = requirement.identity.toLowerAscii in ["nim"]

proc isUrl*(requirement: Requirement): bool =
  result = ':' in requirement.identity

when false:
  proc importName*(requirement: Requirement): string =
    if not requirement.isUrl:
      result = requirement.identity
    else:
      result = now what genius

proc toUrl*(requirement: Requirement): Option[Uri] =
  ## try to determine the distribution url for a requirement
  var url: Uri
  # if it could be a url, try to parse it as such
  if requirement.isUrl:
    try:
      url = parseUri(requirement.identity)
      if requirement.release.kind in {Equal, Tag}:
        url.anchor = $requirement.release
        removePrefix(url.anchor, {'#'})
      result = url.some
    except:
      warn &"unable to parse requirement `{requirement.identity}`"
