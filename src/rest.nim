import times
import httpclient
import httpcore
import json
import strutils
import uri

export httpcore.HttpMethod, is2xx, is3xx, is4xx, is5xx

type
  KeyVal = tuple[key: string; val: string]

  RestClientObj = object of RootObj
    keepalive: bool
    http: HttpClient
    headers: HttpHeaders
  RestClient* = ref RestClientObj

  RestCall* = ref object of RootObj
    client*: RestClient
    name*: string
    meth*: HttpMethod
    url*: Uri

  Recallable* = ref object of RootObj
    ## a handle on input/output of a re-issuable API call
    headers*: HttpHeaders
    client*: RestClient
    url*: string
    json*: JsonNode
    body*: string
    retries*: int
    began*: Time
    took*: Duration
    meth*: HttpMethod
  RestError* = object of CatchableError       ## base for REST errors
  RetriesExhausted* = object of RestError     ## ran outta retries
  CallRequestError* = object of RestError     ## HTTP [45]00 status code

proc massageHeaders*(node: JsonNode): seq[KeyVal] =
  if node == nil or node.kind != JObject or node.len == 0:
    return @[]
  else:
    for k, v in node.pairs:
      assert v.kind == JString
      result.add (key: k, val: v.getStr)

method `$`*(e: ref RestError): string
  {.base, raises: [].}=
  result = $typeof(e) & " " & e.msg

method `$`*(c: RestCall): string
  {.base, raises: [].}=
  result = $c.meth
  result = result.toUpperAscii & " " & c.name

method initRestClient*(self: RestClient) {.base.} =
  self.http = newHttpClient()

proc newRestClient*(): RestClient =
  new result
  result.initRestClient()

method newRecallable*(call: RestCall; url: Uri; headers: HttpHeaders;
                      body: string): Recallable
  {.base, raises: [Exception].} =
  ## make a new HTTP request that we can reissue if desired
  new result
  result.url = $url
  result.retries = 0
  result.body = body
  if call.client != nil and call.client.keepalive:
    result.client = call.client
  else:
    result.client = newRestClient()
  result.headers = headers
  result.client.headers = result.headers
  result.client.http.headers = result.headers
  result.meth = call.meth

proc issueRequest*(rec: Recallable): Response
  {.raises: [RestError].} =
  ## submit a request and store some metrics
  assert rec.client != nil
  try:
    if rec.body == "":
      if rec.json != nil:
        rec.body = $rec.json
    rec.began = getTime()
    #
    # FIXME move this header-fu into something restClient-specific
    #
    if not rec.headers.isNil:
      rec.client.http.headers = rec.headers
    elif not rec.client.headers.isNil:
      rec.client.http.headers = rec.client.headers
    else:
      rec.client.http.headers = newHttpHeaders()
    result = rec.client.http.request(rec.url, rec.meth, body=rec.body)
  except CatchableError as e:
    raise newException(RestError, e.msg)
  except Exception as e:
    raise newException(RestError, e.msg)
