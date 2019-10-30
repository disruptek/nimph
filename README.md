# nimph
a distribution generator for nim package hierarchies

## Some Goals

- Merge `git` and `nimble`: Provide better access to functionality we already
  rely upon while adding reusable distribution assets that can be more easily
  allowed through firewalls.

- Decentralized and open implementation. Anyone can serve a distribution with
  any contents of any size, which may nonetheless be vetted against the sources
  from which it is comprised.

- Specify any versions, sources, or commits you want: We'll optimize them to
  reduce the likelihood that you need to:
  - change the URL/signature of your distribution
  - re-test compatibility between updates

- Add ease, not roadblocks: You don't need `nimph` in order to install and use
  a distribution, though it helps.  It's still `nimble`, but it has tests, docs,
  and everything else you might expect from `nimble develop`.

- We should be able to offer update recommendations based upon available
  distribution combinations, public traffic/stars figures, release tags, and so
  on.

- If Araq's not watching too closely, we might even be able to shadow system
  packages using symbolic links.

## Theory of Operation

We make some assumptions:

- Older is better: Given any two distributions, the distribution modified least
  recently is also the least likely to be modified in the future. You might be
  able to convince me that we can determine seniority some other way; if you
  think you've got a better idea, have at it!

- Distributions satisfy all their dependencies: Given any two packages, if
  the second depends upon the first, then it may not be included in a parent
  distribution of the first. Duh.

- Every package has a `git` hash, regardless of how it was installed. With
  this unique hash of the code, we can both compute and verify distribution
  sources.

- The cost of verifying compatibility between one newer package and two older
  packages is likely greater than the cost of verifying compatibility between one
  newer package and a distribution of those same two older packages, especially
  since the distribution may be similarly tested for compatibility against many
  other newer packages.

- The most ideal format for a distribution is a single immutable file.

The assumptions inform the structure:

Every distribution is a single file comprised of:
  1. some packages that can co-exist in Nimble
  1. an optional parent distribution (see 1.)

Given any such set of packages, we can nest them into multiple distributions
according to their dependencies and then their age; each subsequent
distribution will exactly reproduce all those that parent it.

For three packages ordered by age, from least- to most- recently-modified:

  - A
  - B
  - C

and their dependencies, each line representing a package:

  - B1
  - B2
    - C
  - C1

they may be nested into as many as three distributions thusly:

  - **child distribution**
    - B
    - B1 is a dependency of B
    - B2 is a dependency of B
    - _parent distribution_
      - C is a requirement of B2
      - C1 is a dependency of C
      - _grand-parent distribution_
        - A is the oldest (no dependencies)

Any number of distributions can piggy-back on this form, both predicting and
exploiting pre-existing distributions A and C when creating a distribution D
which does not require B.

## Creating a New Distribution

#### What You Type

```
$ nimph init
```

#### What it Does
- initializes an empty distribution
- points the compiler at this tree of packages

## Installing a Distribution

#### What You Type
```
$ nimph init /some/distribution.file
```

#### What it Does
- installs a distribution to its own private tree
- points the compiler at this tree of packages


## Extending a Distribution

You add and remove packages using `nimble` pass-through commands which do what
you might expect.

#### What You Type
```
$ nimph install arraymancer npeg@0.18.0 cligen@0.9.40
```

#### What it Does

- installs current version of arraymancer
- installs npeg version 0.18.0
- installs cligen version 0.9.40
- installs any dependencies of these packages


## Tweaking a Distribution

You can also issue arbitrary `git` commands which largely pass-through
naturally.

#### What You Type
```
$ nimph pull npeg
```

#### What it Does

- does a `git pull` in the npeg package

## Creating a Private Distribution

You can turn your package tree into one or more local distribution files
by specifying an output directory.

#### What You Type
```
$ nimph nest --directory /my/distributions
```

#### What it Does

- creates the series of nesting distributions
- writes any distributions which don't yet exist


## Creating a Public Distribution

You can turn your package tree into one or more distribution files stored in
the cloud.

#### What You Type
```
$ nimph nest --s3 some-bucket
```

#### What it Does

- creates the series of nesting distributions
- uploads any distributions which don't exist in the bucket


## Vetting a Public Distribution

You can test a public distribution's packages to see that its contents match
sources hosted elsewhere.

#### What You Type
```
$ nimph vet /some/distribution.file
```

#### What it Does

- recursively unpacks the distribution, comparing sources and hashes to those
  found online


## Migrating to a New Distribution

We can improve upon a naive tree walk when migrating distributions.

#### What You Type
```
$ nimph migrate https://some/distribution.file
```

#### What it Does

- installs a new distribution based at a shared root
- removes packages in old tree which aren't in the new tree


## Comparing Distributions

You can compare a distribution file to an installed distribution.

#### What You Type
```
$ nimph compare /some/distribution.file
```

#### What it Does

- recursively unpacks the distribution, comparing sources and hashes to those
  found locally to highlight differences


## Combining Distributions

You can merge an arbitrary numble of distributions.

#### What You Type
```
$ nimph combine /some/distribution.file
```

#### What it Does

- it's essentially a non-destructive `nimph init`


## Checking a Distribution

You can run a sanity check against a distribution to look for misconfiguration.

#### What You Type
```
$ nimph check
```

#### What it Does

- run a check against every package in the distribution


## Testing a Distribution

You can run tests across an entire distribution.

#### What You Type
```
$ nimph test
```

#### What it Does

- run tests for every package in the distribution


## Documenting a Distribution

You can generate documentation for an entire distribution.

#### What You Type
```
$ nimph doc /my/documentation
```

#### What it Does

- generate docs for every package in the distribution and throw them into /my/documentation
