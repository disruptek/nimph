import std/tables
import std/sequtils
import std/httpclient
import std/httpcore
import std/json
import std/os
import std/options
import std/asyncfutures
import std/asyncdispatch
import std/strutils
import std/strformat
import std/uri
import std/times

import rest
import github
import jsonconvert

import nimph/spec

const
  hubTime* = initTimeFormat "yyyy-MM-dd\'T\'HH:mm:ss\'Z\'"

type
  HubKind* = enum
    HubRelease
    HubTag
    HubCommit
    HubRepo
    HubIssue
    HubPull
    HubUser
    HubCode

  HubTree* = object
    sha*: string
    url*: Uri
    `type`*: string

  HubContact* = object
    name*: string
    email*: string
    date*: DateTime

  HubVerification* = object
    verified*: bool
    reason*: string
    signature*: string
    payload*: string

  HubCommitMeta* = object
    url*: Uri
    author*: HubContact
    committer*: HubContact
    message*: string
    commentCount*: int
    tree*: HubTree

  HubResult* = ref object
    htmlUrl*: Uri
    id*: int
    number*: int
    title*: string
    body*: string
    state*: string
    name*: string
    user*: HubResult
    tagName*: string
    targetCommitish*: string
    sha*: string
    created*: DateTime
    updated*: DateTime
    case kind*: HubKind:
    of HubCommit:
      tree*: HubTree
      author*: HubResult
      committer*: HubResult
      parents*: seq[HubTree]
      commit*: HubCommitMeta
    of HubTag:
      tagger*: HubContact
      `object`*: HubTree
    of HubRelease:
      draft*: bool
      prerelease*: bool
    of HubUser:
      login*: string
    of HubIssue:
      closedBy*: HubResult
    of HubPull:
      mergedBy*: HubResult
      merged*: bool
    of HubCode:
      path*: string
      repository*: HubResult
    of HubRepo:
      fullname*: string
      description*: string
      watchers*: int
      stars*: int
      forks*: int
      owner*: string
      size*: int
      pushed*: DateTime
      issues*: int
      clone*: Uri
      git*: Uri
      ssh*: Uri
      web*: Uri
      license*: string
      branch*: string
      original*: bool
      score*: float

  HubGroup* = OrderedTable[Uri, HubResult]

  HubSort* {.pure.} = enum
    Ascending = "asc"
    Descending = "desc"

  HubSortBy* {.pure.} = enum
    Best = ""
    Stars = "stars"
    Forks = "forks"
    Updated = "updated"

proc url*(r: HubResult): Uri = r.htmlUrl

proc shortly(stamp: DateTime): string =
  ## render a date shortly
  result = stamp.format(shortDate)

proc renderShortly*(r: HubResult): string =
  result = &"""
{r.web:<65} pushed {r.pushed.shortly}
{r.size:>5} {"kb":<10} {r.issues:>4} {"issues":<10} {r.stars:>4} {"stars":<10} {r.forks:>4} {"forks":<10} created {r.created.shortly}
  {r.description}
  """
  result = result.strip

proc findGithubToken*(): Option[string] =
  ## find a github token in one of several places
  var
    token: string
  let
    hub = getHomeDir() / hubTokenFn
    file = getHomeDir() / dotNimble / ghTokenFn
    env = getEnv(ghTokenEnv, getEnv("GITHUB_TOKEN", getEnv("GHI_TOKEN", "")))
  if env != "":
    token = env
    debug "using a github token from environment"
  elif fileExists(file):
    token = readFile(file)
    debug "using a github token from nimble"
  elif fileExists(hub):
    for line in lines(hub):
      if "oauth_token:" in line:
        token = line.strip.split(" ")[^1]
        debug "using a github token from hub"
  token = token.strip
  if token != "":
    result = token.some

proc newHubContact*(js: JsonNode): HubContact =
  ## parse some json into a simple contact record
  let
    tz = utc()
  # 🐼 result = js.to(HubContact)
  if js == nil or "date" notin js or js.kind != JString:
    result = HubContact(date: now())
  else:
    result = HubContact(
      date: js["date"].getStr.parse(hubTime, zone = tz)
    )
  if js != nil:
    result.name = js.get("name", "")
    result.email = js.get("email", "")

