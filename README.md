# nimph
nim package handler from the future

or: _How I Learned to Stop Worrying and Love the Search Path_

## Features
- truly path-agnostic dependencies
- native git integration for speed
- github api integration for comfort
- reproducible builds via lockfiles
- immutable cloud-based distributions
- wildcard, tilde, and caret semver
- absolutely zero configuration
- total interoperability with Nimble

## Notable Requirements
- nimgit2 _builds libgit2 and its bindings_
- nimterop _in order to build nimgit2_
- compiler _ie. the compiler as a library_
- nim >= 1.0.4 _for --clearNimblePath and --define:key=value syntax_

## Installation
```
$ nimble install https://github.com/disruptek/nimph
```

## License
MIT
