import std/strutils
import std/hashes
import std/tables
import std/strformat
import std/uri

import nimgit2

{.hint: "libgit2 version " & git2SetVer.}

import nimph/spec

when false:
  type
    GitObjectKind* = enum
      goAny         = (GIT_OBJECT_ANY, "object")
      goBad         = (GIT_OBJECT_INVALID, "invalid")
      goCommit      = (GIT_OBJECT_COMMIT, "commit")
      goTree        = (GIT_OBJECT_TREE, "tree")
      goBlob        = (GIT_OBJECT_BLOB, "blob")
      goTag         = (GIT_OBJECT_TAG, "tag")
      # this space intentionally left blank
      goOfsDelta    = (GIT_OBJECT_OFS_DELTA, "ofs")
      goRefDelta    = (GIT_OBJECT_REF_DELTA, "ref")
else:
  type
    GitObject* = ptr git_object
    GitObjectKind* = enum
      goAny         = (2 + GIT_OBJECT_ANY, "object")
      goBad         = (2 + GIT_OBJECT_INVALID, "invalid")
      goCommit      = (2 + GIT_OBJECT_COMMIT, "commit")
      goTree        = (2 + GIT_OBJECT_TREE, "tree")
      goBlob        = (2 + GIT_OBJECT_BLOB, "blob")
      goTag         = (2 + GIT_OBJECT_TAG, "tag")
      # this space intentionally left blank
      goOfsDelta    = (2 + GIT_OBJECT_OFS_DELTA, "ofs")
      goRefDelta    = (2 + GIT_OBJECT_REF_DELTA, "ref")
    GitThing* = ref object
      o*: GitObject
      case kind*: GitObjectKind:
      of goTag:
        discard
      of goRefDelta:
        discard
      else:
        discard

type
  GitHeapGits = git_repository | git_reference | git_remote | git_tag |
                git_strarray | git_object
  NimHeapGits = git_clone_options
  GitOid* = ptr git_oid
  GitRemote* = ptr git_remote
  GitReference* = ptr git_reference
  GitRepository* = ptr git_repository
  GitStrArray* = ptr git_strarray
  GitTag* = ptr git_tag
  GitClone* = object
    url*: cstring
    directory*: cstring
    repo*: GitRepository
    options*: ptr git_clone_options
  GitOpen* = object
    path*: cstring
    repo*: GitRepository
  GitTagTable* = OrderedTableRef[string, GitThing]

template dumpError() =
  let err = git_error_last()
  if err != nil:
    error $err.message

template gitTrap*(allocd: typed; code: int; body: untyped) =
  defer:
    free(allocd)
  if code != 0:
    dumpError()
    body

template gitTrap*(code: int; body: untyped) =
  if code != 0:
    dumpError()
    body

proc init*(): bool =
  let count = git_libgit2_init()
  result = count > 0
  debug "open gits:", count

proc shutdown*(): bool =
  let count = git_libgit2_shutdown()
  result = count >= 0
  debug "open gits:", count

template withGit*(body: untyped) =
  if not init():
    raise newException(OSError, "unable to init git")
  else:
    defer:
      if not shutdown():
        raise newException(OSError, "unable to shut git")
    body

proc free*[T: GitHeapGits](point: ptr T) =
  if point != nil:
    when T is git_repository:
      git_repository_free(point)
    elif T is git_reference:
      git_reference_free(point)
    elif T is git_remote:
      git_remote_free(point)
    elif T is git_strarray:
      git_strarray_free(point)
    elif T is git_tag:
      git_tag_free(point)
    elif T is git_object:
      git_object_free(point)
    else:
      {.error: "missing a free definition".}

proc free*[T: NimHeapGits](point: ptr T) =
  if point != nil:
    dealloc(point)

proc free*(clone: GitClone) =
  free(clone.repo)
  free(clone.options)

proc free*(opened: GitOpen) =
  free(opened.repo)

proc free*(thing: GitThing) =
  free(thing.o)

proc `$`*(got: GitOid): string =
  result = $git_oid_tostr_s(got)

proc `$`*(tag: GitTag): string =
  assert tag != nil
  let
    name = git_tag_name(tag)
  if name != nil:
    result = $name

proc message*(tag: GitTag): string =
  result = $git_tag_message(tag)

proc oid*(got: GitReference): GitOid =
  result = git_reference_target(got)

proc oid*(obj: GitObject): GitOid =
  result = git_object_id(obj)

