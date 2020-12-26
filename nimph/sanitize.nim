import std/macros
import std/options
import std/strutils

const
  elideUnderscoresInIdentifiers {.booldefine.} = false

when nimvm:
  discard
else:
  import cutelog

proc isValidNimIdentifier*(s: string): bool =
  ## true for strings that are valid identifier names
  block complete:
    if s.len > 0 and s[0] in IdentStartChars:
      if s.len > 1 and '_' in [s[0], s[^1]]:
        break complete
      for i in 1..s.len-1:
        if s[i] notin IdentChars:
          break complete
        if s[i] == '_' and s[i-1] == '_':
          break complete
      result = true

template cappableAdd(s: var string; c: char) =
  ## add a char to a string, perhaps capitalizing it
  if s.len > 0 and s[^1] == '_':
    s.add c.toUpperAscii()
  else:
    s.add c

proc sanitizeIdentifier*(name: string; capsOkay=false): Option[string] =
  ## convert any string to a valid nim identifier in camel_Case
  var id = ""
  block sanitized:
    if name.len == 0:
      break sanitized
    for c in name:
      if id.len == 0:
        if c in IdentStartChars:
          id.cappableAdd c
          continue
      elif c in IdentChars:
        id.cappableAdd c
        continue
      # help differentiate words case-insensitively
      id.add '_'
    when not elideUnderscoresInIdentifiers:
      while "__" in id:
        id = id.replace("__", "_")
    if id.len > 1:
      id.removeSuffix {'_'}
      id.removePrefix {'_'}
    # if we need to lowercase the first letter, we'll lowercase
    # until we hit a word boundary (_, digit, or lowercase char)
    if not capsOkay and id[0].isUpperAscii:
      for i in id.low..id.high:
        if id[i] in ['_', id[i].toLowerAscii]:
          break
        id[i] = id[i].toLowerAscii
    # ensure we're not, for example, starting with a digit
    if id[0] notin IdentStartChars:
      when nimvm:
        warning "identifiers cannot start with `" & id[0] & "`"
      else:
        discard
      #  warn "identifiers cannot start with `" & id[0] & "`"
      break sanitized
    when elideUnderscoresInIdentifiers:
      if id.len > 1:
        while "_" in id:
          id = id.replace("_", "")
    if not id.isValidNimIdentifier:
      when nimvm:
        warning "bad identifier: " & id
      else:
        discard
      #  warn "bad identifier: " & id
      break sanitized
    result = id.some
