# Checks and coverage

The builders that build or run Lisp code (`mkTestCheck`, `mkScriptCheck`,
`mkCommandCheck` and `mkCoverageReport`) use `lispDerivation`'s own
[`enableCheck`](building.md#what-the-result-carries), which sets
`doCheck = true`. Each check process uses the derivation's build environment,
including its resolved [`CL_SOURCE_REGISTRY`](building.md#implementation-and-operation-arguments),
[`lispCheckDependencies`](building.md#dependency-arguments), transitive
native-library environment, and writable working tree. `mkCommandCheck` and
`mkCoverageReport` define their `$out` contents separately, as described below.

`mkScriptCheck`, `mkCommandCheck` and `mkCoverageReport` all accept
`timeoutSeconds` (default `null`, meaning no limit) and `killAfterSeconds`
(default `30`). SBCL defers signals to safepoints, so a tight compiled loop
outlives a bare SIGTERM; the grace period escalates to SIGKILL rather than
letting the run fall through to the enclosing CI job timeout, where the
failure is no longer attributable.

The two checks below inspect repository files without loading the
repository's Lisp source or running its tests. A pass establishes only the
structural properties each check reads.

## `mkFeatureLintCheck`

Check a repository's feature declarations, package boundaries, glossary, and
export surface without executing its Lisp source or tests.

1. Feature declarations match the glossary headings, package declarations,
   source directories, and test directories.
2. Configured forbidden path and package components, and numbered prefixes,
   are absent.
3. Package imports and qualified references resolve to declared features;
   dependency edges are declared and acyclic.
4. Facade references resolve to an owning feature package and exported symbol.
5. Cross-feature `package::symbol` references match the path, package, symbol,
   and maximum count in `legacyInternalRefs` during `transition`. `strict`
   permits none and requires that file's list to be empty.
6. A domain package does not depend directly on its feature's infrastructure
   package.
7. Glossary key types and functions are exported by the feature package and
   included in the expected export surface.

The scanner parses source as data without evaluating Lisp forms or interning
package names. It accepts standard Common Lisp reader syntax. For `#+` and
`#-`, it parses the feature expression and scans the following form without
selecting a feature set; both conditional bodies are checked. It consumes
`#.` forms without evaluation. Literal contents do not count as feature
declarations or package references. Unreadable `#<` objects and unsupported
sharpsign dispatch syntax fail with a source location. The scanner does not
consult or execute user-defined readtables or reader macros.

Pass `src` as a path or absolute path string. Every other path argument is
relative to the root of `src`. Repository rules such as package prefixes
and forbidden names come from the caller; the example supplies its package
rules explicitly, and none of them is a cl-nix-forge default.

| Argument | Default | Effect |
|---|---|---|
| `src` | required | Path or absolute path string for the source tree to inspect |
| `featureDefinitions` | required | Relative path to the S-expression feature dependency declarations |
| `glossary` | required | Relative path to the Markdown feature glossary |
| `glossaryHeadingPrefix` | required | Text prepended to each feature slug to form its glossary heading |
| `exportSurface` | required | Relative path to the expected package export snapshot |
| `mode` | required | `transition` permits only recorded legacy internal references up to their maximum counts; `strict` permits none and requires `legacyInternalRefs` to be empty |
| `legacyInternalRefs` | required | Relative path to a list of legacy facade `package::symbol` references, keyed by source path, package, symbol, and maximum permitted occurrence count |
| `forbiddenNames` | required | List of exact path or package components that must not appear |
| `numberedPrefixes` | required | List of prefixes rejected when followed by one or more ASCII digits in a path or package component |
| `packagePrefix` | required | Prefix required for repository-local package names |
| `infraSuffix` | required | Suffix that identifies infrastructure-layer packages |
| `name` | `"feature-lint"` | Check derivation name |

`featureDefinitions` is a list of feature records. Each record supplies the
feature slug, source directories, test directory, facade packages, domain
package, optional infrastructure package, and dependency slugs:

```lisp
((:feature "nodes"
  :source-dirs ("src/nodes")
  :test-dir "t/nodes"
  :facade-packages ("cl-cc/ast")
  :domain-package "cl-cc/ast/nodes"
  :infra-package nil
  :depends-on ()))
```

`exportSurface` is one list containing symbol records. Each `:keep` record
contains the facade package, feature package, expected home package, and symbol
name as strings. `:add` and `:remove` records have the same fields plus a
string containing the changelog heading anchor. For example:

```lisp
((:symbol :keep "cl-cc/ast" "cl-cc/ast/nodes" "cl-cc/ast/nodes" "MAKE-NODE")
 (:symbol :add "cl-cc/ast" "cl-cc/ast/nodes" "cl-cc/ast/nodes" "NODE" "CHANGELOG.md#anchor")
 (:symbol :remove "cl-cc/ast" "cl-cc/ast/nodes" "cl-cc/ast/nodes" "OLD-NODE" "CHANGELOG.md#anchor"))
```

`:keep` rows contain the facade, feature, home-package, and symbol names.
`:add` and `:remove` rows also require a `CHANGELOG.md#...` anchor. For each
glossary API, feature-lint checks that the symbol appears in the source package's
exports and in the snapshot built from `:keep` and `:add` rows. Each
repository's snapshot test owns the full comparison between facade exports and
their home packages.

`legacyInternalRefs` is a list of records shaped like
`(:ref "t/nodes/internal-check.lisp" "cl-cc/ast" "%NODE-COUNT" 2)`, where
the last value is the maximum number of matching references. The
`featureDefinitions`, `exportSurface`, and `legacyInternalRefs` files each
contain one S-expression and are read as data with reader evaluation disabled.

```nix
checks.${system}.feature-lint = cl.mkFeatureLintCheck {
  src = ./.;
  featureDefinitions = "nix/feature-dependencies.sexp";
  glossary = "docs/src/reference/glossary.md";
  glossaryHeadingPrefix = "## ";
  exportSurface = "t/export-surface.txt";
  mode = "transition";
  legacyInternalRefs = "t/legacy-internal-refs.sexp";
  forbiddenNames = [ "phases" "misc" "utils" "helpers" ];
  numberedPrefixes = [ "FR-" "W" ];
  packagePrefix = "cl-cc/ast/";
  infraSuffix = "/infra";
};
```

## `mkOrphanTestCheck`

Compare the Lisp files under configured test roots with the files registered
by the named ASDF test systems. The builder combines all listed systems
before comparing the sets in both directions, so a registered file must
exist under a root and every `.lisp` file under a root must be registered.

All roots and allowlist entries are relative to `src`. The check reads the
ASDF test-system declarations and source tree; it does not run the test
systems.

The static reader accepts literal `defsystem` declarations and recursively
follows literal `:module`, `:file`, `:cl-source-file`, and `:static-file`
components. Unsupported forms, options, or component kinds fail closed. Each
allowlist path must name an existing `.lisp` file under a configured root; it
cannot suppress a missing registered component.

| Argument | Default | Effect |
|---|---|---|
| `src` | required | Path or absolute path string for the source tree containing ASDF systems and test files |
| `testRoots` | required | Non-empty list of relative directories whose `.lisp` files are compared with ASDF components |
| `testSystems` | required | Non-empty list of ASDF test-system names; components from all systems are combined before comparison |
| `allowlist` | `[ ]` | Existing `.lisp` paths under configured roots that suppress only the unregistered-file diagnostic |
| `name` | `"orphan-tests"` | Check derivation name |

Some repositories have multiple test systems with files under the same test
root. List each system so the builder combines their components before
comparing them with that root:

```nix
checks.${system}.orphan-tests = cl.mkOrphanTestCheck {
  src = ./.;
  testRoots = [ "t" ];
  testSystems = [ "cl-cc-mir/test" "cl-cc-target/test" ];
};
```

## `mkTestCheck`

A named `checks.<system>.<name>` for a derivation's `asdf:test-system` path.

```nix
checks.${system}.my-app = cl.mkTestCheck myApp;
```

It is exactly `drv.enableCheck`. The function gives each enabled check a named
`checks` attribute instead of leaving a bare `.enableCheck` property access in
the flake.

For a suite that cannot be driven by an enclosing `test-op`, or that needs a
time limit, use `mkScriptCheck`.

## `mkScriptCheck`

Run a check through an arbitrary Lisp entry point instead of
`asdf:test-system`.

```nix
checks.${system}.my-app = cl.mkScriptCheck {
  drv = myApp;
  entryPoint = "run-tests.lisp";   # default
  timeoutSeconds = 600;
};
```

| Argument | Default | Effect |
|---|---|---|
| `drv` | required | A `lispDerivation` result; its `lispCheckDependencies` are pulled in |
| `entryPoint` | `"run-tests.lisp"` | A Lisp file inside the source tree, relative to its root |
| `entryPointText` | `null` | Inline Lisp source instead; mutually exclusive with `entryPoint` |
| `timeoutSeconds` | `null` | SIGTERM deadline |
| `killAfterSeconds` | `30` | SIGKILL grace period after that deadline |
| `name` | `null` | Derivation `pname`; defaults to the built system's `pname` plus `-script-check` |

Passing both `entryPoint` and `entryPointText`, an absolute `entryPoint`, or
an empty `entryPoint`, is an evaluation error. The default name keeps a `mkTestCheck`
and a `mkScriptCheck` over the same system distinguishable in a build log.

### Why this is not just `doCheck`

An enclosing `test-op` is not neutral. [cl-weave](https://github.com/nerima-lisp/cl-weave),
the Common Lisp test framework used here, has a suite that performs `test-op`
on `cl-weave/test` directly to assert ASDF's failure path. Driving that suite
from an enclosing `test-op` puts the same operation on the ASDF operation plan
twice, and ASDF rejects it as a circular dependency. This suite cannot run
through `asdf:test-system` for that reason.

`run-tests.lisp` is the default entry point. Using the same command developers
run by hand (`sbcl --script run-tests.lisp`) keeps the CI gate aligned with
local runs.

## `mkCommandCheck`

Run a command against a built system, assert it produced named artifacts,
validate them, and publish the artifacts — and only the artifacts — as the
check's `$out`, so CI can retrieve them.

```nix
checks.${system}.report = cl.mkCommandCheck {
  drv = myApp;
  name = "my-app-junit";
  command = [ "${cli}/bin/my-cli" "--junit" "my-app-junit.xml" ];
  artifacts = [ "my-app-junit.xml" ];
  validationCommands = [ "xmllint --noout my-app-junit.xml" ];
  nativeBuildInputs = [ pkgs.libxml2 ];
};
```

| Argument | Default | Effect |
|---|---|---|
| `drv` | required | Supplies the working tree, resolved registry and native-library environment |
| `name` | required | A single system routinely has ten of these, so a derived name would collide |
| `command` | required | argv, as a **list** |
| `artifacts` | `[ ]` | Paths resolved from the working directory of `checkPhase`, the built source tree; files or directories |
| `validationCommands` | `[ ]` | Shell snippets run after the artifacts are asserted |
| `nativeBuildInputs` | `[ ]` | The validators — `pkgs.jq`, `pkgs.libxml2`, `pkgs.perl`, … |
| `timeoutSeconds` | `null` | Optional time limit for the command; validation commands are not included |
| `killAfterSeconds` | `30` | Grace period after the time limit before SIGKILL |

`command` is a list of argv items, never a concatenated shell string. The list
preserves spaces and shell metacharacters such as `>` inside an argument rather
than letting the shell interpret them. A non-list, empty, or non-string-element
`command` is an evaluation error.

Every artifact is asserted **present and non-empty**. Presence alone is not
the property anyone wants: a reporter that opens its output file and then
dies leaves a zero-byte JSON document behind, and `test -e` is perfectly
happy with it. A directory artifact is non-empty when it has at least one
entry — `test -s` on a directory reports its inode size and is meaningless.

Artifacts keep their relative layout under `$out`, so a check writing
`reports/summary.json` does not silently flatten to `$out/summary.json` and
collide with another artifact of that name. A single trailing slash on an
artifact path is removed; multiple trailing slashes are an error.

Validation runs after the artifacts are known to exist, and outside the
command's time limit. The limit exists for the Lisp process's runaway risk;
folding a validator into it could report a slow validator as a suite timeout.

## `mkCheckMatrix`

A declarative matrix for running one test suite under multiple Lisp
implementations. It replaces per-package `meta.broken` predicates when a
suite needs to run under more than one Lisp.

```nix
checks.${system} = cl.mkCheckMatrix {
  args = {
    lispSystem = "my-app";
    src = cl.mkLispSource { root = ./.; };
  };
  lisps = [ "sbcl" "ecl" ];
  lispPackages = { inherit (pkgs) sbcl ecl; };
  expect.ecl.expectedFailure = true;
};
```

| Argument | Default | Effect |
|---|---|---|
| `args` | required | The attrset you would pass to `lispDerivation`, **without** `lisp`/`lispImplementation`/`doCheck` — this function sets those per entry |
| `lisps` | `[ "sbcl" ]` | Which implementations to run under; each must be a key of `lispPackages` |
| `lispPackages` | required | `{ <name> = derivation; }` — the package for each name |
| `externalBins` | `[ ]` | Non-Lisp tools the suite shells out to, added to every entry's `nativeBuildInputs` |
| `expect` | `{ }` | `{ <name> = { skip ? false; expectedFailure ? false; }; }` |

Returns `{ "<name>-check-<lisp>" = derivation; }`, one entry per non-skipped
implementation, meant to be spliced into `checks.<system>`. The base name is
`args.pname`, or `args.lispSystems` (falling back to `args.lispSystem`) joined
with `-`.

`lispPackages` is kept separate from the `lisps` name list so the same name
set can point at different package sources — nixpkgs stable versus a nightly
override — without touching call sites. A name with no entry is an error
naming the missing key.

`skip` omits an implementation's check entirely, via `builtins.trace` so a
skip is never silent. If both flags are true, `skip` takes precedence.
`expectedFailure` still runs the check. An expected failure is logged and does
not fail `nix flake check`. If the check passes, the build log says to remove
the `expectedFailure` flag; the unexpected pass does not fail the build.

## `mkCoverageReport`

An sb-cover HTML report as a derivation whose `$out` **is** the report.

```nix
checks.${system}.coverage = cl.mkCoverageReport {
  drv = myApp;
  systems = [ "my-app" ];
};
```

| Argument | Default | Effect |
|---|---|---|
| `drv` | required | A `lispDerivation` result built with SBCL |
| `systems` | `drv.lispSystems` | Which systems to instrument — what the report is *about* |
| `entryPoint` | `"run-tests.lisp"` | How to exercise the instrumented code |
| `entryPointText` | `null` | Inline Lisp entry point; omit `entryPoint` when setting this |
| `name` | `null` | `pname`; defaults to the built system's `pname` plus `-coverage` |
| `timeoutSeconds` | `null` | Optional time limit for the coverage runner |
| `killAfterSeconds` | `30` | Grace period after the time limit before SIGKILL |

**SBCL only.** sb-cover is an SBCL contrib with no counterpart in ECL or any
other implementation, so this throws during evaluation for a derivation built
with anything else. Producing an empty report, or silently skipping, would
leave a green check attesting to nothing.

It owns the load-bearing sequence:

```lisp
(declaim (optimize sb-cover:store-coverage-data))
(asdf:load-system "<sys>" :force t)
(declaim (optimize (sb-cover:store-coverage-data 0)))
```

Instrumentation is a *compile*-time property: only code compiled while
`store-coverage-data` is in effect records anything. The build phase already
compiled the system without it, so `:force t` is not a performance knob —
without it ASDF finds the existing fasls current, loads them, and the report
comes back empty. `:force t` forces this system alone and not its
dependencies, so a dependency's fasls are reused and its files stay out of
the report. The second `declaim` restores the default before the suite is
compiled, so the report measures the library and not the tests.

The generated coverage runner writes the report under `unwind-protect` because
`run-tests.lisp` may end in `(uiop:quit N)`, which unwinds on SBCL. It still
produces a report when the suite fails.

The result asserts its own `cover-index.html` is non-empty before installing
it, so it doubles as `checks.coverage` with no wrapper derivation.

### No minimum-coverage threshold

There is no agreed project target for a minimum coverage percentage, so the
report shows the measure without making it a merge gate.

And sb-cover offers no supported way to implement one. `sb-cover:report`
returns the index pathname and nothing else, so a percentage gate would mean
scraping SBCL's generated HTML — a coupling to a report template with no
stability guarantee. A project that wants a gate should compute the ratio in
its own Lisp code and wire it up with `mkCommandCheck`.
