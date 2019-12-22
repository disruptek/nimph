import std/options
import std/strutils
import std/strformat
import std/tables
import std/uri except Url
import std/hashes

import bump
import npeg

import nimph/spec
import nimph/version

type
  # the specification of a package requirement
  Requirement* = ref object
    identity*: string
    operator*: Operator
    release*: Release
    child*: Requirement
    notes*: string

  Requires* = OrderedTableRef[Requirement, Requirement]

proc `$`*(req: Requirement): string =
  result = &"{req.identity}{req.operator}{req.release}"

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

proc isSatisfiedBy(requirement: Requirement; version: Version): bool =
  ## true if the version satisfies the requirement
  let
    op = requirement.operator
  case op:
  of Tag:
    # try to parse a version from the tag and see if it matches exactly
    result = version == requirement.release.effectively
  of Caret:
    # the caret logic is designed to match that of cargo
    block caret:
      let accepts = requirement.release.accepts
      for index, field in accepts.pairs:
        if field.isNone:
          break
        if result == false:
          if field.get != 0:
            if field.get != version.at(index):
              result = false
              break caret
            result = true
        elif field.get > version.at(index):
          result = false
          break caret
  of Tilde:
    # the tilde logic is designed to match that of cargo
    block tilde:
      let accepts = requirement.release.accepts
      for index, field in accepts.pairs:
        if field.isNone or index == VersionIndex.high:
          break
        if field.get != version.at(index):
          result = false
          break tilde
      result = true
  of Wild:
    # wildcards match 3.1.* or simple strings like "3" (3.*.*)
    let accepts = requirement.release.accepts
    # all the fields must be acceptable
    if acceptable(accepts.major, op, version.major):
      if acceptable(accepts.minor, op, version.minor):
        if acceptable(accepts.patch, op, version.patch):
          result = true
  of Equal:
    result = version == requirement.release.version
  of AtLeast:
    result = version >= requirement.release.version
  of NotMore:
    result = version <= requirement.release.version
  of Under:
    result = version < requirement.release.version
  of Over:
    result = version > requirement.release.version

proc isSatisfiedBy*(req: Requirement; spec: Release): bool =
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
    # otherwise, we might be able to treat it as a version
    elif spec.isSpecific:
      result = req.isSatisfiedBy spec.specifically
    # else we're gonna have to abstract "3" to "3.0.0"
    else:
      result = req.isSatisfiedBy spec.effectively

proc hash*(req: Requirement): Hash =
  ## uniquely identify a requirement
  var h: Hash = 0
  h = h !& req.identity.hash
  h = h !& req.operator.hash
  h = h !& req.release.hash
  if req.child != nil:
    h = h !& req.child.hash
  result = !$h

proc adopt*(parent: var Requirement; child: Requirement) =
  ## combine two requirements
  if parent != child:
    if parent.child == nil:
      parent.child = child
    else:
      parent.child.adopt child

iterator children*(parent: Requirement; andParent = false): Requirement =
  ## yield the children of a parent requirement
  var req = parent
  if andParent:
    yield req
  while req.child != nil:
    req = req.child
    yield req

proc newRequirement*(id: string; operator: Operator;
                     release: Release, notes = ""): Requirement =
  ## create a requirement from a release, eg. that of a project
  when defined(debug):
    if id != id.strip:
      warn &"whitespace around requirement identity: `{id}`"
  if id == "":
    raise newException(ValueError, "requirements must have length, if not girth")
  result = Requirement(identity: id.strip, release: release, notes: notes)
  # if it parsed as Caret, Tilde, or Wild, then paint the requirement as such
  if result.release in Wildlings:
    result.operator = result.release.kind
  elif result.release in {Tag}:
    # eventually, we'll support tag comparisons...
    {.warning: "tag comparisons unsupported".}
    result.operator = result.release.kind
  else:
    result.operator = operator

proc newRequirement*(id: string; operator: Operator; spec: string): Requirement =
  ## parse a requirement from a string
  result = newRequirement(id, operator, newRelease(spec, operator = operator))

proc newRequirement(id: string; operator: string; spec: string): Requirement =
  ## parse a requirement with the given operator from a string
  var
    op = Equal
  # using "" to mean "==" was retarded and i refuse to map my Equal
  # enum to "" in capitulation; nil carborundum illegitimi
  if operator != "":
    op = parseEnum[Operator](operator)
  result = newRequirement(id, op, spec)

iterator orphans*(parent: Requirement): Requirement =
  ## yield each requirement without their kids
  for child in parent.children(andParent = true):
    yield newRequirement(id = child.identity, operator = child.operator,
                         release = child.release, notes = child.notes)

proc parseRequires*(input: string): Option[Requires] =
  ## parse a `requires` string output from `nimble dump`
  ## also supports `~` and `^` and `*` operators a la cargo
  var
    requires = Requires()
    lastname: string

  let
    peggy = peg "document":
      white <- {'\t', ' '}
      url <- +Alnum * "://" * +(1 - white - ending - '#')
      name <- url | +(Alnum | '_')
      ops <- ">=" | "<=" | ">" | "<" | "==" | "~" | "^" | 0
      dstar <- +Digit | '*'
      ver <- (dstar * ('.' * dstar)[0..2]) | "any version"
      ending <- (*white * "," * *white) | (*white * "&" * *white) | !1
      tag <- '#' * +(1 - ending)
      spec <- tag | ver
      anyrecord <- >name:
        lastname = $1
        let req = newRequirement(id = $1, operator = Wild, spec = "*")
        if req notin requires:
          requires[req] = req
      andrecord <- *white * >ops * *white * >spec:
        let req = newRequirement(id = lastname, operator = $1, spec = $2)
        if req notin requires:
          requires[req] = req
      inrecord <- >name * *white * >ops * *white * >spec:
        lastname = $1
        let req = newRequirement(id = $1, operator = $2, spec = $3)
        if req notin requires:
          requires[req] = req
      record <- (inrecord | andrecord | anyrecord) * ending
      document <- *record
    parsed = peggy.match(input)
  if parsed.ok:
    result = requires.some

proc isVirtual*(requirement: Requirement): bool =
  ## is the requirement something we should overlook?
  result = requirement.identity.toLowerAscii in ["nim"]

proc isUrl*(requirement: Requirement): bool =
  ## a terrible way to determine if the requirement is a url
  result = ':' in requirement.identity

proc asUrlAnchor*(release: Release): string =
  ## produce a suitable url anchor referencing a release
  case release.kind:
  of Tag:
    result = release.reference
  of Equal:
    result = $release.version
  else:
    raise newException(Defect, "not yet implemented")

proc toUrl*(requirement: Requirement): Option[Uri] =
  ## try to determine the distribution url for a requirement
  # if it could be a url, try to parse it as such
  if requirement.isUrl:
    try:
      var url = parseUri(requirement.identity)
      if requirement.release.kind in {Equal, Tag}:
        url.anchor = requirement.release.asUrlAnchor
        removePrefix(url.anchor, {'#'})
      result = url.some
    except:
      warn &"unable to parse requirement `{requirement.identity}`"

proc importName*(requirement: Requirement): string =
  ## guess the import name given only a requirement
  block:
    if requirement.isUrl:
      let url = requirement.toUrl
      if url.isSome:
        result = url.get.importName
        break
    result = requirement.identity.importName

proc describe*(requirement: Requirement): string =
  ## describe a requirement and where it may have come from, if possible
  result = $requirement
  if requirement.notes != "":
    result &= " from " & requirement.notes