proc oid*(thing: GitThing): GitOid =
  result = thing.o.oid

proc oid*(tag: GitTag): GitOid =
  result = git_tag_id(tag)

proc name*(got: GitReference): string =
  result = $git_reference_name(got)

proc isTag*(got: GitReference): bool =
  result = git_reference_is_tag(got) == 1

proc `$`*(reference: GitReference): string =
  if reference.isTag:
    result = reference.name
  else:
    result = $reference.oid

proc `$`*(obj: GitObject): string =
  result = $(git_object_type(obj).git_object_type2string)
  result &= "-" & $obj.git_object_id

proc `$`*(thing: GitThing): string =
  result = $thing.o
#  case thing.kind:
#  of goTag:
#  else:

proc free*(table: GitTagTable) =
  for tag, obj in table.pairs:
    when tag is GitTag:
      tag.free
      obj.free
    elif tag is string:
      obj.free
    elif tag is GitThing:
      let
        same = tag == obj
      tag.free
      # make sure we don't free the same object twice
      if not same:
        obj.free
  table.clear

proc hash*(tag: GitTag): Hash =
  var h: Hash = 0
  h = h !& hash($tag)
  result = !$h

proc hash*(thing: GitThing): Hash =
  var h: Hash = 0
  h = h !& hash($thing.oid)
  result = !$h

proc kind(obj: GitObject): GitObjectKind =
  let
    typeName = $(git_object_type(obj).git_object_type2string)
  result = parseEnum[GitObjectKind](typeName)

proc newThing(obj: GitObject): GitThing =
  try:
    result = GitThing(kind: obj.kind, o: obj)
  except:
    result = GitThing(kind: goAny, o: obj)

proc clone*(got: var GitClone; uri: Uri; path: string; branch = ""): int =
  ## clone a repository
  got.options = cast[ptr git_clone_options](sizeof(git_clone_options).alloc)
  result = git_clone_init_options(got.options, GIT_CLONE_OPTIONS_VERSION)
  if result != 0:
    return

  got.options.checkout_branch = branch
  got.url = $uri
  got.directory = path

  result = git_clone(addr got.repo, got.url, got.directory, got.options)

proc repositoryHead*(tag: var GitReference; repo: GitRepository): int =
  ## get the reference that points to HEAD
  result = git_repository_head(addr tag, repo)

proc headReference*(repo: GitRepository; tag: var GitReference): int =
  ## get the reference that points to HEAD
  result = repositoryHead(tag, repo)

proc openRepository*(got: var GitOpen; path: string): int =
  got.path = path
  result = git_repository_open(addr got.repo, got.path)

proc remoteLookup*(remote: var GitRemote; repo: GitRepository;
                   name: string): int =
  ## get the remote by name
  result = git_remote_lookup(addr remote, repo, name)

proc url*(remote: GitRemote): Uri =
  ## retrieve the url of a remote
  result = parseUri($git_remote_url(remote))

proc `==`*(a, b: GitOid): bool =
  result = 1 == git_oid_equal(a, b)

proc targetId*(thing: GitThing): GitOid =
  result = git_tag_target_id(cast[GitTag](thing.o))

proc target*(thing: GitThing; target: var GitThing): int =
  var
    obj: GitObject

  result = git_tag_target(addr obj, cast[GitTag](thing.o))
  if result != 0:
    return
  target = newThing(obj)

proc tagList*(repo: GitRepository; tags: var seq[string]): int =
  ## retrieve a list of tags from the repo
  var
    list: git_strarray
  result = git_tag_list(addr list, repo)
  if list.count > 0:
    tags = cstringArrayToSeq(cast[cstringArray](list.strings), list.count)
  git_strarray_free(addr list)

proc tagTable*(repo: GitRepository; tags: var GitTagTable): int =
  ## compose a table of tags and their associated references
  var
    names: seq[string]

  tags = newOrderedTable[string, GitThing](32)

  result = tagList(repo, names)
  if result != 0:
    return

  for name in names.items:
    var
      obj: GitObject
      target: GitThing
    result = git_revparse_single(addr obj, repo, name)
    if result != 0:
      warn "tag lookup fail"
      return

    let
      thing = newThing(obj)
    if thing.kind == goTag:
      let tag = cast[GitTag](thing.o)
      debug "msg:", tag.message.strip
      result = thing.target(target)
      if result != 0:
        warn "target lookup fail"
        return
    else:
      target = thing
    debug name, "=>", $target
    tags.add name, target
