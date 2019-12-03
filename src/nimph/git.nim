import std/strformat
import std/bitops
import std/os
import std/strutils
import std/hashes
import std/tables
import std/uri

import nimgit2

when git2SetVer == "master":
  discard
elif git2SetVer == "0.28.3":
  discard
else:
  {.error: "libgit2 version " & git2SetVer & " unsupported".}

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
    GitRepoState* = enum
      rsNone                  = (GIT_REPOSITORY_STATE_NONE, "none")
      rsMerge                 = (GIT_REPOSITORY_STATE_MERGE, "merge")
      rsRevert                = (GIT_REPOSITORY_STATE_REVERT, "revert")
      rsRevertSequence        = (GIT_REPOSITORY_STATE_REVERT_SEQUENCE,
                                 "revert sequence")
      rsCherrypick            = (GIT_REPOSITORY_STATE_CHERRYPICK, "cherrypick")
      rsCherrypickSequence    = (GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE,
                                 "cherrypick sequence")
      rsBisect                = (GIT_REPOSITORY_STATE_BISECT, "bisect")
      rsRebase                = (GIT_REPOSITORY_STATE_REBASE, "rebase")
      rsRebaseInteractive     = (GIT_REPOSITORY_STATE_REBASE_INTERACTIVE,
                                 "rebase interactive")
      rsRebaseMerge           = (GIT_REPOSITORY_STATE_REBASE_MERGE,
                                 "rebase merge")
      rsApplyMailbox          = (GIT_REPOSITORY_STATE_APPLY_MAILBOX,
                                 "apply mailbox")
      rsApplyMailboxOrRebase  = (GIT_REPOSITORY_STATE_APPLY_MAILBOX_OR_REBASE,
                                 "apply mailbox or rebase")
    GitStatusShow* = enum
      ssIndexAndWorkdir       = (GIT_STATUS_SHOW_INDEX_AND_WORKDIR,
                                 "index and workdir")
      ssIndexOnly             = (GIT_STATUS_SHOW_INDEX_ONLY,
                                 "index only")
      ssWorkdirOnly           = (GIT_STATUS_SHOW_WORKDIR_ONLY,
                                 "workdir only")
    GitStatusOption* = enum
      soIncludeUntracked      = (GIT_STATUS_OPT_INCLUDE_UNTRACKED,
                                 "include untracked")
      soIncludeIgnored        = (GIT_STATUS_OPT_INCLUDE_IGNORED,
                                 "include ignored")
      soIncludeUnmodified     = (GIT_STATUS_OPT_INCLUDE_UNMODIFIED,
                                 "include unmodified")
      soExcludeSubmodules     = (GIT_STATUS_OPT_EXCLUDE_SUBMODULES,
                                 "exclude submodules")
      soRecurseUntrackedDirs  = (GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS,
                                 "recurse untracked dirs")
      soDisablePathspecMatch  = (GIT_STATUS_OPT_DISABLE_PATHSPEC_MATCH,
                                 "disable pathspec match")
      soRecurseIgnoredDirs    = (GIT_STATUS_OPT_RECURSE_IGNORED_DIRS,
                                 "recurse ignored dirs")
      soRenamesHeadToIndex    = (GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX,
                                 "renames head to index")
      soRenamesIndexToWorkdir = (GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR,
                                 "renames index to workdir")
      soSortCaseSensitively   = (GIT_STATUS_OPT_SORT_CASE_SENSITIVELY,
                                 "sort case sensitively")
      soSortCaseInsensitively = (GIT_STATUS_OPT_SORT_CASE_INSENSITIVELY,
                                 "sort case insensitively")
      soRenamesFromRewrites   = (GIT_STATUS_OPT_RENAMES_FROM_REWRITES,
                                 "renames from rewrites")
      soNoRefresh             = (GIT_STATUS_OPT_NO_REFRESH,
                                 "no refresh")
      soUpdateIndex           = (GIT_STATUS_OPT_UPDATE_INDEX,
                                 "update index")
      soIncludeUnreadable     = (GIT_STATUS_OPT_INCLUDE_UNREADABLE,
                                 "include unreadable")

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
                git_strarray | git_object | git_commit | git_status_list
  NimHeapGits = git_clone_options | git_status_options
  GitOid* = ptr git_oid
  GitRemote* = ptr git_remote
  GitReference* = ptr git_reference
  GitRepository* = ptr git_repository
  GitStrArray* = ptr git_strarray
  GitTag* = ptr git_tag
  GitCommit* = ptr git_commit
  GitClone* = object
    url*: cstring
    directory*: cstring
    repo*: GitRepository
    options*: ptr git_clone_options
  GitOpen* = object
    path*: cstring
    repo*: GitRepository
  GitTagTable* = OrderedTableRef[string, GitThing]
  GitStatus* = ptr git_status_entry

const
  CommonDefaultStatusFlags: set[GitStatusOption] = {
    soIncludeUntracked,
    soIncludeIgnored,
    soIncludeUnmodified,
    soExcludeSubmodules,
    soDisablePathspecMatch,
    soRenamesHeadToIndex,
    soRenamesIndexToWorkdir,
    soRenamesFromRewrites,
    soUpdateIndex,
    soIncludeUnreadable,
  }

  DefaultStatusFlags* =
    when FileSystemCaseSensitive:
      CommonDefaultStatusFlags + {soSortCaseSensitively}
    else:
      CommonDefaultStatusFlags + {soSortCaseInsensitively}

template dumpError() =
  let err = git_error_last()
  if err != nil:
    error $err.message