proc newHubTree*(js: JsonNode): HubTree =
  ## parse something like a commit tree
  result = HubTree()
  if js != nil:
    result.url = js.get("url", "").parseUri
    result.sha = js.get("sha", "")
    result.`type` = js.get("type", "")

proc newHubCommitMeta*(js: JsonNode): HubCommitMeta =
  ## collect some ingredients found in a typical commit
  result = HubCommitMeta(
    committer: newHubContact js.getOrDefault("committer"),
    author: newHubContact js.getOrDefault("author")
  )
  result.tree = newHubTree js.getOrDefault("tree")
  result.commentCount = js.get("comment_count", 0)

proc newHubResult*(kind: HubKind; js: JsonNode): HubResult

proc init*(result: var HubResult; js: JsonNode) =
  ## instantiate a new hub object using a jsonnode

  # impart a bit of sanity
  if js == nil or js.kind != JObject:
    raise newException(Defect, "nonsensical input: " & js.pretty)

  case result.kind:
  of HubRelease: discard
  of HubTag: discard
  of HubCommit:
    result.committer = HubUser.newHubResult(js["committer"])
    result.author = HubUser.newHubResult(js["author"])
    result.sha = js["sha"].getStr
  of HubIssue:
    if "closed_by" in js and js["closed_by"].kind == JObject:
      result.closedBy = HubUser.newHubResult(js["closed_by"])
  of HubPull:
    result.merged = js.getOrDefault("merged").getBool
    if "merged_by" in js and js["merged_by"].kind == JObject:
      result.mergedBy = HubUser.newHubResult(js["merged_by"])
  of HubCode:
    result.path = js.get("path", "")
    result.sha = js.get("sha", "")
    result.name = js.get("name", "")
    if "repository" in js:
      result.repository = HubRepo.newHubResult(js["repository"])
  of HubRepo:
    result.fullname = js.get("full_name", "")
    result.owner = js.get("owner", "")
    result.name = js.get("name", "")
    result.description = js.get("description", "")
    result.stars = js.get("stargazers_count", 0)
    result.watchers = js.get("subscriber_count", 0)
    result.forks = js.get("forks_count", 0)
    result.issues = js.get("open_issues_count", 0)
    if "clone_url" in js:
      result.clone = js["clone_url"].getStr.parseUri
    if "git_url" in js:
      result.git = js["git_url"].getStr.parseUri
    if "ssh_url" in js:
      result.ssh = js["ssh_url"].getStr.parseUri
    if "homepage" in js and $js["homepage"] notin ["null", ""]:
      result.web = js["homepage"].getStr.parseUri
    if not result.web.isValid:
      result.web = result.htmlUrl
    if "license" in js:
      result.license = js["license"].getOrDefault("name").getStr
    result.branch = js.get("default_branch", "")
    result.original = not js.get("fork", false)
    result.score = js.get("score", 0.0)
  of HubUser:
    result.login = js.get("login", "")
  result.id = js.get("id", 0)
  if "title" in js:
    result.body = js.get("body", "")
    result.title = js.get("title", "")
    result.state = js.get("state", "")
    result.number = js.get("number", 0)
  if "user" in js and js["user"].kind == JObject:
    result.user = HubUser.newHubResult(js["user"])

