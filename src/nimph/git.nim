import std/sets
import std/options
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
elif git2SetVer == "v0.28.3":
  discard
else:
  {.error: "libgit2 version `" & git2SetVer & "` unsupported".}

{.hint: "libgit2 version `" & git2SetVer & "`".}

import nimph/spec

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

  GitCheckoutStrategy* = enum
    gcsNone                      = (GIT_CHECKOUT_NONE,
                                    "dry run")
    gcsSafe                      = (GIT_CHECKOUT_SAFE,
                                    "safe")
    gcsForce                     = (GIT_CHECKOUT_FORCE,
                                    "force")
    gcsRecreateMissing           = (GIT_CHECKOUT_RECREATE_MISSING,
                                    "recreate missing")
    gcsAllowConflicts            = (GIT_CHECKOUT_ALLOW_CONFLICTS,
                                    "allow conflicts")
    gcsRemoveUntracked           = (GIT_CHECKOUT_REMOVE_UNTRACKED,
                                    "remove untracked")
    gcsRemoveIgnored             = (GIT_CHECKOUT_REMOVE_IGNORED,
                                    "remove ignored")
    gcsUpdateOnly                = (GIT_CHECKOUT_UPDATE_ONLY,
                                    "update only")
    gcsDontUpdateIndex           = (GIT_CHECKOUT_DONT_UPDATE_INDEX,
                                    "don't update index")
    gcsNoRefresh                 = (GIT_CHECKOUT_NO_REFRESH,
                                    "no refresh")
    gcsSkipUnmerged              = (GIT_CHECKOUT_SKIP_UNMERGED,
                                    "skip unmerged")
    gcsUseOurs                   = (GIT_CHECKOUT_USE_OURS,
                                    "use ours")
    gcsUseTheirs                 = (GIT_CHECKOUT_USE_THEIRS,
                                    "use theirs")
    gcsDisablePathspecMatch      = (GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH,
                                    "disable pathspec match")
    # this space intentionally left blank
    gcsUpdateSubmodules          = (GIT_CHECKOUT_UPDATE_SUBMODULES,
                                    "update submodules")
    gcsUpdateSubmodulesIfChanged = (GIT_CHECKOUT_UPDATE_SUBMODULES_IF_CHANGED,
                                    "update submodules if changed")
    gcsSkipLockedDirectories     = (GIT_CHECKOUT_SKIP_LOCKED_DIRECTORIES,
                                    "skip locked directories")
    gcsDontOverwriteIgnored      = (GIT_CHECKOUT_DONT_OVERWRITE_IGNORED,
                                    "don't overwrite ignored")
    gcsConflictStyleMerge        = (GIT_CHECKOUT_CONFLICT_STYLE_MERGE,
                                    "conflict style merge")
    gcsConflictStyleDiff3        = (GIT_CHECKOUT_CONFLICT_STYLE_DIFF3,
                                    "conflict style diff3")
    gcsDontRemoveExisting        = (GIT_CHECKOUT_DONT_REMOVE_EXISTING,
                                    "don't remove existing")
    gcsDontWriteIndex            = (GIT_CHECKOUT_DONT_WRITE_INDEX,
                                    "don't write index")

  GitCheckoutNotify* = enum
    gcnNone            = (GIT_CHECKOUT_NOTIFY_NONE, "none")
    gcnConflict        = (GIT_CHECKOUT_NOTIFY_CONFLICT, "conflict")
    gcnDirty           = (GIT_CHECKOUT_NOTIFY_DIRTY, "dirty")
    gcnUpdated         = (GIT_CHECKOUT_NOTIFY_UPDATED, "updated")
    gcnUntracked       = (GIT_CHECKOUT_NOTIFY_UNTRACKED, "untracked")
    gcnIgnored         = (GIT_CHECKOUT_NOTIFY_IGNORED, "ignored")
    gcnAll             = (GIT_CHECKOUT_NOTIFY_ALL, "all")

  GitResultCode* = enum
    grcOk              = (-1 * GIT_OK, "ok")
    grcError           = (-1 * GIT_ERROR, "generic error")
    # this space intentionally left blank
    grcNotFound        = (-1 * GIT_ENOTFOUND, "not found")
    grcExists          = (-1 * GIT_EEXISTS, "object exists")
    grcAmbiguous       = (-1 * GIT_EAMBIGUOUS, "ambiguous match")
    grcBuffer          = (-1 * GIT_EBUFS, "buffer overflow")
    grcUser            = (-1 * GIT_EUSER, "user-specified")
    grcBareRepo        = (-1 * GIT_EBAREREPO, "bare repository")
    grcUnbornBranch    = (-1 * GIT_EUNBORNBRANCH, "unborn branch")
    grcUnmerged        = (-1 * GIT_EUNMERGED, "unmerged")
    grcNonFastForward  = (-1 * GIT_ENONFASTFORWARD, "not fast-forward")
    grcInvalidSpec     = (-1 * GIT_EINVALIDSPEC, "invalid spec")
    grcConflict        = (-1 * GIT_ECONFLICT, "conflict")
    grcLocked          = (-1 * GIT_ELOCKED, "locked")
    grcModified        = (-1 * GIT_EMODIFIED, "modified")
    grcAuthentication  = (-1 * GIT_EAUTH, "authentication")
    grcCertificate     = (-1 * GIT_ECERTIFICATE, "certificate")
    grcApplied         = (-1 * GIT_EAPPLIED, "applied")
    grcPeel            = (-1 * GIT_EPEEL, "peel")
    grcEndOfFile       = (-1 * GIT_EEOF, "end-of-file")
    grcInvalid         = (-1 * GIT_EINVALID, "invalid")
    grcUncommitted     = (-1 * GIT_EUNCOMMITTED, "uncommitted")
    grcDirectory       = (-1 * GIT_EDIRECTORY, "directory")
    grcMergeConflict   = (-1 * GIT_EMERGE_CONFLICT, "merge conflict")
    # this space intentionally left blank
    grcPassThrough     = (-1 * GIT_PASSTHROUGH, "pass-through")
    grcIterOver        = (-1 * GIT_ITEROVER, "end of iteration")
    grcRetry           = (-1 * GIT_RETRY, "retry")
    grcMismatch        = (-1 * GIT_EMISMATCH, "hash mismatch")
    grcIndexDirty      = (-1 * GIT_EINDEXDIRTY, "dirty index")
    grcApplyFail       = (-1 * GIT_EAPPLYFAIL, "patch failed")

  GitErrorClass* = enum
    gecNone        = (GIT_ERROR_NONE, "none")
    gecNoMemory    = (GIT_ERROR_NOMEMORY, "no memory")
    gecOS          = (GIT_ERROR_OS, "os")
    gecInvalid     = (GIT_ERROR_INVALID, "invalid")
    gecReference   = (GIT_ERROR_REFERENCE, "reference")
    gecZlib        = (GIT_ERROR_ZLIB, "zlib")
    gecRepository  = (GIT_ERROR_REPOSITORY, "repository")
    gecConfig      = (GIT_ERROR_CONFIG, "config")
    gecRegEx       = (GIT_ERROR_REGEX, "regex")
    gecODB         = (GIT_ERROR_ODB, "odb")
    gecIndex       = (GIT_ERROR_INDEX, "index")
    gecObject      = (GIT_ERROR_OBJECT, "object")
    gecNet         = (GIT_ERROR_NET, "network")
    gecTag         = (GIT_ERROR_TAG, "tag")
    gecTree        = (GIT_ERROR_TREE, "tree")
    gecIndexer     = (GIT_ERROR_INDEXER, "indexer")
    gecSSL         = (GIT_ERROR_SSL, "ssl")
    gecSubModule   = (GIT_ERROR_SUBMODULE, "submodule")
    gecThread      = (GIT_ERROR_THREAD, "thread")
    gecStash       = (GIT_ERROR_STASH, "stash")
    gecCheckOut    = (GIT_ERROR_CHECKOUT, "check out")
    gecFetchHead   = (GIT_ERROR_FETCHHEAD, "fetch head")
    gecMerge       = (GIT_ERROR_MERGE, "merge")
    gecSSH         = (GIT_ERROR_SSH, "ssh")
    gecFilter      = (GIT_ERROR_FILTER, "filter")
    gecRevert      = (GIT_ERROR_REVERT, "revert")
    gecCallBack    = (GIT_ERROR_CALLBACK, "call back")
    gecCherryPick  = (GIT_ERROR_CHERRYPICK, "cherry pick")
    gecDescribe    = (GIT_ERROR_DESCRIBE, "describe")
    gecReBase      = (GIT_ERROR_REBASE, "re-base")
    gecFileSystem  = (GIT_ERROR_FILESYSTEM, "filesystem")
    gecPatch       = (GIT_ERROR_PATCH, "patch")
    gecWorkTree    = (GIT_ERROR_WORKTREE, "work tree")
    gecSHA1        = (GIT_ERROR_SHA1, "sha1")

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

  GitHeapGits = git_repository | git_reference | git_remote | git_tag |
                git_strarray | git_object | git_commit | git_status_list |
                git_annotated_commit
  NimHeapGits = git_clone_options | git_status_options | git_checkout_options |
                git_oid
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
  GitStatusList* = ptr git_status_list

