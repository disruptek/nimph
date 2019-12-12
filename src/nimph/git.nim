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
  # separating out stuff we free via routines from libgit2
  GitHeapGits = git_repository | git_reference | git_remote | git_tag |
                git_strarray | git_object | git_commit | git_status_list |
                git_annotated_commit | git_tree_entry | git_revwalk

  # or stuff we alloc and pass to libgit2, and then free later ourselves
  NimHeapGits = git_clone_options | git_status_options | git_checkout_options |
                git_oid

  GitTreeWalkCallback* = proc (root: cstring; entry: ptr git_tree_entry;
                               payload: pointer): cint

  GitTreeWalkMode* = enum
    gtwPre  = (GIT_TREEWALK_PRE, "pre")
    gtwPost = (GIT_TREEWALK_POST, "post")

  GitRepoState* = enum
    rsNone                  = (GIT_REPOSITORY_STATE_NONE,
                               "none")
    rsMerge                 = (GIT_REPOSITORY_STATE_MERGE,
                               "merge")
    rsRevert                = (GIT_REPOSITORY_STATE_REVERT,
                               "revert")
    rsRevertSequence        = (GIT_REPOSITORY_STATE_REVERT_SEQUENCE,
                               "revert sequence")
    rsCherrypick            = (GIT_REPOSITORY_STATE_CHERRYPICK,
                               "cherrypick")
    rsCherrypickSequence    = (GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE,
                               "cherrypick sequence")
    rsBisect                = (GIT_REPOSITORY_STATE_BISECT,
                               "bisect")
    rsRebase                = (GIT_REPOSITORY_STATE_REBASE,
                               "rebase")
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

  GitStatusFlag* = enum
    gsfCurrent           = (GIT_STATUS_CURRENT, "current")
    # this space intentionally left blank
    gsfIndexNew          = (GIT_STATUS_INDEX_NEW, "index new")
    gsfIndexModified     = (GIT_STATUS_INDEX_MODIFIED, "index modified")
    gsfIndexDeleted      = (GIT_STATUS_INDEX_DELETED, "index deleted")
    gsfIndexRenamed      = (GIT_STATUS_INDEX_RENAMED, "index renamed")
    gsfIndexTypechange   = (GIT_STATUS_INDEX_TYPECHANGE, "index typechange")
    # this space intentionally left blank
    gsfTreeNew           = (GIT_STATUS_WT_NEW, "tree new")
    gsfTreeModified      = (GIT_STATUS_WT_MODIFIED, "tree modified")
    gsfTreeDeleted       = (GIT_STATUS_WT_DELETED, "tree deleted")
    gsfTreeTypechange    = (GIT_STATUS_WT_TYPECHANGE, "tree typechange")
    gsfTreeRenamed       = (GIT_STATUS_WT_RENAMED, "tree renamed")
    # this space intentionally left blank
    gsfIgnored           = (GIT_STATUS_IGNORED, "ignored")
    gsfConflicted        = (GIT_STATUS_CONFLICTED, "conflicted")

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
    grcApplyFail       = (GIT_EAPPLYFAIL, "patch failed")
    grcIndexDirty      = (GIT_EINDEXDIRTY, "dirty index")
    grcMismatch        = (GIT_EMISMATCH, "hash mismatch")
    grcRetry           = (GIT_RETRY, "retry")
    grcIterOver        = (GIT_ITEROVER, "end of iteration")
    grcPassThrough     = (GIT_PASSTHROUGH, "pass-through")
    # this space intentionally left blank
    grcMergeConflict   = (GIT_EMERGE_CONFLICT, "merge conflict")
    grcDirectory       = (GIT_EDIRECTORY, "directory")
    grcUncommitted     = (GIT_EUNCOMMITTED, "uncommitted")
    grcInvalid         = (GIT_EINVALID, "invalid")
    grcEndOfFile       = (GIT_EEOF, "end-of-file")
    grcPeel            = (GIT_EPEEL, "peel")
    grcApplied         = (GIT_EAPPLIED, "applied")
    grcCertificate     = (GIT_ECERTIFICATE, "certificate")
    grcAuthentication  = (GIT_EAUTH, "authentication")
    grcModified        = (GIT_EMODIFIED, "modified")
    grcLocked          = (GIT_ELOCKED, "locked")
    grcConflict        = (GIT_ECONFLICT, "conflict")
    grcInvalidSpec     = (GIT_EINVALIDSPEC, "invalid spec")
    grcNonFastForward  = (GIT_ENONFASTFORWARD, "not fast-forward")
    grcUnmerged        = (GIT_EUNMERGED, "unmerged")
    grcUnbornBranch    = (GIT_EUNBORNBRANCH, "unborn branch")
    grcBareRepo        = (GIT_EBAREREPO, "bare repository")
    grcUser            = (GIT_EUSER, "user-specified")
    grcBuffer          = (GIT_EBUFS, "buffer overflow")
    grcAmbiguous       = (GIT_EAMBIGUOUS, "ambiguous match")
    grcExists          = (GIT_EEXISTS, "object exists")
    grcNotFound        = (GIT_ENOTFOUND, "not found")
    # this space intentionally left blank
    grcError           = (GIT_ERROR, "generic error")
    grcOk              = (GIT_OK, "ok")

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

  GitObjectKind* = enum
    # we have to add 2 here to satisfy nim; discriminants.low must be zero
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
    of goTree:
      discard
    else:
      discard

  GitRevWalker* = ptr git_revwalk
  GitTreeEntry* = ptr git_tree_entry
  GitTreeEntries* = seq[GitTreeEntry]
  GitObject* = ptr git_object
  GitOid* = ptr git_oid
  GitOids* = seq[GitOid]
  GitRemote* = ptr git_remote
  GitReference* = ptr git_reference
  GitRepository* = ptr git_repository
  GitStrArray* = ptr git_strarray
  GitTag* = ptr git_tag
  GitCommit* = ptr git_commit
  GitStatus* = ptr git_status_entry
  GitStatusList* = ptr git_status_list
  GitTree* = ptr git_tree

  GitClone* = object
    url*: cstring
    directory*: cstring
    repo*: GitRepository
    options*: ptr git_clone_options

  GitOpen* = object
    path*: cstring
    repo*: GitRepository

  GitTagTable* = OrderedTableRef[string, GitThing]

