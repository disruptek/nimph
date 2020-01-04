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

import nimph/spec
import nimph/group

const
  hubTime* = initTimeFormat "yyyy-MM-dd\'T\'HH:mm:ss\'Z\'"

type
  HubKind* = enum
    HubRepo
    HubIssue
    HubPull
    HubUser
    HubCode

  HubResult* = ref object
    htmlUrl*: Uri
    id*: int
    number*: int
    title*: string
    body*: string
    state*: string
    name*: string
    user*: HubResult
    case kind*: HubKind:
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
      sha*: string
    of HubRepo:
      fullname*: string
      description*: string
      watchers*: int
      stars*: int
      forks*: int
      owner*: string
      size*: int
      created*: DateTime
      updated*: DateTime
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

  HubGroup* = ref object of Group[Uri, HubResult]

  HubSort* {.pure.} = enum
    Ascending = "asc"
    Descending = "desc"

  HubSortBy* {.pure.} = enum
    Best = ""
    Stars = "stars"
    Forks = "forks"
    Updated = "updated"

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

proc newHubResult*(kind: HubKind; js: JsonNode): HubResult =
  ## instantiate a new hub object using a jsonnode

  # impart a bit of sanity
  if js == nil or js.kind != JObject:
    raise newException(Defect, "nonsensical input: " & js.pretty)

  let
    tz = utc()
    kind = block:
      if "head" in js:
        HubPull
      elif kind == HubPull:
        HubIssue
      else:
        kind

  case kind:
  of HubIssue:
    result = HubResult(kind: HubIssue)
    result.htmlUrl = js["html_url"].getStr.parseUri
    if "closed_by" in js and js["closed_by"].kind == JObject:
      result.closedBy = HubUser.newHubResult(js["closed_by"])
  of HubPull:
    result = HubResult(kind: HubPull)
    result.htmlUrl = js["html_url"].getStr.parseUri
    result.merged = js.getOrDefault("merged").getBool
    if "merged_by" in js and js["merged_by"].kind == JObject:
      result.mergedBy = HubUser.newHubResult(js["merged_by"])
  of HubCode:
    result = HubResult(kind: HubCode)
    result.htmlUrl = js["html_url"].getStr.parseUri
    result.path = js["path"].getStr
    result.sha = js["sha"].getStr
    result.name = js["name"].getStr
    if "repository" in js:
      result.repository = HubRepo.newHubResult(js["repository"])
  of HubRepo:
    template thenOrNow(label: string): DateTime =
      if label in js:
        js[label].getStr.parse(hubTime, zone = tz)
      else:
        now()
    result = HubResult(kind: HubRepo,
      created: thenOrNow "created_at",
      updated: thenOrNow "updated_at",
      pushed: thenOrNow "pushed_at",
    )
    result.htmlUrl = js["html_url"].getStr.parseUri
    result.fullname = js["full_name"].getStr
    if "owner" in js and js["owner"].kind == JString:
      result.owner = js["owner"].getStr
    result.name = js["name"].getStr
    result.description = js["description"].getStr
    if "stargazers_count" in js:
      result.stars = js["stargazers_count"].getInt
    if "subscriber_count" in js:
      result.watchers = js.getOrDefault("subscriber_count").getInt
    if "forks_count" in js:
      result.forks = js["forks_count"].getInt
    if "open_issues_count" in js:
      result.issues = js["open_issues_count"].getInt
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
    if "default_branch" in js:
      result.branch = js["default_branch"].getStr
    result.original = not js["fork"].getBool
    result.score = js.getOrDefault("score").getFloat
  of HubUser:
    result = HubResult(kind: HubUser)
    result.login = js["login"].getStr
  if "id" in js:
    result.id = js["id"].getInt
  if "title" in js:
    result.body = js["body"].getStr
    result.number = js["number"].getInt
    result.title = js["title"].getStr
    result.state = js["state"].getStr
  if "user" in js and js["user"].kind == JObject:
    result.user = HubUser.newHubResult(js["user"])

proc newHubGroup*(flags: set[Flag] = defaultFlags): HubGroup =
  result = HubGroup(flags: flags)
  result.init(flags, mode = modeCaseSensitive)

proc add*(group: var HubGroup; hub: HubResult) =
  {.warning: "nim bug #12818".}
  add[Uri, HubResult](group, hub.htmlUrl, hub)

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
    var
      group = newHubGroup()
    result = group.some

    # add any parseable results to the group
    for node in js["items"].items:
      try:
        let item = newHubResult(kind, node)
        # if these are repositories, ignore forks
        if kind == HubRepo and not item.original:
          continue
        group.add item
      except Exception as e:
        warn "error parsing repo: " & e.msg

proc getGitHubUser*(): Future[Option[HubResult]] {.async.} =
  ## attempt to retrieve the authorized user
  var
    req = getUser.call()
  debug &"fetching github user"
  result = await req.queryOne(HubUser)

proc forkHub*(owner: string; repo: string): Future[Option[HubResult]] {.async.} =
  ## attempt to fork an existing repository
  var
    req = postReposOwnerRepoForks.call(repo, owner, body = newJObject())
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
