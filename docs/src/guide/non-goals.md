# Non-goals

Each of these is a decision, with a reason. They are listed here so that
"cl-nix-forge does not do X" can be checked against "…and here is why not"
rather than read as an unfinished feature.

## Per-file FASL caching finer than one derivation per ASDF system

Infeasible, not just undeveloped. Compiling file N of a serial ASDF system
requires files `1..N-1` to already be *loaded* — macros, `eval-when`, and
CLOS class definitions all take effect at load time — so a file cannot be
compiled as a pure function of its own text.

One derivation per system is the real ceiling. nixpkgs' and `cl-nix-lite`'s
independent designs already converge on it.

## Cargo/poetry-style lockfile version unification

ASDF resolves systems by name only; there is no version-lockfile concept to
unify. This library makes the existing name-based model *reproducible* for a
fixed set of pinned inputs. It does not invent Common Lisp package-version
resolution.

`fromAsdSystem` reads a version out of a `.asd`, which is a different thing:
it is a naming input to a derivation, not a constraint solved against
anything.

## Quicklisp/Ultralisp dist fetching

Use `pkgs.sbcl.withPackages` or nixpkgs `lisp-modules` for that, and hand the
result to
[`fromNixpkgsLisp`](../reference/dependencies.md#fromnixpkgslisp) if you need
to mix it with `cl-nix-forge`-built systems. That composition is supported and
exercised; re-implementing dist fetching is not.

## Cross-compilation

Not supported.

## Related decisions elsewhere

Two more "deliberately absent" choices are narrow enough to live with the
function they belong to, rather than here:

- [`mkCoverageReport`](../reference/checks.md#mkcoveragereport) has no
  minimum-coverage threshold, and no option to add one.
- [`mkExecutable`](../reference/outputs.md#mkexecutable) exposes neither
  `save-runtime-options` nor core compression, because neither could be
  honoured on the `program-op` path.
