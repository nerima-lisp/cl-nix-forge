{ lib }:
let
  # Every failure carries the file, because the caller's Nix expression only
  # mentions a path -- the offending line is in a .asd they have to go open.
  # `caller` is the public function's own name so a failure points at the entry
  # point that was actually used.
  mkFail =
    caller: asdFile: message:
    throw "cl-nix-forge ${caller}: ${message} in ${toString asdFile}";

  # Shared front end: lex `asdFile` and return one record per `defsystem` form,
  # in source order, as `{ system, versions }`. `versions` is a list because a
  # form declaring `:version` twice is a drift bug the callers must be able to
  # see, not something to silently resolve here.
  #
  # This is deliberately a small lexer, not a Common Lisp parser: it understands
  # strings and the two comment forms needed to avoid accepting commented-out
  # metadata, and nothing else. A .asd is arbitrary Lisp -- the moment we would
  # have to evaluate it to know the answer, the right response is to fail and
  # make the caller pass `version` explicitly.
  defsystemForms =
    caller: asdFile:
    let
      fail = mkFail caller asdFile;
      isWhitespace =
        char:
        builtins.elem char [
          " "
          "\t"
          "\n"
          "\r"
        ];
      startsWith =
        prefix: chars:
        builtins.length chars >= builtins.length prefix
        && lib.take (builtins.length prefix) chars == prefix;
      skipLineComment =
        chars:
        if chars == [ ] then
          [ ]
        else if builtins.head chars == "\n" then
          builtins.tail chars
        else
          skipLineComment (builtins.tail chars);
      skipBlockComment =
        chars: depth:
        if chars == [ ] then
          fail "unterminated block comment"
        else if startsWith [ "#" "|" ] chars then
          skipBlockComment (lib.drop 2 chars) (depth + 1)
        else if startsWith [ "|" "#" ] chars then
          if depth == 1 then lib.drop 2 chars else skipBlockComment (lib.drop 2 chars) (depth - 1)
        else
          skipBlockComment (builtins.tail chars) depth;
      readString =
        chars: value: escaped:
        if chars == [ ] then
          fail "unterminated string literal"
        else
          let
            char = builtins.head chars;
            rest = builtins.tail chars;
          in
          if char == "\"" then
            {
              token = {
                type = "string";
                value = builtins.concatStringsSep "" value;
                inherit escaped;
              };
              inherit rest;
            }
          else if char == "\\" then
            if rest == [ ] then
              fail "unterminated string escape"
            else
              readString (builtins.tail rest) (value ++ [ (builtins.head rest) ]) true
          else
            readString rest (value ++ [ char ]) escaped;
      # `#` is not an atom terminator, so `#:cl-prolog` and `:cl-prolog` each
      # come back as ONE atom; `systemNameAt` relies on that to strip the
      # designator prefix textually instead of re-lexing.
      readAtom =
        chars: value:
        if chars == [ ] then
          {
            token = {
              type = "atom";
              value = builtins.concatStringsSep "" value;
            };
            rest = [ ];
          }
        else
          let
            char = builtins.head chars;
          in
          if
            isWhitespace char
            || builtins.elem char [
              "("
              ")"
              ";"
              "\""
            ]
            || startsWith [ "#" "|" ] chars
          then
            {
              token = {
                type = "atom";
                value = builtins.concatStringsSep "" value;
              };
              rest = chars;
            }
          else
            readAtom (builtins.tail chars) (value ++ [ char ]);
      lex =
        chars: tokens:
        if chars == [ ] then
          tokens
        else
          let
            char = builtins.head chars;
            rest = builtins.tail chars;
          in
          if isWhitespace char then
            lex rest tokens
          else if char == ";" then
            lex (skipLineComment rest) tokens
          else if startsWith [ "#" "|" ] chars then
            lex (skipBlockComment (lib.drop 2 chars) 1) tokens
          else if char == "(" then
            lex rest (tokens ++ [ { type = "open"; } ])
          else if char == ")" then
            lex rest (tokens ++ [ { type = "close"; } ])
          else if char == "\"" then
            let
              string = readString rest [ ] false;
            in
            lex string.rest (tokens ++ [ string.token ])
          else
            let
              atom = readAtom chars [ ];
            in
            lex atom.rest (tokens ++ [ atom.token ]);
      tokens = lex (lib.stringToCharacters (builtins.readFile asdFile)) [ ];
      tokenCount = builtins.length tokens;
      tokenAt = index: builtins.elemAt tokens index;

      # The three spellings that actually occur in the wild: bare (the form used
      # inside `(in-package #:asdf-user)`, which is what ASDF's own template
      # emits) and the two package-qualified ones -- ASDF exports `defsystem`
      # from both the `asdf` and `asdf/defsystem` packages. Nothing else is
      # guessed at; an unrecognised operator simply is not a defsystem form.
      # The comparison is on the lowercased token because the CL reader
      # upcases, so `DEFSYSTEM` and `defsystem` denote the same symbol.
      defsystemOperators = [
        "defsystem"
        "asdf:defsystem"
        "asdf/defsystem:defsystem"
      ];
      isDefsystemAt =
        index:
        index + 1 < tokenCount
        && (tokenAt (index + 1)).type == "atom"
        && builtins.elem (lib.toLower (tokenAt (index + 1)).value) defsystemOperators;

      # ASDF's `coerce-name` accepts the system designator as a string, a
      # keyword or an uninterned symbol, so `(defsystem "x")`, `(defsystem :x)`
      # and `(defsystem #:x)` all name the same system. Normalise all three to
      # one plain lowercase string so callers get a single predictable key
      # shape. (ASDF itself keeps a *string* designator case-sensitive and only
      # downcases symbols; a uniform rule is worth the divergence, since a
      # mixed-case system name does not occur in practice and a caller that hit
      # one would get a missing-key error, not a wrong answer.)
      systemNameAt =
        index:
        let
          token = if index < tokenCount then tokenAt index else null;
        in
        if token != null && token.type == "string" then
          lib.toLower token.value
        else if token != null && token.type == "atom" then
          lib.toLower (lib.removePrefix ":" (lib.removePrefix "#" token.value))
        else
          fail "a `defsystem` form has no system-name designator";

      # `open` is the stack of defsystem forms whose closing paren has not been
      # seen yet, each tagged with the paren depth of its OWN option plist. That
      # tag is the whole point: a `:version` inside a `:components` entry sits
      # one level deeper and is therefore never attributed to the system.
      scan =
        index: depth: open: closed:
        if index == tokenCount then
          # A truncated file leaves forms open. Report what was found rather
          # than validating paren balance -- that is the Lisp reader's job, and
          # a half-written .asd will fail loudly at build time anyway.
          closed ++ open
        else
          let
            token = tokenAt index;
          in
          if token.type == "open" then
            scan (index + 1) (depth + 1) (
              if isDefsystemAt index then
                # index is `(`, index + 1 the operator, so index + 2 is the name.
                open
                ++ [
                  {
                    depth = depth + 1;
                    system = systemNameAt (index + 2);
                    versions = [ ];
                  }
                ]
              else
                open
            ) closed
          else if token.type == "close" then
            scan (index + 1) (depth - 1) (lib.filter (form: form.depth < depth) open) (
              closed ++ lib.filter (form: form.depth == depth) open
            )
          else if token.type == "atom" && lib.toLower token.value == ":version" then
            if !(builtins.any (form: form.depth == depth) open) then
              # A `:version` that is not a defsystem option -- a `defparameter`,
              # a component's own version -- is not system metadata. Skip it
              # BEFORE the literal-string checks, so unrelated code in the .asd
              # cannot make extraction fail.
              scan (index + 1) depth open closed
            else if index + 1 >= tokenCount || (tokenAt (index + 1)).type != "string" then
              fail "`:version` must be followed by a literal string"
            else if (tokenAt (index + 1)).escaped then
              fail "`:version` must not use string escapes"
            else
              scan (index + 2) depth (map (
                form:
                if form.depth == depth then
                  form // { versions = form.versions ++ [ (tokenAt (index + 1)).value ]; }
                else
                  form
              ) open) closed
          else
            scan (index + 1) depth open closed;
    in
    scan 0 0 [ ] [ ];

  # Render `"1.0.0" (a, b), "2.0.0" (c)` -- the distinct values *and* who
  # declared each one, because fixing drift means editing a specific defsystem.
  describeDrift =
    forms: distinct:
    lib.concatMapStringsSep ", " (
      value:
      let
        declarers = map (form: form.system) (lib.filter (form: builtins.elem value form.versions) forms);
      in
      "${builtins.toJSON value} (${lib.concatStringsSep ", " declarers})"
    ) distinct;