proc grc(code: cint): GitResultCode =
  result = cast[GitResultCode](ord(-1 * code))

proc gec(code: int): GitErrorClass =
  result = cast[GitErrorClass](code.ord)

proc hash*(gcs: GitCheckoutStrategy): Hash = gcs.ord.hash

const
  defaultCheckoutStrategy = [
    gcsSafe,
    gcsRecreateMissing,
    gcsSkipLockedDirectories,
    gcsDontOverwriteIgnored,
  ].toHashSet
  commonDefaultStatusFlags: set[GitStatusOption] = {
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

  defaultStatusFlags* =
    when FileSystemCaseSensitive:
      commonDefaultStatusFlags + {soSortCaseSensitively}
    else:
      commonDefaultStatusFlags + {soSortCaseInsensitively}

template dumpError() =
  let err = git_error_last()
  if err != nil:
    error $gec(err.klass) & " error: " & $err.message

template gitFail*(allocd: typed; code: untyped; body: untyped) =
  ## a version of gitTrap that expects failure; no error messages!
  block:
    defer:
      if code == grcOk:
        free(allocd)
    if code != grcOk:
      body

template gitFail*(allocd: typed; code: untyped; body: untyped) =
  ## a version of gitTrap that expects failure; no error messages!
  defer:
    if code == grcOk:
      free(allocd)
  if code != grcOk:
    body

template gitTrap*(allocd: typed; code: untyped; body: untyped) =
  ## a version of gitTrap that expects failure; no error messages!
  defer:
    if code == grcOk:
      free(allocd)
  if code != grcOk:
    dumpError()
    body

template gitTrap*(code: GitResultCode; body: untyped) =
  if code != grcOk:
    dumpError()
    body

template gitFail*(code: GitResultCode; body: untyped) =
  var code: GitResultCode = code
  if code != grcOk:
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

template withGit(body: untyped) =
  once:
    if not init():
      raise newException(OSError, "unable to init git")
  when false:
    defer:
      if not shutdown():
        raise newException(OSError, "unable to shut git")
  body

template withGitRepoAt(path: string; body: untyped) =
  withGit:
    var open: GitOpen
    gitTrap open, openRepository(open, path):
      var code: GitResultCode
      error &"error opening repository {path}"
      result = code
    var repo {.inject.} = open.repo
    body

template demandGitRepoAt(path: string; body: untyped) =
  withGit:
    var open: GitOpen
    gitTrap open, openRepository(open, path):
      var code: GitResultCode
      let emsg = &"error opening repository {path}"
      raise newException(IOError, emsg)
    var repo {.inject.} = open.repo
    body

proc free*[T: GitHeapGits](point: ptr T) =
  withGit:
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
      elif T is git_annotated_commit:
        git_annotated_commit_free(point)
      else:
        {.error: "missing a free definition".}

proc free*[T: NimHeapGits](point: ptr T) =
  if point != nil:
    dealloc(point)

proc free*(clone: GitClone) =
  withGit:
    free(clone.repo)
    free(clone.options)

proc free*(opened: GitOpen) =
  withGit:
    free(opened.repo)

proc free*(thing: GitThing) =
  withGit:
    free(thing.o)

proc short*(oid: GitOid; size: int): string =
  var
    output: cstring
  withGit:
    output = cast[cstring](alloc(size + 1))
    output[size] = '\0'
    git_oid_nfmt(output, size.uint, oid)
    result = $output
    dealloc(output)

proc `$`*(got: GitOid): string =
  withGit:
    result = $git_oid_tostr_s(got)

proc `$`*(tag: GitTag): string =
  withGit:
    assert tag != nil
    let
      name = git_tag_name(tag)
    if name != nil:
      result = $name

proc oid*(got: GitReference): GitOid =
  withGit:
    result = git_reference_target(got)

proc oid*(obj: GitObject): GitOid =
  withGit:
    result = git_object_id(obj)

proc oid*(thing: GitThing): GitOid =
  result = thing.o.oid

proc oid*(tag: GitTag): GitOid =
  withGit:
    result = git_tag_id(tag)

proc name*(got: GitReference): string =
  withGit:
    result = $git_reference_name(got)

proc isTag*(got: GitReference): bool =
  withGit:
    result = git_reference_is_tag(got) == 1

proc `$`*(reference: GitReference): string =
  if reference.isTag:
    result = reference.name
  else:
    result = $reference.oid

proc `$`*(obj: GitObject): string =
  withGit:
    result = $(git_object_type(obj).git_object_type2string)
    result &= "-" & $obj.git_object_id

proc `$`*(thing: GitThing): string =
  result = $thing.o
#  case thing.kind:
#  of goTag:
#  else:
#
proc message*(commit: GitCommit): string =
  withGit:
    result = $git_commit_message(commit)

proc message*(tag: GitTag): string =
  withGit:
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
  ## produce a summary for a given commit
  withGit:
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
  ## free a tag table
  withGit:
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
  withGit:
    let
      typeName = $(git_object_type(obj).git_object_type2string)
    result = parseEnum[GitObjectKind](typeName)

proc newThing(obj: GitObject): GitThing =
  try:
    result = GitThing(kind: obj.kind, o: obj)
  except:
    result = GitThing(kind: goAny, o: obj)

proc clone*(got: var GitClone; uri: Uri; path: string;
            branch = ""): GitResultCode =
  ## clone a repository
  got.options = cast[ptr git_clone_options](sizeof(git_clone_options).alloc)
  defer:
    got.options.free
  withGit:
    when git2SetVer == "master":
      result = git_clone_options_init(got.options, GIT_CLONE_OPTIONS_VERSION).grc
    else:
      result = git_clone_init_options(got.options, GIT_CLONE_OPTIONS_VERSION).grc
    if result != grcOk:
      return

    if branch != "":
      got.options.checkout_branch = branch
    got.url = $uri
    got.directory = path

  result = git_clone(addr got.repo, got.url, got.directory, got.options).grc

proc headReference*(repo: GitRepository; tag: var GitReference): GitResultCode =
  ## get the reference that points to HEAD
  withGit:
    result = git_repository_head(addr tag, repo).grc

proc setHeadDetached*(repo: GitRepository; oid: GitOid): GitResultCode =
  ## detach the HEAD and point it at the given OID
  withGit:
    result = git_repository_set_head_detached(repo, oid).grc

proc setHeadDetached*(repo: GitRepository; reference: string): GitResultCode =
  ## point the repo's head at the given reference
  var
    oid: ptr git_oid = cast[ptr git_oid](sizeof(git_oid).alloc)
  defer:
    oid.free
  withGit:
    result = git_oid_fromstr(oid, reference).grc
    if result == grcOk:
      result = repo.setHeadDetached(oid)

proc openRepository*(got: var GitOpen; path: string): GitResultCode =
  ## open a repository by path
  got.path = path
  withGit:
    result = git_repository_open(addr got.repo, got.path).grc

proc remoteLookup*(remote: var GitRemote; repo: GitRepository;
                   name: string): GitResultCode =
  ## get the remote by name
  withGit:
    result = git_remote_lookup(addr remote, repo, name).grc

proc remoteLookup*(remote: var GitRemote; path: string;
                   name: string): GitResultCode =
  ## get the remote by name using a repository path
  withGitRepoAt(path):
    result = remoteLookup(remote, repo, name)

proc remoteRename*(repo: GitRepository; prior: string; next: string): GitResultCode =
  ## rename a remote
  var
    list: git_strarray
  withGit:
    result = git_remote_rename(addr list, repo, prior, next).grc
    if result == grcOk:
      defer:
        git_strarray_free(addr list)
      if list.count > 0'u:
        let problems = cstringArrayToSeq(cast[cstringArray](list.strings),
                                         list.count)
        for problem in problems.items:
          warn problem

proc remoteRename*(path: string; prior: string; next: string): GitResultCode =
  ## rename a remote in the repository at the given path
  withGitRepoAt(path):
    result = remoteRename(repo, prior, next)

proc remoteDelete*(repo: GitRepository; name: string): GitResultCode =
  ## delete a remote from the repository
  withGit:
    result = git_remote_delete(repo, name).grc

proc remoteDelete*(path: string; name: string): GitResultCode =
  ## delete a remote from the repository at the given path
  withGitRepoAt(path):
    result = remoteDelete(repo, name)

proc remoteCreate*(remote: var GitRemote; repo: GitRepository;
                   name: string; url: Uri): GitResultCode =
  ## create a new remote in the repository
  withGit:
    result = git_remote_create(addr remote, repo, name, $url).grc

proc remoteCreate*(remote: var GitRemote; path: string;
                   name: string; url: Uri): GitResultCode =
  ## create a new remote in the repository at the given path
  withGitRepoAt(path):
    result = remoteCreate(remote, repo, name, url)

proc url*(remote: GitRemote): Uri =
  ## retrieve the url of a remote
  withGit:
    result = parseUri($git_remote_url(remote)).normalizeUrl

proc `==`*(a, b: GitOid): bool =
  withGit:
    result = 1 == git_oid_equal(a, b)

proc targetId*(thing: GitThing): GitOid =
  withGit:
    result = git_tag_target_id(cast[GitTag](thing.o))

proc target*(thing: GitThing; target: var GitThing): GitResultCode =
  var
    obj: GitObject
  withGit:
    result = git_tag_target(addr obj, cast[GitTag](thing.o)).grc
    if result == grcOk:
      target = newThing(obj)

proc tagList*(repo: GitRepository; tags: var seq[string]): GitResultCode =
  ## retrieve a list of tags from the repo
  var
    list: git_strarray
  withGit:
    result = git_tag_list(addr list, repo).grc
    if result == grcOk:
      defer:
        git_strarray_free(addr list)
      if list.count > 0'u:
        tags = cstringArrayToSeq(cast[cstringArray](list.strings), list.count)

proc lookupThing*(thing: var GitThing; repo: GitRepository; name: string): GitResultCode =
  ## try to look some thing up in the repository with the given name
  var
    obj: GitObject
  withGit:
    result = git_revparse_single(addr obj, repo, name).grc
    if result == grcOk:
      thing = newThing(obj)

proc lookupThing*(thing: var GitThing; path: string; name: string): GitResultCode =
  ## try to look some thing up in the repository at the given path
  withGitRepoAt(path):
    result = lookupThing(thing, repo, name)

proc tagTable*(repo: GitRepository; tags: var GitTagTable): GitResultCode =
  ## compose a table of tags and their associated references
  var
    names: seq[string]

  tags = newOrderedTable[string, GitThing](32)

  result = tagList(repo, names)
  if result != grcOk:
    return

  for name in names.items:
    var
      thing, target: GitThing
    result = lookupThing(thing, repo, name)
    if result != grcOk:
      debug &"failed lookup for `{name}`"
      return

    if thing.kind != goTag:
      target = thing
    else:
      result = thing.target(target)
      free(thing)
      if result != grcOk:
        debug &"failed target for `{name}`"
        return
    tags.add name, target

proc tagTable*(path: string; tags: var GitTagTable): GitResultCode =
  ## compose a table of tags and their associated references
  withGitRepoAt(path):
    result = repo.tagTable(tags)

proc shortestTag*(table: GitTagTable; oid: string): string =
  ## pick the shortest tag that matches the oid supplied
  for name, thing in table.pairs:
    if $thing.oid != oid:
      continue
    if result == "" or name.len < result.len:
      result = name
  if result == "":
    result = oid

proc getHeadOid*(repository: GitRepository): Option[GitOid] =
  ## try to retrieve the #head oid from a repository
  var
    head: GitReference
  withGit:
    gitFail head, repository.headReference(head):
      var code: GitResultCode
      case code:
      of grcOk, grcNotFound:
        discard
      else:
        dumpError()
      return
    result = head.oid.some

proc getHeadOid*(path: string): Option[GitOid] =
  ## try to retrieve the #head oid from a repository at the given path
  demandGitRepoAt(path):
    result = repo.getHeadOid

proc repositoryState*(repository: GitRepository): GitRepoState =
  ## fetch the state of a repository
  withGit:
    result = cast[GitRepoState](git_repository_state(repository))

proc repositoryState*(path: string): GitRepoState =
  ## fetch the state of the repository at the given path
  demandGitRepoAt(path):
    result = repositoryState(repo)

when git2SetVer == "master":
  iterator status*(repository: GitRepository; show: GitStatusShow;
                   flags = defaultStatusFlags): GitStatus =
    ## iterate over files in the repo using the given search flags
    withGit:
      var
        statum: GitStatusList
        options: ptr git_status_options = cast[ptr git_status_options](sizeof(git_status_options).alloc)
      block:
        if grcOk != git_status_options_init(options, GIT_STATUS_OPTIONS_VERSION).grc:
          break

        options.show = cast[git_status_show_t](show)
        for flag in flags.items:
          options.flags = bitand(options.flags, flag.ord.cuint)

        if grcOk != git_status_list_new(addr statum, repository, options).grc:
          break

        let
          count = git_status_list_entrycount(statum)
        for index in 0 ..< count:
          yield git_status_byindex(statum, index.cuint)
      free(options)
      free(statum)
else:
  iterator status*(repository: GitRepository; show: GitStatusShow;
                   flags = defaultStatusFlags): GitStatus =
    raise newException(ValueError, "you need a newer libgit2 to do that")

iterator status*(path: string; show = ssIndexAndWorkdir;
                 flags = defaultStatusFlags): GitStatus =
  ## for repository at path, yield status for each file which trips the flags
  demandGitRepoAt(path):
    for entry in status(repo, show, flags):
      yield entry

proc checkoutTree*(repo: GitRepository; thing: GitThing;
                   strategy = defaultCheckoutStrategy): GitResultCode =
  ## checkout a repository using a thing
  withGit:
    var
      options = cast[ptr git_checkout_options](sizeof(git_checkout_options).alloc)
      commit: ptr git_commit
      target: ptr git_annotated_commit
    defer:
      options.free

    block:
      # start with converting the thing to an annotated commit
      result = git_annotated_commit_lookup(addr target, repo, thing.oid).grc
      if result != grcOk:
        break
      defer:
        target.free

      # use the oid of this target to look up the commit
      let oid = git_annotated_commit_id(target)
      result = git_commit_lookup(addr commit, repo, oid).grc
      if result != grcOk:
        break
      defer:
        commit.free

      # setup our checkout options
      result = git_checkout_options_init(options,
                                         GIT_CHECKOUT_OPTIONS_VERSION).grc
      if result != grcOk:
        break

      # reset the strategy per flags
      options.checkout_strategy = 0
      for flag in strategy.items:
        options.checkout_strategy = bitand(options.checkout_strategy,
                                           flag.ord.cuint)

      # checkout the tree using the commit we fetched
      result = git_checkout_tree(repo, cast[GitObject](commit), options).grc
      if result != grcOk:
        break

      # get the commit ref name
      let name = git_annotated_commit_ref(target)
      if name.isNil:
        result = git_repository_set_head_detached_from_annotated(repo, target).grc
      else:
        result = git_repository_set_head(repo, name).grc

proc checkoutTree*(repo: GitRepository; reference: string;
                   strategy = defaultCheckoutStrategy): GitResultCode =
  ## checkout a repository using a reference string
  withGit:
    var
      thing: GitThing
    result = lookupThing(thing, repo, reference)
    defer:
      thing.free
    if result == grcOk:
      result = checkoutTree(repo, thing, strategy = strategy)

proc checkoutTree*(path: string; reference: string;
                   strategy = defaultCheckoutStrategy): GitResultCode =
  ## checkout a repository in the given path using a reference string
  withGitRepoAt(path):
    result = checkoutTree(repo, reference, strategy = strategy)
