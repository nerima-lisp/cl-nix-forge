# Flake outputs and delivery

These are the functions a downstream flake calls once, near the top level,
and then stops thinking about. `examples/flake-outputs/` is a worked version
of the whole surface.

## `mkExecutable`

Deliver a standalone binary via `asdf:program-op`.

```nix
packages.${system}.my-cli = cl.mkExecutable {
  args = {
    pname = "my-cli";
    lispSystem = "my-app";
    version = cl.fromAsdSystem ./my-app.asd;
    src = cl.mkLispSource { root = ./.; };
    lispDependencies = [ ... ];
  };
  dynamicSpaceSize = 2048;
  imageRequires = [ "sb-cover" ];
};
```

| Argument | Default | Effect |
|---|---|---|
| `args` | required | The exact attrset you would pass to `lispDerivation`, **without** `lispBuildOp` — this function sets it |
| `buildOperation` | `"asdf:operate 'asdf:program-op"` | Only used on the non-Darwin-SBCL path |
| `programPath` | `null` | Where ASDF actually wrote the program, if not the system name |
| `dynamicSpaceSize` | `null` | Megabytes of SBCL dynamic space |
| `imageRequires` | `[ ]` | Implementation modules to `(require ...)` before the image is dumped |
| `installSource` | `false` | Ship the sources under the delivered image's own prefix — see the contract below |

`args.pname` controls the installed executable name and may differ from
`lispSystem`. Exactly one system must be named, via `lispSystem` or a
single-element `lispSystems`; anything else is an evaluation error.

