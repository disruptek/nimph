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

type
  HubRepo* = ref object
    fullname*: string
    owner*: string
    name*: string
    description*: string
    created*: DateTime
    updated*: DateTime
    pushed*: DateTime
    size*: int
    stars*: int
    watchers*: int
    forks*: int
    issues*: int
    clone*: Uri
    git*: Uri
    ssh*: Uri
    web*: Uri
    license*: string
    branch*: string
    original*: bool
    score*: float

  HubGroup* = ref object
    repos*: OrderedTableRef[string, HubRepo]

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

iterator values*(group: HubGroup): HubRepo =
  for value in group.repos.values:
    yield value

proc renderShortly*(r: HubRepo): string =
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
    env = getEnv(ghTokenEnv, "")
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

proc add(group: HubGroup; repo: HubRepo) =
  ## add a repo to the group
  group.repos.add repo.fullname, repo

proc newHubRepo(js: JsonNode): HubRepo =
  ## instantiate a new repo using a jsonnode
  let
    tz = utc()
  result = HubRepo(
    fullname: js["full_name"].getStr,
    owner: js["owner"].getStr,
    name: js["name"].getStr,
    description: js["description"].getStr,
    created: js["created_at"].getStr.parse(hubTime, zone = tz),
    updated: js["updated_at"].getStr.parse(hubTime, zone = tz),
    pushed: js["pushed_at"].getStr.parse(hubTime, zone = tz),
    size: js["size"].getInt,
    stars: js["stargazers_count"].getInt,
    watchers: js["watchers_count"].getInt,
    forks: js["forks_count"].getInt,
    issues: js["open_issues_count"].getInt,
    clone: js["clone_url"].getStr.parseUri,
    git: js["git_url"].getStr.parseUri,
    ssh: js["git_url"].getStr.parseUri,
    web: js["html_url"].getStr.parseUri,
    license: js["license"].getOrDefault("name").getStr,
    branch: js["default_branch"].getStr,
    original: not js["fork"].getBool,
    score: js["score"].getFloat,
  )

proc newHubGroup(): HubGroup =
  result = HubGroup()
  result.repos = newOrderedTable[string, HubRepo]()

proc len*(group: HubGroup): int =
  result = group.repos.len

iterator reversed*(group: HubGroup): HubRepo =
  ## yield repos in reverse order of entry
  let
    repos = toSeq group.values

  for i in countDown(repos.high, repos.low):
    yield repos[i]

proc searchHub*(keywords: seq[string]; sort = Best;
                order = Descending): Future[Option[HubGroup]] {.async.} =
  ## search github for packages
  let
    token = findGithubToken()
  if not token.isSome:
    return
  var
    query = @["language:nim"].concat(keywords)
    req = getSearchRepositories.call(q = query.join(" "),
                                     sort = $sort,
                                     order = $order)
  req.headers.del "Authorization"
  req.headers.add "Authorization", "token " & token.get

  let
    response = await req.issueRequest()
  if not response.code.is2xx:
    notice &"got response code {response.code} from github"
    return
  let
    body = await response.body
    js = parseJson(body)
  var
    group = newHubGroup()
  for node in js["items"].items:
    try:
      let repo = newHubRepo(node)
      if repo.original:
        group.add repo
    except Exception as e:
      warn "error parsing repo: " & e.msg
  result = group.some

when not defined(ssl):
  {.error: "this won't work without defining `ssl`".}
