# Versions

Two functions, one lexer. Both read the `:version` a `.asd` already declares,
so a release edits one file rather than a file and a flake.

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
