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

## Opinions

- The package manager should only be used to manage the environment.  If the
environment isn't changing, the package manager doesn't need to run.
- The compiler should be used to compile programs.  It's extraordinarily powerful
and that power should be made accessible to the user whenever possible.
- The user knows best; sometimes they are just lazy.  If we can intuit their
desire, we should do their work for them.
- Git is great and GitHub is pretty decent, too; we should exploit these as
much as possible.

## Demonstration
[![asciicast](https://asciinema.org/a/aoDAm39yjoKenepl15L3AyfzN.svg)](https://asciinema.org/a/aoDAm39yjoKenepl15L3AyfzN)

## Installation
```
$ nimble install https://github.com/disruptek/nimph
```

## Details

It's worth noting that you can run `nimph` from anywhere in your project tree;
it will simply search upwards until it finds a `.nimble` file and act as if you
ran it there.

Most operations do require that you be within a project, but `nimph` is
flexible enough to operate on local dependencies, global packages, and anything
in-between.  You can run it on any package, anywhere, and it will provide useful
output (and optional repair) of the environment it finds itself in.

### Search

The `search` subcommand is used to query GitHub for packages.  Arguments should
match [GitHub search syntax for repositories](https://help.github.com/en/github/searching-for-information-on-github/searching-for-repositories) and for convenience, a `language:nim` qualifier will be included.

Results are output in **increasing order of relevance** to reduce scrolling; _the last result is the best_.

### Clone

The `clone` subcommand performs git clones to add packages to your environment.
Pass this subcommand some GitHub search syntax and it will download the best
matching package, or you can supply a URL directly.  Local URLs are fine, too.

Where the package ends up is a function of your existing compiler settings
as recorded in relevant `nim.cfg` files; we'll search any `--nimblePath`
statements to find increasingly distant directories with decreasing quantities
of packages, with the following exception:

- if you have a `deps` directory in your project, we'll use that instead

_This behavior will be changed shortly to simply clone into the last-specified
`nimblePath`, for consistency with Nimble._

### Doctor

The interesting action happens in the `doctor` subcommand.  When run without any
arguments, `nimph` effectively runs the `doctor` with a `--dry-run` option, to
perform non-destructive evaluation of your environment and report any issues.
In this mode, logging is elevated to report package versions and a summary of
their last commit or tag.

When run as `nimph doctor`, any problems discovered will be fixed, if possible.
This includes cloning missing packages for which we can determine a URL,
adjusting path settings in the project's `nim.cfg`, and similar housekeeping.

### Path

The `path` subcommand is used to retrieve the filesystem path to a package
given the Nim symbol you might use to import it. For consistency, the package
must be installed.

In contrast to Nimble, you can specify multiple symbols to search for, and the
symbols are matched without regard to underscores or capitalization.

### Nimble Subcommands

Any commands not mentioned above are passed directly to an instance of `nimble`
which is run with the appropriate `nimbleDir` environment to ensure that it will
operate upon the project it should.

You can use this to, for example, **refresh** the official packages list, run **test**s, or build **doc**umentation for a project.

## Hacking

Virtually all constants in Nimph are recorded in a single `spec` file where
you can perform quick behavioral tweaks. Additionally, these constants may be
overridden via `--define:key=value` statements during compilation.

Notably, compiling `nimph` outside `release` or `danger` modes will increase
the default log-level baked into the executable. Use a `debug` define for even
more spam.

Interesting procedures are exported so that you can exploit them in your own
projects.

## Documentation

See [the documentation for the nimph module](https://disruptek.github.io/nimph/nimph.html) as generated directly from the source.

## License
MIT
