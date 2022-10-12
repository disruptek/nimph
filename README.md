# nimph

[![Test Matrix](https://github.com/disruptek/nimph/workflows/CI/badge.svg)](https://github.com/disruptek/nimph/actions?query=workflow%3ACI)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/disruptek/nimph?style=flat)](https://github.com/disruptek/nimph/releases/latest)
![Minimum supported Nim version](https://img.shields.io/badge/nim-1.2.14%2B-informational?style=flat&logo=nim)
![Maximum supported Nim version](https://img.shields.io/badge/nim-1.6.7%2B-informational?style=flat&logo=nim)
[![License](https://img.shields.io/github/license/disruptek/nimph?style=flat)](#license)

nim package hierarchy manager from the future

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
- full-featured choosenim replacement

## Usage

You can run `nimph` from anywhere in your project tree; it will simply search
upwards until it finds a `.nimble` file and act as if you ran it there.

Most operations do require that you be within a project, but `nimph` is
flexible enough to operate on local dependencies, global packages, and anything
in-between. You can run it on any package, anywhere, and it will provide useful
output (and optional repair) of the environment it finds itself in.

- [Searching for New Nim Packages](https://github.com/disruptek/nimph#search)
- [Adding Packages to the Environment](https://github.com/disruptek/nimph#clone)
- [Checking the Environment for Errors](https://github.com/disruptek/nimph#doctor)
- [Quickly Forking an Installed Package](https://github.com/disruptek/nimph#fork)
- [Finding a Path via Nim Import Name](https://github.com/disruptek/nimph#path)
- [Locking the Dependency Tree by Name](https://github.com/disruptek/nimph#lock)
- [Specifying Arbitrary Package Versions](https://github.com/disruptek/nimph#roll)
- [Upgrading Dependencies Automatically](https://github.com/disruptek/nimph#upgrade)
- [Downgrading Dependencies Automatically](https://github.com/disruptek/nimph#downgrade)
- [Cutting New Release Versions+Tags](https://github.com/disruptek/nimph#bump)
- [Adding Any Missing Tags Automatically](https://github.com/disruptek/nimph#tag)
- [Running Commands on All Dependencies](https://github.com/disruptek/nimph#run)
- [Outputting the Dependency Graph](https://github.com/disruptek/nimph#graph)
- [Git Subcommand Auto-Integration](https://github.com/disruptek/nimph#git-subcommands)
- [Nimble Subcommand Auto-Integration](https://github.com/disruptek/nimph#nimble-subcommands)
- [Tweaking Nimph Behavior Constants](https://github.com/disruptek/nimph#hacking)
- [Using `choosenim` to Select Nim Toolchains](https://github.com/disruptek/nimph#choose-nimph-choose-nim)
- [Nimph Module Documentation](https://github.com/disruptek/nimph#documentation)

## Demonstration

This is a demo screencast of using Nimph to setup a project for development.
Starting with nothing more than the project's repository, we'll...

1. show the `bot.nimble` that specifies varied dependencies
1. show the `nim.cfg` that specifies compilation options
1. edit the `nim.cfg` to configure a directory to hold local dependencies
1. create a `deps` directory to hold those packages
1. run `nimph` to evaluate the state of the environment -- verdict: 😦
1. run `nimph doctor` to converge the environment to our specifications
1. run `nimph` to confirm the environment state -- verdict: 😊
1. show the `nim.cfg` to reveal any changes made by `nimph doctor`

[![asciicast](https://asciinema.org/a/aoDAm39yjoKenepl15L3AyfzN.svg)](https://asciinema.org/a/aoDAm39yjoKenepl15L3AyfzN)

## Installation

A `bootstrap-nonimble.sh` script is provided which retrieves the dependencies
and builds Nimph without requiring `nimble`.

### Windows

I no longer test Windows via the CI because I have no way to debug it.
That said, Windows builds may work just fine for you using the older
`bootstrap.ps1` which relies upon `nimble` to install dependencies.

### OS X

I no longer test OS X via the CI because I cannot be bothered to debug
libgit2/libssh behavior there.  The tests for nim-1.2 do pass, however.

### GitHub Integration

You may want to [create a new GitHub personal access token
here](https://github.com/settings/tokens) and then add it to your environment
as `NIMPH_TOKEN` or `GITHUB_TOKEN`.

If you skip this step, Nimph will try to use a Nimble token for **search**es,
and it will also try to read any `hub` or `ghi` credentials.  Notably, the
**fork** subcommand will not work without adequate scope authorization.

## Subcommand Usage

### Search

The `search` subcommand is used to query GitHub for
packages. Arguments should match [GitHub search syntax for
repositories](https://help.github.com/en/github/searching-for-information-on-gi
thub/searching-for-repositories) and for convenience, a `language:nim`
qualifier will be included.

Results are output in **increasing order of relevance** to reduce scrolling;
_the last result is the best_.

```
$ nimph search pegs

https://github.com/GlenHertz/peg                                  pushed 2017-11-19
  645 kb            0 issues        0 stars         0 forks      created 2017-11-18
  PEG version of grep

https://github.com/lguzzon-NIM/simplePEG                          pushed 2019-09-05
   82 kb            0 issues        0 stars         0 forks      created 2017-09-05
  Simple Peg

https://github.com/zevv/npeg                                      pushed 2019-11-27
 9125 kb            2 issues       66 stars         2 forks      created 2019-03-08
  PEGs for Nim, another take
```

### Clone

The `clone` subcommand performs git clones to add packages to your environment.
Pass this subcommand some GitHub search syntax and it will download the best
matching package, or you can supply a URL directly.  Local URLs are fine, too.

Where the package ends up is a function of your existing compiler settings
as recorded in relevant `nim.cfg` files; we'll search all `--nimblePath`
statements, but according to a convention also adopted by Nimble...

_The last specified --nimblePath, as processed by the `nim.cfg` files, is the
"default" for the purposes of new package additions._

```
$ nimph clone npeg
👭cloning git://github.com/zevv/npeg.git...
👌cloned git://github.com/zevv/npeg.git
```

### Doctor

The interesting action happens in the `doctor` subcommand.  When run without any
arguments, `nimph` effectively runs the `doctor` with a `--dry-run` option, to
perform non-destructive evaluation of your environment and report any issues.
In this mode, logging is elevated to report package versions and a summary of
their last commit or tag.

```
$ nimph
✔️  8a7114          bot   cleanups
✔️  775047      swayipc   we can remove this notice now
✔️  v0.4.5         nesm   Version 0.4.5
✔️  5186f4       cligen   Add a test program and update release notes as per last commit to fix https://github.com/c-blake/cligen/issues/120
✔️  c7ba0f         dbus   Merge pull request #3 from SolitudeSF/case
✔️  57f244        c2nim   new option: annotate procs with `{.noconv.}`
✔️  54ed41         npeg   Added section about non-consuming operators and captures to the README. Fixes #17
✔️  183eaa    unittest2   remove redundant import
✔️  v0.3.0          irc   v0.3.0
✔️  fe276f         rest   add generated docs
✔️  5d72a4      foreach   clarify example
✔️  5493b2           xs   add some docs about google
✔️   1.0.1      cutelog   ladybug easier to see
✔️  9d75fe         bump   update docs
✔️   1.0.2       github   fix nimble again
✔️  6830ae        nimph   add asciinema demo
✔️  b6b8d5     compiler   [backport] always set `fileInfoIdx.isKnownFile` (#12773)
✔️  v0.3.3     nimterop   v0.3.3
✔️ v0.13.0        regex   bump 0.13.0 (#52)
✔️  2afc38    unicodedb   improve decomposition performance (#11)
✔️  v0.5.1  unicodeplus   Fix ascii range (#2)
✔️  v0.1.1      nimgit2   v0.1.1
✔️  v0.5.0    parsetoml   Update to version 0.5.0
👌bot version 0.0.11 lookin' good
```
When run as `nimph doctor`, any problems discovered will be fixed, if possible.
This includes cloning missing packages for which we can determine a URL,
adjusting path settings in the project's `nim.cfg`, and similar housekeeping.

```
$ nimph doctor
👌bot version 0.0.11 lookin' good
```

### Fork

The `fork` subcommand is used to fork an installed dependency in your GitHub
account and add a new git `origin` remote pointing at your new fork. The
original `origin` remote is renamed to `upstream` by default. These constants
may be easily changed; see **Hacking** below.

This allows you to quickly move from merely testing a package to improving it
and sharing your work upstream.

```
$ nimph fork npeg
🍴forking npeg-#54ed418e80f1e1b14133ed383b9c585b320a66cf
🔱https://github.com/disruptek/npeg
```

### Path

The `path` subcommand is used to retrieve the filesystem path to a package
given the Nim symbol you might use to import it. For consistency, the package
must be installed.

In contrast to Nimble, you can specify multiple symbols to search for, and the
symbols are matched without regard to underscores or capitalization.
```
$ nimph path nimterop irc
/home/adavidoff/git/bot/deps/pkgs/nimterop-#v0.3.3
/home/adavidoff/git/bot/deps/pkgs/irc-#v0.3.0
```

If you want to limit your search to packages that are part of your project's
dependency tree, add the `--strict` switch:

```
$ nimph path coco
/home/adavidoff/git/nimph/deps/pkgs/coco-#head

$ nimph path --strict coco
couldn't find a dependency importable as `coco`
```

It's useful to create a shell function to jump into dependency directories so
you can quickly hack at them.

```bash
#!/bin/bash
function goto { pushd `nimph path $1`; }
```

or

```fish
#!/bin/fish
function goto; pushd (nimph path $argv); end
```

### Lock

The `lock` subcommand writes the current dependency tree to a JSON file; see
**Hacking** below to customize its name. You pass arguments to give this record
a name that you can use to retrieve the dependency tree later. Multiple such
_lockfiles_ may be cached in a single file.

```
$ nimph lock works with latest npeg
👌locked nimph-#0.0.26 as `works with latest npeg`
```

### Unlock

The `unlock` subcommand reads a dependency tree previously saved with `lock`
and adjusts the environment to match, installing any missing dependencies and
rolling repositories to the versions that were recorded previously.

```
$ nimph unlock goats
unsafe lock of `regex` for regex>=0.10.0 as #ff6ab8297c72f30e4da34daa9e8a60075ce8df7b
👭cloning https://github.com/zevv/npeg...
rolled to #e3243f6ff2d05290f9c6f1e3d3f1c725091d60ab to meet git://github.com/disruptek/cutelog.git##1.1.1
```

### Roll

The `roll` subcommand lets you supply arbitrary requirements which are
evaluated exactly as if they appeared in your package specification file. For
shell escaping reasons, each such requirement should be a quoted string.

```
$ nimph roll "nimterop == 0.3.4"
rolled to #v0.3.4 to meet nimterop>=0.3.3
👌nimph is lookin' good
```

Nimph will ensure that the new requirement doesn't break any existing
requirements of the project or any of its dependencies.

```
$ nimph roll "nimterop > 6"
nimterop*6 unmet by nimterop-#v0.3.4
failed to fix all dependencies
👎nimph is not where you want it
```

As Nimble does not yet support caret (`^`), tilde (`~`), or wildcard (`*`),
`roll` is the only way to experiment with these operators in requirements.

```
$ nimph roll "nimterop 0.3.*"
rolled to #v0.3.6 to meet nimterop>=0.3.3
👌nimph is lookin' good
```

You can also use `roll` to resolve packages that are named in Nimble's official
package directory but aren't hosted on GitHub.

```
$ nimph roll nesm
👭cloning https://gitlab.com/xomachine/NESM.git...
rolled to #v0.4.5 to meet nesm**
👌xs is lookin' good
```

### Upgrade

The `upgrade` subcommand resolves the project's dependencies and attempts to
upgrade any git clones to the latest release tag that matches the project's
requirements.

The `outdated` subcommand is an alias equivalent to `upgrade --dry-run`:

```
$ nimph outdated
would upgrade bump from 1.8.16 to 1.8.17
would upgrade nimph from 0.3.2 to 0.4.1
would upgrade nimterop from 0.3.3 to v0.3.5
👎bot is not where you want it
```

Upgrade individual packages by specifying the _import name_.

```
$ nimph upgrade swayipc
rolled swayipc from 3.1.0 to 3.1.3
the latest swayipc release of 3.1.4 is masked
👌bot is up-to-date
```

Upgrade all dependencies at once by omitting any module names.

```
$ nimph upgrade
the latest swayipc release of 3.1.4 is masked
rolled foreach from 1.0.0 to 1.0.2
rolled cutelog from 1.0.1 to 1.1.1
rolled bump from 1.8.11 to 1.8.16
rolled github from 1.0.1 to 1.0.2
rolled nimph from 0.1.0 to 0.2.1
rolled regex from 0.10.0 to v0.13.0
rolled unicodedb from 0.6.0 to v0.7.2
👌bot is up-to-date
```

### Downgrade

The `downgrade` subcommand performs the opposite action to the upgrade
subcommand.

```
$ nimph downgrade
rolled swayipc from 3.1.4 to 3.1.0
rolled cligen from 0.9.41 to v0.9.40
rolled foreach from 1.0.2 to 1.0.0
rolled cutelog from 1.1.1 to 1.0.1
rolled bump from 1.8.16 to 1.8.11
rolled github from 1.0.2 to 1.0.1
rolled nimph from 0.3.2 to 0.3.0
rolled regex from 0.13.0 to v0.10.0
rolled unicodeplus from 0.5.1 to v0.5.0
👌bot is lookin' good
```

### Bump

The `bump` tool is included as a dependency; it provides easy version and tag incrementing.

```
$ bump fixed a bug
🎉1.0.3: fixed a bug
🍻bumped
```

For complete `bump` documentation, see https://github.com/disruptek/bump

### Tag

The `tag` subcommand operates on a clean project and will roll the repository
as necessary to examine any changes to your package configuration, noting any
commits that:

- introduced a new version of the package but aren't pointed to by a tag, _and_
- introduced a new version for which there exists no tag parsable as that version

```
$ nimph tag --dry-run --log-level=lvlInfo
bump is missing a tag for version 1.1.0
version 1.1.0 arrived in commit-009d45a977a688d22a9f1b14a21b6bd1a064760e
use the `tag` subcommand to add missing tags
run without --dry-run to fix these
```

The above conditions suggest that if you don't want to use this particular
commit for your tag, you can simply point the tag at a different commit; Nimph
won't change it on you.

```
$ git tag -a "re-release_of_1.1.0_just_in_time_for_the_holidays" 0abe7a9f0b5a05f2dd709f2b120805cc0cdd9668
```

Alternatively, if you don't want a version tag to be used by package managers,
you can give the tag a name that won't parse as a version. Having found a tag
for the commit, Nimph won't warn you that the commit needs tagging.

```
$ git tag -a "oops_this_was_compromised" 0abe7a9f0b5a05f2dd709f2b120805cc0cdd9668
```

When run without `--dry-run`, any missing tags are added automatically.

```
$ nimph tag --log-level=lvlInfo
created new tag 1.1.0 for 009d45a977a688d22a9f1b14a21b6bd1a064760e
👌bump tags are lookin' good
```

Incidentally, these command-line examples demonstrate adjusting the log-level
to increase verbosity.

### Run

The `run` subcommand lets you invoke arbitrary programs in the root of each
dependency of your project.

```
$ nimph run pwd
/home/adavidoff/git/Nim
/home/adavidoff/git/nimph/deps/pkgs/github-1.0.2
/home/adavidoff/git/nimph/deps/pkgs/npeg-0.20.0
/home/adavidoff/git/nimph/deps/pkgs/rest-#head
/home/adavidoff/git/nimph/deps/pkgs/foreach-#head
/home/adavidoff/git/nimph/deps/pkgs/cligen-#head
/home/adavidoff/git/nimph/deps/pkgs/bump-1.8.15
/home/adavidoff/git/nimph/deps/pkgs/cutelog-1.1.1
/home/adavidoff/git/nimph/deps/pkgs/nimgit2-0.1.1
/home/adavidoff/git/nimph/deps/pkgs/nimterop-0.3.3
/home/adavidoff/git/nimph/deps/pkgs/regex-#v0.13.0
/home/adavidoff/git/nimph/deps/pkgs/unicodedb-0.7.2
/home/adavidoff/git/nimph/deps/pkgs/unicodeplus-0.5.0
/home/adavidoff/git/nimph/deps/pkgs/unittest2-#head
```

To pass switches to commands `run` in your dependencies, use the `--` as a stopword.

```
$ nimph run -- head -1 LICENSE
/bin/head: cannot open 'LICENSE' for reading: No such file or directory
head -1 LICENSE
head didn't like that in /home/adavidoff/git/Nim
MIT License
Copyright 2019 Ico Doornekamp <npeg@zevv.nl>
MIT License
MIT License
Copyright (c) 2015,2016,2017,2018,2019 Charles L. Blake.
MIT License
MIT License
MIT License
MIT License
MIT License
MIT License
MIT License
/bin/head: cannot open 'LICENSE' for reading: No such file or directory
head -1 LICENSE
head didn't like that in /home/adavidoff/git/nimph/deps/pkgs/unittest2-#head
```

Finally, you can use the `--git` switch to limit `run` to dependencies with
Git repositories; see [Git Subcommands](https://github.com/disruptek/nimph#git-subcommands) for examples.

### Graph

The `graph` subcommand dumps some _very basic_ details about discovered
dependencies and their associated packages and projects.

```
$ nimph graph

requirement: swayipc>=3.1.4 from xs
    package: https://github.com/disruptek/swayipc

requirement: cligen>=0.9.41 from xs
requirement: cligen>=0.9.40 from bump
    package: https://github.com/c-blake/cligen.git
  directory: /home/adavidoff/.nimble/pkgs/cligen-0.9.41
    project: cligen-#b144d5b3392bac63ed49df3e1f176becbbf04e24

requirement: dbus** from xs
    package: https://github.com/zielmicha/nim-dbus

requirement: irc>=0.2.1 from xs
    package: https://github.com/nim-lang/irc

requirement: https://github.com/disruptek/cutelog.git>=1.0.1 from xs
requirement: git://github.com/disruptek/cutelog.git>=1.1.0 from bump
    package: git://github.com/disruptek/cutelog.git

requirement: bump>=1.8.11 from xs
    package: file:///home/adavidoff/.nimble/pkgs/bump-1.8.13
  directory: /home/adavidoff/.nimble/pkgs/bump-1.8.13
    project: bump-1.8.13
```

Like other subcommands, you can provide _import names_ to retrieve the detail
for only those dependencies, or omit any additional arguments to display all
dependencies.

```
$ nimph graph cligen

requirement: cligen>=0.9.41 from xs
requirement: cligen>=0.9.40 from bump
    package: https://github.com/c-blake/cligen.git
  directory: /home/adavidoff/.nimble/pkgs/cligen-0.9.41
    project: cligen-#b144d5b3392bac63ed49df3e1f176becbbf04e24
```

Raising the log level of the `graph` command will cause retrieval and display
releases and any _other_ commits at which the package changed versions.

```
$ nimph graph --log=lvlInfo nimterop

requirement: nimterop>=0.3.3 from nimgit2
    package: https://github.com/genotrance/nimterop.git
  directory: /home/adavidoff/git/nimph/deps/pkgs/nimterop-0.4.0
    project: nimterop-#v0.4.0
tagged release commits:
    tag: v0.1.0               commit-c3734587a174ea2fc7e19943e6d11d024f06e091
    tag: v0.2.0               commit-3e9dc2fb0fd6257fd86897c1b13f10ed2a5279b4
    tag: v0.2.1               commit-e9120eee7840851bda8113afbc71062b29fff872
    tag: v0.3.0               commit-37f5faa43d446a415e8934cc1a713bb7f5c5564f
    tag: v0.3.1               commit-1bca308ac472796329c212410ae198c0e31d3acb
    tag: v0.3.2               commit-12cc08900d1bfd39579164567acad75ca021a86b
    tag: v0.3.3               commit-751128e75859de66e07be9888c8341fe3b553816
    tag: v0.3.4               commit-c878a4be05cadd512db2182181b187de2a566ce8
    tag: v0.3.5               commit-c4b6a01878f0f72d428a24c26153723c60f6695f
    tag: v0.3.6               commit-d032a2c107d7f342df79980e01a3cf35194764de
    tag: v0.4.0               commit-f71cf837d297192f8cddfa136e8c3cd84bbc81eb
untagged version commits:
    ver: 0.2.0                commit-3a2395360712d2c6f27221e0887b7e3cad0be7a1
    ver: 0.1.0                commit-9787797d15d281ce1dd792d247fac043c72dc769
```

### Git Subcommands

There are a couple shortcuts for running common git commands inside your
dependencies:

- `nimph fetch` is an alias for `nimph run -- git fetch`; ie. it runs `git fetch` in each dependency package directory.
- `nimph pull` is an alias for `nimph run -- git pull`; ie. it runs `git pull` in each dependency package directory.

### Nimble Subcommands

Any commands not mentioned above are passed directly to an instance of `nimble`
which is run with the appropriate `nimbleDir` environment to ensure that it will
operate upon the project it should.

You can use this to, for example, **refresh** the official packages list, run **test**s, or build **doc**umentation for a project.

```
$ nimph refresh
Downloading Official package list
    Success Package list downloaded.
```

## Hacking

Virtually all constants in Nimph are recorded in a single `spec` file where
you can perform quick behavioral tweaks. Additionally, these constants may be
overridden via `--define:key=value` statements during compilation.

Notably, compiling `nimph` outside `release` or `danger` modes will increase
the default log-level baked into the executable. Use a `debug` define for even
more spam.

Interesting procedures are exported so that you can exploit them in your own
projects.

Compilation flags to adjust output colors/styling/emojis are found in the
project's `nimph.nim.cfg`.

## Choose Nimph, Choose Nim!

The `choosenim` tool included in Nimph allows you to easily switch a symbolic
link between adjacent Nim distributions, wherever you may have installed them.

### Installing `choosenim`
1. Install [jq](https://stedolan.github.io/jq/) from GitHub or wherever.
1. Add the `chosen` toolchain to your `$PATH`.
1. Run `choosenim` against any of your toolchains.
```
# after installing jq however you please...
$ set --export PATH=/directory/for/all-my-nim-installations/chosen:$PATH
$ ./choosenim 1.0
Nim Compiler Version 1.0.7 [Linux: amd64]
Compiled at 2020-04-05
Copyright (c) 2006-2019 by Andreas Rumpf

git hash: b6924383df63c91f0ad6baf63d0b1aa84f9329b7
active boot switches: -d:release
```

### Using `choosenim`
To list available toolchains, run `choosenim`.
```
$ choosenim
.
├── 1.0
├── 1.2
├── chosen -> 1.2
├── devel
└── stable -> 1.0
```
Switch toolchains by supplying a name or alias.
```
$ choosenim 1.2
Nim Compiler Version 1.2.0 [Linux: amd64]
Compiled at 2020-04-05
Copyright (c) 2006-2020 by Andreas Rumpf

git hash: 7e83adff84be5d0c401a213eccb61e321a3fb1ff
active boot switches: -d:release
```
```
$ choosenim devel
Nim Compiler Version 1.3.1 [Linux: amd64]
Compiled at 2020-04-05
Copyright (c) 2006-2020 by Andreas Rumpf

git hash: b6814be65349d22fd12944c7c3d19fd8eb44683d
active boot switches: -d:release
```
```
$ choosenim stable
Nim Compiler Version 1.0.7 [Linux: amd64]
Compiled at 2020-04-05
Copyright (c) 2006-2019 by Andreas Rumpf

git hash: b6924383df63c91f0ad6baf63d0b1aa84f9329b7
```

### Hacking `choosenim`
It's a 20-line shell script, buddy; go nuts.

## Documentation

See [the documentation for the nimph module](https://disruptek.github.io/nimph/nimph.html) as generated directly from the source.

## License
MIT
