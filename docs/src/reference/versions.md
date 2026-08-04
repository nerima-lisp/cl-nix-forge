# Reading a `.asd`

Three functions, one lexer. Each answers a question out of what a `.asd`
already declares rather than out of a second copy in a flake: two read its
`:version`, so a release edits one file rather than a file and a flake, and
one reads its `:depends-on`, so the registry a system is built against comes
from the same file ASDF itself would read.

The lexer is deliberately small — not a Common Lisp parser. It understands
string literals and both comment forms, which is exactly what is needed to
avoid accepting commented-out metadata, and nothing else. A `.asd` is
arbitrary Lisp; the moment the answer would require evaluating it, the right
response is to fail and make the caller pass `version` explicitly.

Every failure names the file, because the caller's Nix expression only
mentions a path — the offending line is in a `.asd` they have to go open.

## `fromAsdSystem`

Extract the literal, unescaped `:version` declared as a direct option of a
`defsystem` form.

```nix
version = cl.fromAsdSystem ./my-app.asd;
```

The operator is recognised as `defsystem`, `asdf:defsystem` or
`asdf/defsystem:defsystem`, case-insensitively, since all three occur in the
wild.

One `.asd` normally defines several systems — `<pkg>` and `<pkg>/test` — that
all carry the same version. That unanimity is accepted and returned as one
string. Versions that *disagree* are real drift and fail loudly, naming each
value and the system it came from.

Line comments and nested block comments are ignored. A `:version` nested
inside `:components` is never mistaken for a system's own. A missing or
dynamically computed version fails; pass `version` explicitly in those cases.

## `asdSystemVersions`

The same extraction as an attrset keyed by system name.

```nix
cl.asdSystemVersions ./cl-prolog.asd
# => { "cl-prolog" = "1.1.0"; "cl-prolog/test" = "1.1.0"; }
```

For the rarer case of needing one specific system's version rather than the
file's consensus. System-name designators are normalised, so `"x"`, `:x` and
`#:x` all key as `"x"`.

## `asdSystemDependencies`

The `:depends-on` names each `defsystem` in the file declares, keyed by
system name. The question it answers is the one `CL_SOURCE_REGISTRY` asks:
which other systems have to be reachable before this one can load.

```nix
cl.asdSystemDependencies {
  asd = ./cl-cli.asd;
  features = [ "sbcl" ];
}
# => {
#      "cl-cli" = [ "alexandria" "cl-host-kit" ];
#      "cl-cli/test" = [ "cl-cli" "fiveam" ];
#    }
```

Both arguments are required. The same lexer and the same `defsystem`
recognition as above apply, so line comments, block comments and
commented-out clauses are ignored here too.

### `features` has no default on purpose

`features` is the `*features*` list the file's reader conditionals are
evaluated against. `#+sbcl "cl-host-kit"` contributes `cl-host-kit` when
`"sbcl"` is in `features` and contributes nothing when it is not.
`(:feature :sbcl "cl-host-kit")` is ASDF's own spelling of the same
conditional and is evaluated against the same list, with the same result.

Defaulting the list would mean guessing, and the two available guesses are
both wrong. A cl-nix-forge registry entry is a derivation built for one
specific implementation, so an SBCL-only dependency silently included in an
ECL build is not a harmless extra path on `CL_SOURCE_REGISTRY` — it is a
build against the wrong implementation's code, discovered later and further
away. Dropping conditionals instead loses real dependencies from the SBCL
build. `cl-cli` is the org's live instance of this: its `.asd` guards
`cl-host-kit` with `#+sbcl` precisely so the ECL portability gate never sees
it, and a default in either direction would defeat that guard from the Nix
side. Requiring the argument makes the caller state which implementation the
answer is for, which it already knows, since it is the same choice it made
when it picked a Lisp to build with.

### A system with no dependencies is kept, not dropped

`asdSystemVersions` omits a system that declares no `:version`. This
function omits nothing: a `defsystem` with no `:depends-on` is present with
`[ ]`.

The asymmetry is deliberate, because the two absences are different facts.
A missing `:version` is unknown data — the file does not say what the version
is, and inventing a key for it would put a fiction in the attrset. "This
system depends on nothing" is not unknown; it is a complete and correct
answer, and dropping the key would force every caller to tell it apart from
"there is no such system in this file", which is the one distinction a
registry builder cannot afford to lose.

`:depends-on ()` and `:depends-on NIL` say exactly what no `:depends-on`
clause says, and all three yield `[ ]`.

### The value is a list, not a set

Source order is preserved and duplicates are not collapsed. A name that
appears twice in one `:depends-on` is drift in the `.asd` that the caller has
to be able to see; deduplicating here would launder it into a well-formed
answer and delete the evidence. A caller that wants a set applies
`lib.unique` and can be held to having asked for it.

### `(:require ...)` contributes no name

`(:require :sb-cover)` asks the implementation to load a module it ships
itself. That is not an ASDF system, there is no source tree for a registry to
point at, and so it contributes no name to the result. Its absence from the
list is the correct answer, not a gap.

Any other element shape fails, naming the file and quoting the element, on
the same reasoning as the rest of this page: the caller's Nix expression
mentions only a path, so the message has to say which file to open and what
in it was not understood. Unprefixed symbol designators are among the
rejected shapes — write `#:alexandria` or `"alexandria"`, not a bare
`alexandria`.

### The key set is not the same as `asdSystemVersions`'

The two functions do not agree on keys, and code that assumes they do is
wrong. Because a versionless system is omitted from one and kept in the
other, the keys of `asdSystemVersions` are a proper *subset* of these:
across the org's 108 systems, 13 declare dependencies and no `:version`.

A naive join — walking these keys and indexing the version attrset with each
— therefore throws on those 13. Take this function's key set as the
authoritative list of systems in the file, and look versions up defensively
(`versions.<name> or null`) rather than assuming a one-to-one.

### Nesting

A `:depends-on` inside a `:components` entry names sibling *files* within the
system, not systems, and is correctly not attributed to the system — the same
rule that keeps a `:version` nested inside `:components` from being mistaken
for a system's own.
