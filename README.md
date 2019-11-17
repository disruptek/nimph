# nimph
nim package handler from the future

_so far in the future, in fact, that it's only now starting to become visible..._

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
- nim >= 1.1.1 _for --clearNimblePath and --define:key=value syntax_

## License
MIT