proc grc(code: cint): GitResultCode =
  result = cast[GitResultCode](code.ord)

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

template gitFail*(allocd: typed; code: GitResultCode; body: untyped) =
  ## a version of gitTrap that expects failure; no error messages!
  defer:
    if code == grcOk:
      free(allocd)
  if code != grcOk:
    body

template gitFail*(allocd: typed; code: GitResultCode; body: untyped) =
  ## a version of gitTrap that expects failure; no error messages!
  defer:
    if code == grcOk:
      free(allocd)
  if code != grcOk:
    body

template gitTrap*(allocd: typed; code: GitResultCode; body: untyped) =
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
      when declaredInScope(result):
        when result is GitResultCode:
          var code: GitResultCode
          result = code
      error "error opening repository " & path
    var repo {.inject.} = open.repo
    body

template demandGitRepoAt(path: string; body: untyped) =
  withGit:
    var open: GitOpen
    gitTrap open, openRepository(open, path):
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
      elif T is git_tree:
        git_tree_free(point)
      elif T is git_tree_entry:
        git_tree_entry_free(point)
      elif T is git_revwalk:
        git_revwalk_free(point)
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

proc free*(entries: GitTreeEntries) =
  withGit:
    for entry in entries.items:
      free(entry)

proc short*(oid: GitOid; size: int): string =
  var
    output: cstring
  withGit:
    output = cast[cstring](alloc(size + 1))
    output[size] = '\0'
    git_oid_nfmt(output, size.uint, oid)
    result = $output
    dealloc(output)