in
{
  # fromAsdSystem :: path -> string
  #
  # The single version of the .asd as a whole. A repo that follows the org's
  # one-.asd-at-the-root layout defines `<pkg>` and `<pkg>/test` (and often
  # more) in one file, each repeating the same `:version` -- that is the normal
  # shape, not an ambiguity, so unanimous agreement across every defsystem form
  # is accepted and returned. Disagreement is a real drift bug: refuse to pick a
  # winner rather than build something whose version depends on file order.
  fromAsdSystem =
    asdFile:
    let
      fail = mkFail "fromAsdSystem" asdFile;
      forms = defsystemForms "fromAsdSystem" asdFile;
      distinct = lib.unique (lib.concatMap (form: form.versions) forms);
    in
    if distinct == [ ] then
      fail "no literal `:version \"...\"` option in a `defsystem` form was found"
    else if builtins.length distinct == 1 then
      builtins.head distinct
    else
      fail "conflicting `:version` options ${describeDrift forms distinct}; reconcile them or pass `version` explicitly";

  # asdSystemVersions :: path -> { <systemName> = version; ... }
  #
  # Every defsystem's own declared version, keyed by normalised system name, for
  # the rare caller that needs one specific system rather than the file's
  # consensus. Orthogonal to fromAsdSystem: this one is happy to report drift.
  #
  # A defsystem with no `:version` is OMITTED rather than recorded as null. A
  # null would flow silently into `lispDerivation`'s `version` and produce a
  # nameless-looking derivation; a missing key throws at the use site, which is
  # the louder failure. Omitting also keeps the result plain comparable data
  # (no throw-valued attributes), so callers and tests can `==` whole attrsets.
  asdSystemVersions =
    asdFile:
    let
      fail = mkFail "asdSystemVersions" asdFile;
      forms = defsystemForms "asdSystemVersions" asdFile;
      # Two disagreeing `:version` options inside the SAME defsystem are just as
      # much a drift bug as two systems disagreeing, so refuse there too.
      versionOf =
        form:
        let
          distinct = lib.unique form.versions;
        in
        if builtins.length distinct == 1 then
          builtins.head distinct
        else
          fail "system ${builtins.toJSON form.system} declares conflicting `:version` options ${
            describeDrift [ form ] distinct
          }";
    in
    builtins.listToAttrs (
      map (form: lib.nameValuePair form.system (versionOf form)) (
        lib.filter (form: form.versions != [ ]) forms
      )
    );
}
