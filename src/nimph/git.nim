import std/strformat
import std/uri

import nimgit2

{.hint: "libgit2 version " & git2SetVer.}

import nimph/spec

type
  GitHeapGits = git_repository | git_reference
  NimHeapGits = git_clone_options
  GitOid* = ptr git_oid
  GitReference* = ptr git_reference
  GitRepository* = ptr git_repository
  GitClone* = object
    url*: cstring
    directory*: cstring
    repo*: GitRepository
    options*: ptr git_clone_options
  GitOpen* = object
    path*: cstring
    repo*: GitRepository

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
    else:
      {.error: "missing a free definition".}

proc free*[T: NimHeapGits](point: ptr T) =
  if point != nil:
    dealloc(point)

proc free*(clone: GitClone) =
  free(clone.repo)
  free(clone.options)

proc `$`*(got: GitOid): string =
  result = $git_oid_tostr_s(got)

proc oid*(got: GitReference): GitOid =
  result = git_reference_target(got)

proc name*(got: GitReference): string =
  result = $git_reference_name(got)

proc isTag*(got: GitReference): bool =
  result = git_reference_is_tag(got) == 1

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

proc openRepository*(got: var GitOpen; path: string): int =
  got.path = path
  #got.repo = cast[ptr git_repository](sizeof(git_repository).alloc)
  result = git_repository_open(addr got.repo, got.path)