proc `$`*(annotated: ptr git_annotated_commit): string =
  withGit:
    result = $git_annotated_commit_ref(annotated)

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

proc oid*(entry: GitTreeEntry): GitOid =
  withGit:
    result = git_tree_entry_id(entry)

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

proc name*(entry: GitTreeEntry): string =
  withGit:
    result = $git_tree_entry_name(entry)

proc isTag*(got: GitReference): bool =
  withGit:
    result = git_reference_is_tag(got) == 1

proc flags*(status: GitStatus): set[GitStatusFlag] =
  ## produce the set of flags indicating the status of the file
  for flag in GitStatusFlag.low .. GitStatusFlag.high:
    if flag.ord.uint == bitand(status.status.uint, flag.ord.uint):
      result.incl flag

proc `$`*(reference: GitReference): string =
  if reference.isTag:
    result = reference.name
  else:
    result = $reference.oid

proc `$`*(entry: GitTreeEntry): string =
  result = entry.name

proc `$`*(obj: GitObject): string =
  withGit:
    result = $(git_object_type(obj).git_object_type2string)
    result &= "-" & $obj.git_object_id

proc `$`*(thing: GitThing): string =
  result = $thing.o
#  case thing.kind:
#  of goTag:
#  else:

proc `$`*(status: GitStatus): string =
  for flag in status.flags.items:
    if result != "":
      result &= ","
    result &= $flag

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

proc `$`*(commit: GitCommit): string =
  result = $cast[GitObject](commit)

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
        options = cast[ptr git_status_options](sizeof(git_status_options).alloc)
      defer:
        options.free

      block:
        if grcOk != git_status_options_init(options,
                                            GIT_STATUS_OPTIONS_VERSION).grc:
          break

        options.show = cast[git_status_show_t](show)
        for flag in flags.items:
          options.flags = bitand(options.flags.uint, flag.ord.uint).cuint

        if grcOk != git_status_list_new(addr statum, repository, options).grc:
          break
        defer:
          statum.free

        let
          count = git_status_list_entrycount(statum)
        for index in 0 ..< count:
          yield git_status_byindex(statum, index.cuint)

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
        options.checkout_strategy = bitor(options.checkout_strategy.uint,
                                          flag.ord.uint).cuint

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
    if result == grcOk:
      defer:
        thing.free
      result = checkoutTree(repo, thing, strategy = strategy)

proc checkoutTree*(path: string; reference: string;
                   strategy = defaultCheckoutStrategy): GitResultCode =
  ## checkout a repository in the given path using a reference string
  withGitRepoAt(path):
    result = checkoutTree(repo, reference, strategy = strategy)

proc lookupTreeThing*(thing: var GitThing;
                      repo: GitRepository; path = "HEAD"): GitResultCode =
    result = thing.lookupThing(repo, path & "^{tree}")

proc lookupTreeThing*(thing: var GitThing;
                      repository: string; path = "HEAD"): GitResultCode =
  withGitRepoAt(repository):
    result = thing.lookupThing(repo, path & "^{tree}")

proc treeEntryByPath*(entry: var GitTreeEntry; thing: GitThing;
                      path: string): GitResultCode =
  ## get a tree entry using its path and that of the repo
  withGit:
    var
      leaf: GitTreeEntry
    # get the entry by path using the thing as a tree
    result = git_tree_entry_bypath(addr leaf, cast[GitTree](thing.o), path).grc
    if result == grcOk:
      defer:
        leaf.free
      # if it's okay, we have to make a copy of it that the user can free,
      # because when our thing is freed, it will invalidate the leaf var.
      result = git_tree_entry_dup(addr entry, leaf).grc