template gitFail*(allocd: typed; code: int; body: untyped) =
  ## a version of gitTrap that expects failure; no error messages!
  defer:
    if code == 0:
      free(allocd)
  if code != 0:
    body

template gitTrap*(allocd: typed; code: int; body: untyped) =
  ## trap a git call, freeing the alloc'd argument if it succeeds
  gitFail(allocd, code):
    dumpError()
    body

template gitTrap*(code: int; body: untyped) =
  if code != 0:
    dumpError()
    body

proc init*(): bool =
  let count = git_libgit2_init()
  result = count > 0
  when defined(debugGit):
    debug "open gits:", count

proc shutdown*(): bool =
  let count = git_libgit2_shutdown()
  result = count >= 0
  when defined(debugGit):
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
    elif T is git_commit:
      git_commit_free(point)
    elif T is git_object:
      git_object_free(point)
    elif T is git_status_list:
      git_status_list_free(point)
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

proc short*(oid: GitOid; size: int): string =
  var
    output: cstring
  output = cast[cstring](alloc(size + 1))
  output[size] = '\0'
  git_oid_nfmt(output, size.uint, oid)
  result = $output
  dealloc(output)

proc `$`*(got: GitOid): string =
  result = $git_oid_tostr_s(got)

proc `$`*(tag: GitTag): string =
  assert tag != nil
  let
    name = git_tag_name(tag)
  if name != nil:
    result = $name

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
#
proc message*(commit: GitCommit): string =
  result = $git_commit_message(commit)

proc message*(tag: GitTag): string =
  result = $git_tag_message(tag)

proc message*(thing: GitThing): string =
  case thing.kind:
  of goTag:
    result = cast[GitTag](thing.o).message
  of goCommit:
    result = cast[GitCommit](thing.o).message
  else:
    raise newException(ValueError, "dunno how to get a message: " & $thing)

proc summary*(commit: GitCommit): string =
  result = $git_commit_summary(commit)

proc summary*(thing: GitThing): string =
  case thing.kind:
  of goTag:
    result = cast[GitTag](thing.o).message
  of goCommit:
    result = cast[GitCommit](thing.o).summary
  else:
    raise newException(ValueError, "dunno how to get a summary: " & $thing)
  result = result.strip

proc free*(table: var GitTagTable) =
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
  when git2SetVer == "master":
    result = git_clone_options_init(got.options, GIT_CLONE_OPTIONS_VERSION)
  else:
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

proc remoteRename*(repo: GitRepository; prior: string; next: string): int =
  ## rename a remote
  var
    list: git_strarray
  result = git_remote_rename(addr list, repo, prior, next)
  if list.count > 0'u:
    let problems = cstringArrayToSeq(cast[cstringArray](list.strings),
                                     list.count)
    for problem in problems.items:
      warn problem
  git_strarray_free(addr list)

proc remoteCreate*(remote: var GitRemote; repo: GitRepository;
                   name: string; url: Uri): int =
  ## create a new remote in the repository
  result = git_remote_create(addr remote, repo, name, $url)

proc url*(remote: GitRemote): Uri =
  ## retrieve the url of a remote
  result = parseUri($git_remote_url(remote)).normalizeUrl

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
  if list.count > 0'u:
    tags = cstringArrayToSeq(cast[cstringArray](list.strings), list.count)
  git_strarray_free(addr list)

proc lookupThing*(thing: var GitThing; repo: GitRepository; name: string): int =
  var
    obj: GitObject
  result = git_revparse_single(addr obj, repo, name)
  if result != 0:
    return
  thing = newThing(obj)

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
      thing, target: GitThing
    result = lookupThing(thing, repo, name)
    if result != 0:
      return

    if thing.kind == goTag:
      result = thing.target(target)
      free(thing)
      if result != 0:
        return
    else:
      target = thing
    tags.add name, target

proc getHeadOid*(repository: GitRepository): GitOid =
  var
    head: GitReference
  gitTrap head, repositoryHead(head, repository):
    warn "error fetching repo head"
    return
  result = head.oid

proc repositoryState*(repository: GitRepository): GitRepoState =
  result = cast[GitRepoState](git_repository_state(repository))

proc repositoryState*(path: string): GitRepoState =
  var
    open: GitOpen
  withGit:
    gitTrap open, openRepository(open, path):
      let emsg = &"error opening repository {path}"
      raise newException(IOError, emsg)
    result = repositoryState(open.repo)

when git2SetVer == "master":
  iterator status*(repository: GitRepository; show: GitStatusShow;
                   flags = DefaultStatusFlags): GitStatus =
    ## iterate over files in the repo using the given search flags
    var
      statum: ptr git_status_list
      options: ptr git_status_options = cast[ptr git_status_options](sizeof(git_status_options).alloc)
    block:
      if 0 != git_status_options_init(options, GIT_STATUS_OPTIONS_VERSION):
        break

      options.show = cast[git_status_show_t](show)
      for flag in flags.items:
        options.flags = bitand(options.flags, flag.ord.cuint)

      if 0 != git_status_list_new(addr statum, repository, options):
        break

      let
        count = git_status_list_entrycount(statum)
      for index in 0 ..< count:
        yield git_status_byindex(statum, index.cuint)
    free(options)
    free(statum)
elif git2SetVer == "0.28.3":
  iterator status*(repository: GitRepository; show: GitStatusShow;
                   flags = DefaultStatusFlags): GitStatus =
    raise newException(ValueError, "you need a newer libgit2 to do that")