proc newHubResult*(kind: HubKind; js: JsonNode): HubResult =
  # impart a bit of sanity
  if js == nil or js.kind != JObject:
    raise newException(Defect, "nonsensical input: " & js.pretty)

  template thenOrNow(label: string): DateTime =
    if js != nil and label in js and js[label].kind == JString:
      js[label].getStr.parse(hubTime, zone = tz)
    else:
      now()

  let
    tz = utc()
    kind = block:
      if "head" in js:
        HubPull
      elif kind == HubPull:
        HubIssue
      else:
        kind

  case kind
  of HubRelease:
    result = HubResult(kind: HubRelease,
                       created: thenOrNow "created_at",
                       updated: thenOrNow "updated_at")
  of HubTag:
    result = HubResult(kind: HubTag,
                       tagger: newHubContact(js.getOrDefault("tagger")),
                       `object`: newHubTree(js.getOrDefault("object")),
                       created: thenOrNow "created_at",
                       updated: thenOrNow "updated_at")
  of HubPull:
    result = HubResult(kind: HubPull,
                       created: thenOrNow "created_at",
                       updated: thenOrNow "updated_at")
  of HubCode:
    result = HubResult(kind: HubCode,
                       created: thenOrNow "created_at",
                       updated: thenOrNow "updated_at")
  of HubIssue:
    result = HubResult(kind: HubIssue,
                       created: thenOrNow "created_at",
                       updated: thenOrNow "updated_at")
  of HubRepo:
    result = HubResult(kind: HubRepo,
                       pushed: thenOrNow "pushed_at",
                       created: thenOrNow "created_at",
                       updated: thenOrNow "updated_at")
  of HubCommit:
    result = HubResult(kind: HubCommit,
                       commit: newHubCommitMeta(js.getOrDefault("commit")),
                       created: thenOrNow "created_at",
                       updated: thenOrNow "updated_at")
  of HubUser:
    result = HubResult(kind: HubUser,
                       created: thenOrNow "created_at",
                       updated: thenOrNow "updated_at")

  result.htmlUrl = js.get("html_url", "").parseUri
  result.init(js)

proc newHubGroup*(): HubGroup =
  result = HubGroup()

proc authorize*(request: Recallable): bool =
  ## find and inject credentials into a github request
  let token = findGithubToken()
  result = token.isSome
  if result:
    request.headers.del "Authorization"
    request.headers.add "Authorization", "token " & token.get
  else:
    error "unable to find a github authorization token"

proc queryOne(recallable: Recallable; kind: HubKind): Future[Option[HubResult]]
  {.async.} =
  ## issue a recallable query and parse the response as a single item
  block success:
    # start with installing our credentials into the request
    if not recallable.authorize:
      break success

    # send the request to github and see if they like it
    let response = await recallable.issueRequest()
    if not response.code.is2xx:
      notice &"got response code {response.code} from github"
      break success

    # read the response and parse it to json
    let js = parseJson(await response.body)

    # turn the json into a hub result object
    result = newHubResult(kind, js).some

proc queryMany(recallable: Recallable; kind: HubKind): Future[Option[HubGroup]]
  {.async.} =
  ## issue a recallable query and parse the response as a group of items
  block success:
    # start with installing our credentials into the request
    if not recallable.authorize:
      break success

    # send the request to github and see if they like it
    let response = await recallable.issueRequest()
    if not response.code.is2xx:
      notice &"got response code {response.code} from github"
      break success

    # read the response and parse it to json
    let js = parseJson(await response.body)

    # we know now that we'll be returning a group of some size
    var group = newHubGroup()

    # add any parseable results to the group
    for node in js["items"].items:
      try:
        let item = newHubResult(kind, node)
        # if these are repositories, ignore forks
        if kind != HubRepo or item.original:
          group[item.url] = item
      except Exception as e:
        warn "error parsing repo: " & e.msg

    result = some(group)

proc getGitHubUser*(): Future[Option[HubResult]] {.async.} =
  ## attempt to retrieve the authorized user
  var
    req = getUser.call(_ = "")
  debug &"fetching github user"
  result = await req.queryOne(HubUser)

proc forkHub*(owner: string; repo: string): Future[Option[HubResult]] {.async.} =
  ## attempt to fork an existing repository
  var
    req = postReposOwnerRepoForks.call(repo = repo, owner = owner, body = newJObject())
  debug &"forking owner `{owner}` repo `{repo}`"
  result = await req.queryOne(HubRepo)

proc searchHub*(keywords: seq[string]; sort = Best;
                order = Descending): Future[Option[HubGroup]] {.async.} =
  ## search github for packages
  var
    query = @["language:nim"].concat(keywords)
    req = getSearchRepositories.call(q = query.join(" "),
                                     sort = $sort,
                                     order = $order)
  debug &"searching github for {query}"
  result = await req.queryMany(HubRepo)

when not defined(ssl):
  {.error: "this won't work without defining `ssl`".}