proc treeEntryByPath*(entry: var GitTreeEntry; repo: GitRepository;
                      path: string): GitResultCode =
  ## get a tree entry using its path and that of the repo
  withGit:
    var thing: GitThing
    result = thing.lookupTreeThing(repo, path = "HEAD")
    if result != grcOk:
      warn &"unable to lookup HEAD for {path}"
    else:
      defer: thing.free
      result = treeEntryByPath(entry, thing, path)

proc treeEntryByPath*(entry: var GitTreeEntry; at: string;
                      path: string): GitResultCode =
  ## get a tree entry using its path and that of the repo
  withGitRepoAt(at):
    result = treeEntryByPath(entry, repo, path)

proc treeEntryToThing*(thing: var GitThing; repo: GitRepository;
                       entry: GitTreeEntry): GitResultCode =
  ## convert a tree entry into a thing
  withGit:
    var obj: GitObject
    result = git_tree_entry_to_object(addr obj, repo, entry).grc
    if result == grcOk:
      thing = newThing(obj)

proc treeEntryToThing*(thing: var GitThing; at: string;
                       entry: GitTreeEntry): GitResultCode =
  ## convert a tree entry into a thing using the repo at the given path
  withGitRepoAt(at):
    result = treeEntryToThing(thing, repo, entry)

proc treeWalk*(tree: GitTree; mode: GitTreeWalkMode;
               callback: git_treewalk_cb;
               payload: pointer): GitResultCode =
  ## walk a tree and run a callback on every entry
  withGit:
    result = git_tree_walk(tree,
                           cast[git_treewalk_mode](mode.ord.cint),
                           callback, payload).grc

proc treeWalk*(tree: GitTree;
               mode: GitTreeWalkMode): Option[GitTreeEntries] =
  ## try to walk a tree and return a sequence of its entries
  withGit:
    var
      entries: GitTreeEntries

  proc walk(root: cstring; entry: ptr git_tree_entry;
             payload: pointer): cint {.exportc.} =
    # a good way to get a round
    var dupe: GitTreeEntry
    if git_tree_entry_dup(addr dupe, entry).grc == grcOk:
      cast[var GitTreeEntries](payload).add dupe

  if grcOk == tree.treeWalk(mode, cast[git_treewalk_cb](walk),
                            payload = addr entries):
    result = entries.some

proc treeWalk*(tree: GitThing; mode = gtwPre): Option[GitTreeEntries] =
  ## the laziest way to walk a tree, ever
  result = treeWalk(cast[GitTree](tree.o), mode)

proc newRevWalk*(walker: var GitRevWalker; repo: GitRepository): GitResultCode =
  ## instantiate a new walker
  withGit:
    result = git_revwalk_new(addr walker, repo).grc

proc newRevWalk*(walker: var GitRevWalker; path: string): GitResultCode =
  ## instantiate a new walker from a repo at the given path
  withGitRepoAt(path):
    result = newRevWalk(walker, repo)

proc next*(oid: var git_oid; walker: GitRevWalker): GitResultCode =
  ## walk to the next node
  withGit:
    result = git_revwalk_next(addr oid, walker).grc

proc push*(walker: var GitRevWalker; oid: GitOid): GitResultCode =
  ## add a tree to be walked
  withGit:
    result = git_revwalk_push(walker, oid).grc

iterator revWalk*(repo: GitRepository; walker: GitRevWalker;
                  start: GitOid): GitCommit =
  ## sic the walker on a repo starting with the given oid
  withGit:
    var
      oid = cast[git_oid](start[])
      commit: GitCommit
    while true:
      gitTrap commit, git_commit_lookup(addr commit, repo, addr oid).grc:
        warn &"unexpected error while walking {oid}:"
        dumpError()
        break
      yield commit
      gitTrap next(oid, walker):
        break

iterator revWalk*(path: string; walker: GitRevWalker; start: GitOid): GitCommit =
  ## starting with the given oid, sic the walker on a repo at the given path
  withGitRepoAt(path):
    for commit in revWalk(repo, walker, start):
      yield commit