`args.version`, when present, reaches the store path
(`…-my-cli-1.0.1`) and the derivation's `pname`/`version`, so a delivered
binary can be told apart from the previous release's by path, and
[`mkOverlay`](#mkoverlay) can name it without re-parsing anything.

If you are writing a whole package's flake, `mkPackageFlake`'s `executable`
argument calls this for you from the arguments it already resolved, so the
package's `pname`, `version`, `src`, `meta` and `lispDependencies` are spelled
once rather than twice. Reach for `mkExecutable` directly for a delivery that
argument cannot express — and pass `args = ctx.lispDerivationArgs` when you do,
rather than restating the package.

### What `$out` contains, and what an image may assume

This contract is written down because its absence was a bug: an image that
resolved its own ASDF source root by looking for `share/common-lisp/source/`
under its installation prefix found nothing, fell back to the build-time
source directory, and died with `Failed to find the TRUENAME of
/nix/var/nix/builds/nix-…/src/package.lisp` the first time it re-loaded one of
its own systems. Both sides were individually correct and disagreed silently.

`$out` always contains `$out/bin/<pname>` — the entry point, and
`meta.mainProgram`.

With `installSource = true` it also contains:

```
$out/share/common-lisp/source/<pname>/     args.src, verbatim
$out/share/common-lisp/source/<dep>/       one directory per entry of the
                                           resolved dependency closure
```

so that one `(:tree "<prefix>/share/common-lisp/source/")` registry entry
resolves the delivered system and everything it loads. The dependency closure
is installed too, not just the system's own tree: sources that are findable
while their dependencies' are not fail at the same place, one
`asdf:load-system` later.

A delivered image may therefore assume that `share/common-lisp/source/` exists
under the installation prefix of the file it is running out of — the parent of
the directory holding `sb-ext:*runtime-pathname*` on the `program-op` path, and
of the one holding `sb-ext:*core-pathname*` on the Darwin fallback — and
nothing more. Both anchors are covered deliberately: on the Darwin fallback the
running image is a bare `.core` inside an intermediate derivation, so a tree
installed only into `$out` would sit somewhere that image cannot name. That
derivation gets the real tree and `$out` gets a symlink to it, which makes the
two views the same directory rather than two copies that can drift.

What is **not** promised: on the `program-op` path `$out` also holds the whole
built tree at its root, because that is where ASDF wrote the program and the
delivery copies the derivation wholesale. That is an artifact, not an
interface — the Darwin fallback has no such thing.

`installSource` defaults to false because it puts the source tree and its whole
dependency closure into the delivered runtime closure, which a binary that
never re-loads a system at run time should not pay for.

`programPath` exists because ASDF writes a program to the system's
`:build-pathname`, which is not necessarily `$out/bin/<system>`. That
ASDF-specific detail stays explicit at the boundary, and the Nix result is
then normalized. If the program is missing or not executable, the build fails
with a message naming the path it looked at, rather than installing nothing.

`dynamicSpaceSize` and `imageRequires` act on the Lisp that performs the
dump, and take effect on both delivery paths. They are spelled as SBCL
command-line options, so requesting them for another implementation is an
assertion failure. `imageRequires` has a preferred alternative:
`:depends-on ((:require :sb-cover))` in the `.asd` is ASDF-native, works on
both paths, and keeps a system's dependencies in the system definition. The
Nix option is for the remaining case where the *dump* needs a module the
system itself does not depend on.

### What Nix owns and what the `.asd` owns

The `.asd` owns everything about *what* is built: `:build-operation`,
`:build-pathname`, `:entry-point`, and which implementation contribs the
system needs. None of those are Nix options here, and adding them would give
a system two places to disagree about its own entry point.

Nix owns the *invocation* of the Lisp that performs the dump. Two knobs that
look like they belong in that list deliberately are not:

`save-runtime-options`

: Not an option because it cannot be turned off. `uiop:dump-image` hardcodes
`:save-runtime-options t` whenever it is dumping an executable, so the
`program-op` path always saves them; on the Darwin path SBCL documents the
flag as meaningless when `:executable` is NIL, so it is unavailable there by
construction. The observable behaviour it buys — the image starts with the
heap it was dumped with, and the runtime does not eat the user's arguments —
is instead made unconditional on both paths.

`core compression`

: Not an option because it cannot be turned on for `program-op`. ASDF's
`perform` method for an `image-op` calls `dump-image` and never passes
`:compression`, and SBCL exposes no global to change that, so the only route
would be monkey-patching an ASDF method at build time. The Darwin fallback
used to hardcode `:compression t`, which meant one `mkExecutable` call
produced a compressed, slower-starting core on Darwin and an uncompressed one
everywhere else. It now matches `program-op` and compresses nothing.

### The Darwin fallback

On Darwin with SBCL, `mkExecutable` builds a plain, non-executable `.core`
via `save-lisp-and-die` and wraps `sbcl --core` with `makeWrapper`. The
`.asd`'s own `:entry-point` is still the source of truth on that path too,
read back through ASDF's `component-entry-point` at build time rather than
duplicated in Nix.

The evidence is one observation, recorded in `lib/batteries/app.nix` and not
to be overstated. On aarch64-darwin with SBCL 2.6.6, a bare
`(asdf:operate 'asdf:program-op "greeter-app")` under `sbcl --script` had not
completed after five minutes and had written no file at the system's
`:build-pathname`; it was killed at that point. That is "does not finish in a
workable time", not "provably never finishes". A hand-written
`sb-ext:save-lisp-and-die :executable t` on the same host completed in
seconds and produced a working binary, which places the fault in
`program-op`'s delivery rather than in SBCL's dumper. No upstream bug ID is
cited because none could be identified with confidence.

This is the branch CI never builds; see
[Platform coverage](../project/platform-coverage.md).

## `mkApp`

A flake `apps.<system>.<name>` entry for a derivation that already knows
which of its binaries is the interesting one.

```nix
apps.${system}.my-cli = cl.mkApp { drv = myCli; };
```

| Argument | Default | Effect |
|---|---|---|
| `drv` | required | Any derivation with `meta.mainProgram`, or whose `pname` is its binary name |
| `description` | `drv.meta.description` | App description |

Every downstream flake spells this out by hand, and every one of them repeats
the program name three times: in `program`, in `meta.mainProgram`, and in the
`bin/` path. `mkExecutable` and `lispScript` both already set
`meta.mainProgram`, and `lib.getExe` exists to read it, so the derivation
stays the single source of truth for its own entry point.

## `mkTestApp`

`nix run .#test` — the org-standard entry point that runs the repository's
own `run-tests.lisp`.

```nix
apps.${system}.test = cl.mkTestApp {
  pname = "my-app";
  src = ./.;
  lispDependencies = [ clWeave ];
};
```

| Argument | Default | Effect |
|---|---|---|
| `pname` | required | Project name; the runner installs as `<pname>-test` |
| `src` | required | The source tree containing `runner`; its systems shadow anything else on the registry |
| `runner` | `"run-tests.lisp"` | The entry point inside `src` |
| `lisp` | `pkgs.sbcl` | Implementation to run it with |
| `lispImplementation` | `lib.getName lisp` | Table row for that implementation |
| `lispDependencies` | `[ ]` | Other systems the suite needs — a test framework, typically |
| `timeoutSeconds` | `600` | SIGTERM deadline |
| `killAfterSeconds` | `30` | SIGKILL grace period |
| `description` | `"Run the <pname> test suite"` | App description |

This drives the script rather than `asdf:test-system`, so the plain
`sbcl --script run-tests.lisp` path a contributor uses in a REPL-less shell is
the same path CI exercises; [`mkTestCheck`](checks.md#mktestcheck) covers the
`test-system` route. It complements the check helpers: same suite, but the
`nix run` output rather than a pass/fail derivation.

The script runs from the source tree in place, because a `run-tests.lisp`
locates its own systems relative to `*load-truename*` — copying it elsewhere
would silently test whichever copy of the project happened to be on the
registry first.

The registry it builds has no trailing `:`. That is ASDF's spelling of "and
then inherit whatever is configured", which would let a developer's
`~/.config/common-lisp` make `nix run .#test` pass locally and fail in CI. An
explicitly exported `CL_SOURCE_REGISTRY` is still honoured, appended so it
cannot shadow the tree under test.

The `timeout -k` escalation matters because SBCL defers signals to
safepoints: a tight compiled loop — a runaway backtracking bug is exactly
this — outlives a bare SIGTERM and would otherwise fall through to the
enclosing CI job timeout instead of failing here with an attributable error.

## `mkOverlay`

`overlays.default` — expose this flake's packages in the `pkgs` namespace
under their own names.

```nix
overlays.default = cl.mkOverlay { packages = self.packages; };
```

| Argument | Default | Effect |
|---|---|---|
| `packages` | required | The flake's own `self.packages`, keyed by system |
| `names` | `[ "default" ]` | Which entries of `packages.<system>` to publish |

The name a package takes in `pkgs` is its `pname`, read off the derivation
rather than spelled a second time: a flake whose `packages.default` is built
by `lispDerivation` already named it once, and an overlay that repeats the
name is one rename away from exporting `pkgs.cl-weave` from a package called
something else.

`names` is not "all of them" on purpose — `packages.docs` must not become
`pkgs.docs`.

It reads the system from `prev`, not `final`. The attribute *names* here are
computed from each package's own `pname`, so evaluating the attrset's key set
forces `system`, and `final.stdenv` cannot be forced while the overlay
producing it is still being evaluated. That is an infinite recursion, and it
was reproduced before the comment recording it was written. A hand-written
overlay with literal keys gets away with `final` because its names are known
without evaluating anything; the moment it grows a second package and starts
generating names, it does not.

## `mkDevShell`

A `nix develop` shell that exports the derivation's own resolved
`CL_SOURCE_REGISTRY` and prints a short banner.

```nix
devShells.${system}.default = cl.mkDevShell {
  drv = myApp;
  extraPackages = [ pkgs.sbcl.pkgs.alexandria ];
};
```

`lispDerivation`'s result is already a usable shell — it carries the right
`buildInputs`. `mkDevShell` adds the two things a raw derivation cannot:
interactive-only packages that do not become part of the *build*, and a
banner so `nix develop` is not silent about what it just set up. Plus the one
thing `inputsFrom` alone gets wrong.

That last one: `lispDerivation` exports its search path by having its
`shellHook` `eval "$setAsdfPathPhase"`, and `mkShell` copies shellHook *text*
out of `inputsFrom` but not the derivation's environment — so
`$setAsdfPathPhase` arrived empty and the eval silently did nothing. The
banner claimed `CL_SOURCE_REGISTRY` was set while it was in fact unset and
`(asdf:load-system ...)` failed. It is now set here from the derivation's own
resolved `registryPath`: same value, same order, including the literal `$PWD`
entry that makes the tree you are standing in take precedence, and
prepending any registry the caller had already exported exactly as the build
does.

`ASDF_OUTPUT_TRANSLATIONS` is deliberately left alone. The build sets it to
the identity mapping so fasls land beside their sources and the output stays
reusable as a registry entry; a REPL wants the opposite, because fasls
dropped into the working tree are precisely the artefacts `mkLispSource` then
has to keep back out of the store. Left unset, ASDF caches under
`~/.cache/common-lisp`.

The registry it exports is `drv`'s, so `drv` decides whether
`lispCheckDependencies` are on it: `lispDerivation` resolves them only when
`doCheck` is true and drops them entirely when it is not. Pass
`drv = myApp.enableCheck` — the same derivation with checks on, which is also
what [`mkScriptCheck`](checks.md#mkscriptcheck) builds a check from — whenever
the shell is meant to run the suite, or the test system will not load in it.
That costs no build: `inputsFrom` takes a derivation's *inputs*, not its
output, so nothing realises `enableCheck` itself; the check dependencies are
pulled in, and the check that runs the suite builds those anyway.
`mkPackageFlake`'s generated `devShells.default` does exactly this.

A `pkgs.sbcl.withPackages`-built Lisp in `extraPackages` composes, which was
not obvious and was checked: `mkShell` puts `packages` ahead of everything
from `inputsFrom` on `PATH`, so the wrapped Lisp wins over the plain one the
derivation pulls in, and nixpkgs builds that wrapper with
`--prefix CL_SOURCE_REGISTRY` rather than `--set`, so its packages prepend to
the registry exported here rather than replacing it.

## `mkDocsSite`

A generic mkdocs-material site builder.

```nix
packages.${system}.docs = cl.mkDocsSite {
  root = ./docs;
  pname = "my-app-docs";
  version = cl.fromAsdSystem ./my-app.asd;
  meta = {
    description = "Rendered documentation for my-app";
    homepage = "https://github.com/nerima-lisp/my-app";
    license = lib.licenses.mit;
  };
};
```

| Argument | Default | Effect |
|---|---|---|
| `root` | required | The directory `mkdocsYmlName` lives in |
| `fileset` | `null` | A fileset, when the docs need something outside `root` |
| `pname` | `"docs-site"` | By convention `<project>-docs` |
| `version` | `"unstable"` | nixpkgs' spelling of "no meaningful version" |
| `meta` | `{ }` | description / homepage / license |
| `strict` | `true` | Promote broken links and pages missing from the nav to build failures |
| `mkdocsYmlName` | `"mkdocs.yml"` | Config file name inside `root` |

It deliberately does not guess at any one project's fileset shape. Pass
`fileset`, built with `lib.fileset.unions` like any other Nix project, when
the docs read something outside `root` — a repo-root `CHANGELOG.md` that a
changelog page snippet-includes, for instance — and plain `root` for the
common single-directory case. That one optional argument is what collapses
two docs conventions that grew independently into one function.

Identity is the caller's, not this function's. The site is a package a
project publishes under its own name and version — it appears in
`nix flake show`, in a store path, and in whatever deploys it — so baking in
`docs-site`/`unstable` made every consumer that cared reject the helper and
hand-write the derivation again. `version` pairs naturally with
[`fromAsdSystem`](versions.md#fromasdsystem), so the `.asd` stays the one
place a release number is edited.

`strict` defaults to true because `mkdocs build --strict` turns a broken link
or a page missing from the nav into a build failure. Material bundles its own
assets, so the build needs no network either way. This documentation site is
itself built by this function.

## `collect`

Pull a named set of sibling packages out of flake inputs.

```nix
lispDependencies = builtins.attrValues (cl.collect {
  flakeInputs = inputs;
  names = [ "cl-weave" "cl-json-kit" ];
  inherit system;
});
```

The real fix for cross-repository composition is not a bigger helper: once a
sibling repository's own flake exposes its package, it is an ordinary
`lispDependencies` entry and no bespoke registry-string merging is needed at
all. This is only a naming-convention shorthand for "pull the default package
out of each of these flake inputs by name", so a downstream flake does not
reinvent yet another way to spell that. `names` must be attribute names
shared by both `flakeInputs` and each input's own `packages.<system>`.
