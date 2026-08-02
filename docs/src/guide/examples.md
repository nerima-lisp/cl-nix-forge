# Examples

`examples/` doubles as this library's own test suite: every directory below
contributes `packages`, `checks` and sometimes `devShells` to the flake, and
`flake.nix` rejects two examples that try to publish the same name rather
than letting one shadow the other.

That is the reason to read them. Each one is a worked flake fragment *and* a
gate — a change to `lib/` that no example exercises is a change nothing
verifies.

## The catalogue

### `simple-library/`

A single-system leaf exercising `fromAsdSystem`, `mkTestCheck`,
`mkDocsSite`, `mkDevShell`, `lispWithSystems`, `lispScript`, a direct
`lispBuildOp` override, and an executable whose ASDF and installed names
differ.

It also carries the negative tests for the implementation boundary: an ECL
`lispWithSystems` refusing an SBCL-built system, an SBCL derivation refusing
a mismatched `lispImplementation`, an implementation with no row in the
`lispImplementations` table being rejected by `lispDerivation` and
`lispScript` alike, and `fromNixpkgsLisp` refusing a bare derivation. Each
negative pairs `tryEval` with a positive control asserted in the same check,
because `tryEval` reports only `success` and never the message: a typo in the
subject expression fails exactly like the defect under test.

### `multi-system-repo/`

Two systems in one source tree, one depending on the other, exercising
`lispMultiDerivation`, `fromDerivation`, and `core/dedup.nix`'s merge path.

### `native-library-consumer/`

A native shared library, a direct consumer, and a consumer of that consumer,
proving the search path propagates two hops without the middle package
needing to know about it. The test loads the shared library through CFFI and
calls its exported symbol.

### `asd-search-path/`

An ASDF definition below the source root, proving `lispAsdPath` makes both
its build and `asdf:test-system` discoverable.

### `check-only-dependencies/`

A test-only ASDF dependency resolved through `lispCheckDependencies` during
`doCheck`, while the normal derivation has no dependency closure for that
support system.

### `multi-lisp-matrix/`

One system tested under both SBCL and ECL plus an external (non-Lisp) tool
dependency, via `mkCheckMatrix`.

### `checks-and-coverage/`

A system whose `.asd` defines a `test-op` that errors on purpose, so that a
passing `mkScriptCheck` is itself proof the check never routed through
`asdf:test-system`.

Covers both entry-point forms, a `mkCommandCheck` producing JSON, text and
directory artifacts (one filename contains a space, which survives only
because `command` is an argv list), and an `mkCoverageReport`.

Its failure paths are proved, not assumed: a deliberately failing entry point
and a runaway loop killed by its time limit each run the real check phase
inside a wrapper that passes only when that phase failed with an expected
exit status — 1 for the failure, and 124 or 137 for the timeout, depending on
whether SIGTERM was enough or the SIGKILL grace period had to expire.

### `flake-outputs/`

The flake surface a downstream repo actually writes: `mkLispSource`,
`mkApp`, `mkTestApp`, `mkOverlay`, a `mkDocsSite` with caller-supplied
identity, and an `mkExecutable` with a non-default dynamic space size and an
extra image module.

Nothing is asserted in a comment. Planted `.fasl`/`.core`/`coverage-report-*`
fixtures are proved absent from the filtered source and `t/` proved present
by listing it; the test app is run twice, once against a suite that passes
and once against one that fails; and the delivered binary prints its own
argv, dynamic space size and loaded modules so the checks can assert on all
three.

### `org-preset/`

[`mkPackageFlake`](../reference/outputs.md#mkpackageflake) — the org standard
as one call — driven against a real ASDF tree from twenty checks, which is
the largest example here because the preset is the largest function.

It builds several instances of the preset from one shared argument set and
asserts what distinguishes them: the generated `checks.default` really is the
package's own `run-tests.lisp` (the check *is* the generated derivation,
built verbatim), and a copy pointed at a deliberately failing runner is
proved to fail. A `formatter` and a `checks.formatting` are proved to come
from the same treefmt evaluation, by a stub module that plants a marker both
must carry. An instance declaring no `docs` and no `treefmt` is asserted to
have *no* `packages.docs`, `checks.docs` or `checks.formatting` — absence
asserted as absence, each paired with a positive control on the instance that
does declare them, since an assertion whose subject is misspelled passes
exactly like one that holds.

The escape hatches are exercised in both directions: an `extraOutputs` name
that collides with a generated one and an `overrideOutputs` name that was
never generated are each proved to be evaluation errors, while a legitimate
override *wraps* `ctx.generated.checks.default` rather than rebuilding it. On
the delivery side, an `executable` is proved to inherit the package's
`lispDependencies` without repeating them, to round-trip `packageArgs`, and
to reject `args`/`lispDerivation`. The devShell check is the one that
motivated a fix: it loads a test-only dependency in the generated shell, and
the same assertion is run against a shell built the pre-fix way to prove it
would have failed.

## Running them

```sh
nix flake check
```

builds and verifies the current host's checks.

```sh
nix flake check --no-build --no-write-lock-file
```

evaluates them without building, which is what catches an evaluation-time
assertion — several examples assert that a broken input *fails*, and those
fire during evaluation. There is no `--all-systems`: `flake.nix` declares
exactly one system, so the flag would widen nothing.

```sh
nix build .#checks.x86_64-linux.default
```

builds the whole suite through the aggregate every member is an input of.

CI runs the evaluation and then builds each check individually. What that
leaves unverified is stated in
[Platform coverage](../project/platform-coverage.md).
