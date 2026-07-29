# Checks and coverage

Every function here builds on `lispDerivation`'s own `enableCheck` — the same
derivation with `doCheck = true`. None of them creates a fresh derivation
that would have to recompute the resolved `CL_SOURCE_REGISTRY`, the
`lispCheckDependencies`, the transitive native-library environment, the
identity output translations, or the writable working tree already holding
the compiled fasls. Recomputing any of that would be a second, silently
divergent copy.

`mkScriptCheck`, `mkCommandCheck` and `mkCoverageReport` all accept
`timeoutSeconds` (default `null`, meaning no limit) and `killAfterSeconds`
(default `30`). SBCL defers signals to safepoints, so a tight compiled loop
outlives a bare SIGTERM; the grace period escalates to SIGKILL rather than
letting the run fall through to the enclosing CI job timeout, where the
failure is no longer attributable.

## `mkTestCheck`

A named `checks.<system>.<name>` for a derivation's `asdf:test-system` path.

```nix
checks.${system}.my-app = cl.mkTestCheck myApp;
```

It is exactly `drv.enableCheck`. There is no "copy the read-only store path
to a writable tree" step to reinvent the way older hand-rolled flake test
harnesses needed, because a Nix build's working directory is already a
private writable copy. The function exists so that a `checks` attribute reads
as an intentional, named decision rather than a bare `.enableCheck` property
access scattered across a flake.

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
an empty one, is an evaluation error. The default name keeps a `mkTestCheck`
and a `mkScriptCheck` over the same system distinguishable in a build log.

### Why this is not just `doCheck`

An enclosing `test-op` is not neutral. `cl-weave` is its own test subject,
and its suite contains a test that performs `test-op` on `cl-weave/test`
directly, in order to assert the ASDF integration's failure path. Driving
that suite from an enclosing `test-op` puts the same operation on the plan
twice and ASDF rejects it as a circular dependency. Such a system is
untestable through `asdf:test-system` by construction, not by oversight.

`run-tests.lisp` is the default because the nerima-lisp package standard
mandates it at every package's repository root as the universal test entry
point. Defaulting to it means the command a developer runs by hand
(`sbcl --script run-tests.lisp`) and the gate CI runs cannot drift apart.

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
| `artifacts` | `[ ]` | Paths relative to the build tree; files or directories |
| `validationCommands` | `[ ]` | Shell snippets run after the artifacts are asserted |
| `nativeBuildInputs` | `[ ]` | The validators — `pkgs.jq`, `pkgs.libxml2`, `pkgs.perl`, … |

`command` is a list and never a concatenated string. A filter expression like
`"filtering > runs only tests matching a path substring"` contains spaces and
a `>` that a string-concatenated command would hand to the shell as a
redirection. A non-list, empty, or non-string-element `command` is an
evaluation error.

Every artifact is asserted **present and non-empty**. Presence alone is not
the property anyone wants: a reporter that opens its output file and then
dies leaves a zero-byte JSON document behind, and `test -e` is perfectly
happy with it. A directory artifact is non-empty when it has at least one
entry — `test -s` on a directory reports its inode size and is meaningless.

Artifacts keep their relative layout under `$out`, so a check writing
`reports/summary.json` does not silently flatten to `$out/summary.json` and
collide with another artifact of that name. A trailing slash on an artifact
path is normalized once; a malformed one is an error.

Validation runs after the artifacts are known to exist, and *outside* the
time limit: the limit exists for the Lisp process's runaway risk, and folding
a sub-second `jq` into it would let a slow validator be reported as a suite
timeout.

Unlike `mkScriptCheck`, this replaces the install phase. Burying the named
artifacts inside a full copy of the source tree plus its fasls would defeat
the entire point of the check.

## `mkCheckMatrix`

A declarative multi-implementation test matrix, replacing the scattered
`meta.broken` predicate lists every piece of prior art falls back to once it
needs to run the same suite under more than one Lisp.

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
`args.pname`, or the systems joined with `-`.

`lispPackages` is kept separate from the `lisps` name list so the same name
set can point at different package sources — nixpkgs stable versus a nightly
override — without touching call sites. A name with no entry is an error
naming the missing key.

`skip` omits an implementation's check entirely, via `builtins.trace` so a
skip is never silent. `expectedFailure` still *runs* the check, so a
regression to passing stays visible in the build log, but does not fail
`nix flake check`.

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
| `entryPointText` | `null` | Inline Lisp instead; mutually exclusive with `entryPoint` |
| `name` | `null` | `pname`; defaults to the built system's `pname` plus `-coverage` |

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

The report is written under `unwind-protect`, because the org-standard
`run-tests.lisp` ends in `(uiop:quit N)` — on SBCL an unwinding exit — so a
*failing* suite still produces a report, which is precisely when the numbers
are most worth looking at.

The result asserts its own `cover-index.html` is non-empty before installing
it, so it doubles as `checks.coverage` with no wrapper derivation.

### No minimum-coverage threshold

There is deliberately no threshold option, for two reasons.

`cl-prolog` made this call explicitly: the report exists to make the number
visible and trending, not to block merges on a threshold nobody has agreed
to yet.

And sb-cover offers no supported way to implement one. `sb-cover:report`
returns the index pathname and nothing else, so a percentage gate would mean
scraping SBCL's generated HTML — a coupling to a report template with no
stability guarantee. A project that wants a gate should compute the ratio in
its own Lisp code and wire it up with `mkCommandCheck`.
