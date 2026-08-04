{ lib }:
let
  # Every failure carries the file, because the caller's Nix expression only
  # mentions a path -- the offending line is in a .asd they have to go open.
  # `caller` is the public function's own name so a failure points at the entry
  # point that was actually used.
  mkFail =
    caller: asdFile: message:
    throw "cl-nix-forge ${caller}: ${message} in ${toString asdFile}";

  # `defsystemForms` needs the caller's feature set to decide which reader
  # conditionals in a `:depends-on` list fire. The version-only entry points
  # have no feature set to offer and never force `dependencies`, so they pass
  # this sentinel: if that ever stops being true the result is a loud internal
  # error naming the mistake, not a silent `[ ]` that would quietly resurrect
  # the `#+sbcl` over-reporting this module exists to avoid.
  featuresUnused = throw (
    "cl-nix-forge: internal error -- `:depends-on` reader conditionals were "
    + "evaluated from an entry point that reads only `:version`"
  );

  # Shared front end: lex `asdFile` and return one record per `defsystem` form,
  # in source order, as `{ system, versions, dependencies }`. Both payloads are
  # lists rather than resolved values because a form declaring `:version` twice,
  # or naming the same dependency twice, is a drift bug the callers must be able
  # to see, not something to silently resolve here.
  #
  # `dependencies` may be, or may contain, an unforced `throw`. That is the
  # point: this function is shared by three public entry points, and only one
  # of them cares about `:depends-on`. A .asd whose dependency list this lexer
  # cannot read must still yield its `:version` to `fromAsdSystem`, so every
  # dependency failure is deferred into the value rather than raised while
  # walking. Correspondingly, nothing that steers the walk -- any `next` index
  # below -- may depend on a feature test or fail.
  #
  # This is deliberately a small lexer, not a Common Lisp parser: it understands
  # strings and the two comment forms needed to avoid accepting commented-out
  # metadata, and nothing else. A .asd is arbitrary Lisp -- the moment we would
  # have to evaluate it to know the answer, the right response is to fail and
  # make the caller pass `version` explicitly.
  defsystemForms =
    caller: asdFile: features:
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

      # A feature in a reader conditional is spelled with exactly the same
      # three designator shapes a system name is -- `#+sbcl`, `#+:sbcl` and
      # `#+#:sbcl` all test the `SBCL` feature -- so it is normalised by the
      # same rule. The caller's `features` go through it too, which is why
      # passing `[ ":sbcl" ]` cannot silently disagree with a `#+sbcl` in the
      # file and leave a dependency mysteriously absent.
      featureName = text: lib.toLower (lib.removePrefix ":" (lib.removePrefix "#" text));
      presentFeatures = map featureName features;
      featureHolds = name: builtins.elem name presentFeatures;
      isConditional = value: lib.hasPrefix "#+" value || lib.hasPrefix "#-" value;

      # Failures about `:depends-on` quote the offending element, because the
      # caller has to go find it: naming only its token type ("an atom") would
      # not locate it in a list of thirty dependencies.
      describeToken =
        index:
        let
          token = if index < tokenCount then tokenAt index else null;
        in
        if token == null then
          "end of file"
        else if token.type == "string" then
          builtins.toJSON token.value
        else if token.type == "atom" then
          token.value
        else if token.type == "open" then
          "("
        else
          ")";

      # The token just past the `)` closing the list that opens at `index`.
      # Used to step over a `(:version ...)` / `(:require ...)` element whole,
      # so the element loop lands on the next sibling rather than descending
      # into a sublist whose contents it would misread as dependencies.
      endOfListAt =
        index: depth:
        if index >= tokenCount then
          index
        else
          let
            token = tokenAt index;
          in
          if token.type == "open" then
            endOfListAt (index + 1) (depth + 1)
          else if token.type == "close" then
            (if depth == 1 then index + 1 else endOfListAt (index + 1) (depth - 1))
          else
            endOfListAt (index + 1) depth;

      # Evaluate the feature expression that starts at `index` against
      # `features`, returning `{ value, next }`.
      #
      # `next` is derived from parenthesis structure alone: it never consults
      # `value`, never consults `features`, and never fails. That separation
      # is what lets `fromAsdSystem` walk a `:depends-on` list containing
      # reader conditionals while passing `featuresUnused` -- the walk needs
      # only `next`. `value` is the half that may be a `throw`.
      featureExpressionAt =
        index:
        let
          token = if index < tokenCount then tokenAt index else null;
        in
        if token == null then
          {
            value = fail "a reader conditional at end of file has no feature expression";
            next = index;
          }
        else if token.type == "atom" then
          {
            value = featureHolds (featureName token.value);
            next = index + 1;
          }
        else if token.type == "open" then
          let
            # Normalised as a designator, not merely lowercased: a reader
            # conditional writes `(or sbcl ccl)` while ASDF's `(:feature ...)`
            # clause writes `(:or :sbcl :ccl)`, and both name the same
            # connective.
            operator =
              if index + 1 < tokenCount && (tokenAt (index + 1)).type == "atom" then
                featureName (tokenAt (index + 1)).value
              else
                null;
            # Arguments are evaluated lazily and only by the connective that
            # wants them, so `(or sbcl <nonsense>)` still answers on SBCL.
            arguments = featureArgumentsAt (index + 2) [ ];
            listEnd = endOfListAt index 0;
          in
          # `(and)` is TRUE and `(or)` is FALSE with no arguments (CLHS
          # 24.1.2.1). That is not a corner case worth skipping: `#-(and)` is
          # the standard idiom for commenting a form out, and getting it
          # backwards would resurrect a dependency the author deleted.
          if operator == "or" then
            {
              value = builtins.any (holds: holds) arguments;
              next = listEnd;
            }
          else if operator == "and" then
            {
              value = builtins.all (holds: holds) arguments;
              next = listEnd;
            }
          else if operator == "not" then
            {
              value =
                if builtins.length arguments == 1 then
                  !(builtins.head arguments)
                else
                  fail "`not` in a feature expression takes exactly one argument";
              next = listEnd;
            }
          else
            {
              value = fail "feature expression operator ${describeToken (index + 1)} is not `and`, `or` or `not`";
              next = listEnd;
            }
        else if token.type == "close" then
          # Deliberately does NOT consume the `)`: the caller has to see it to
          # recognise a conditional left dangling at the end of a list.
          {
            value = fail "a reader conditional has no feature expression";
            next = index;
          }
        else
          {
            value = fail "feature expression ${describeToken index} is neither a feature name nor an `(and ...)` / `(or ...)` / `(not ...)` list";
            next = index + 1;
          };

      # The argument expressions of a connective, up to the closing `)`.
      # Every branch of `featureExpressionAt` advances past at least one token
      # unless it is looking at that `)` -- which is tested first here -- so
      # this terminates on any input.
      featureArgumentsAt =
        index: values:
        if index >= tokenCount || (tokenAt index).type == "close" then
          values
        else
          let
            argument = featureExpressionAt index;
          in
          featureArgumentsAt argument.next (values ++ [ argument.value ]);

      # A dependency designator, normalised by the same rule as the system
      # name so `asdSystemDependencies`'s values and `asdSystemVersions`'s keys
      # are directly comparable -- the whole point of the function is to look
      # up what a system depends on, which means the two sides must match
      # textually. Only the spellings that occur are accepted: an unrecognised
      # one is a shape this lexer has never seen, and guessing at it would put
      # a bogus system name into a registry that then fails far from here.
      dependencyNameAt =
        index:
        let
          token = if index < tokenCount then tokenAt index else null;
          isDesignator =
            token != null
            && (
              token.type == "string"
              || (token.type == "atom" && (lib.hasPrefix ":" token.value || lib.hasPrefix "#:" token.value))
            );
        in
        if isDesignator then
          systemNameAt index
        else
          # `systemNameAt` twelve lines up accepts a bare symbol as a system
          # NAME, so the rule has to be stated rather than implied: in a
          # dependency position the designator must be a string or carry a
          # `:` / `#:` prefix. Bare symbols are rejected because they do not
          # occur (zero times across the org's 46 .asd files) and because
          # accepting them would make a stray token in an option plist look
          # like a dependency. The message names the fix so the reader does
          # not have to reverse-engineer it from the rejection.
          fail
            "`:depends-on` element ${describeToken index} is not a dependency designator; write a string, `:name` or `#:name`";

      # One element of a `:depends-on` list -- ASDF's `dependency-def` -- as
      # `{ names, next }`. `names` is what the element contributes, `next` the
      # token just past it.
      #
      # As everywhere in this walk, `next` is structural: a reader conditional
      # consumes the element it guards whether or not the feature holds, so
      # the two paths agree on where the element ends and disagree only about
      # `names`. Nothing here forces a feature test to decide where to go.
      dependencyElementAt =
        index:
        let
          token = tokenAt index;
        in
        if token.type == "atom" && isConditional token.value then
          # A reader conditional is NOT transparent. `cl-cli.asd` writes
          # `:depends-on ("uiop" #+sbcl "cl-host-kit")` precisely so that ECL
          # never sees the name -- cl-host-kit wraps `sb-posix` and its own
          # flake excludes it from the ECL build. This function's answer
          # becomes a registry of DERIVATIONS built for one implementation,
          # not a set of paths, so a surplus entry is a build for the wrong
          # implementation rather than an unused directory. That is why the
          # public entry point demands `features` instead of defaulting.
          let
            # `readAtom` stops at `(`, so `#+sbcl` arrives as a single atom
            # while `#+(or sbcl ccl)` arrives as the atom `#+` followed by a
            # list. Both spellings reach here and both must be understood.
            inline = builtins.substring 2 (builtins.stringLength token.value) token.value;
            expression =
              if inline != "" then
                {
                  value = featureHolds (featureName inline);
                  next = index + 1;
                }
              else
                featureExpressionAt (index + 1);
            guarded = expression.next;
            holds = if lib.hasPrefix "#+" token.value then expression.value else !expression.value;
          in
          if guarded >= tokenCount || (tokenAt guarded).type == "close" then
            # A conditional with nothing behind it. Refusing it is the same
            # stance the rest of this module takes towards shapes it does not
            # understand: silently ignoring it would let a truncated edit hide
            # a dependency forever, and it costs nothing to say so.
            {
              names = fail "reader conditional `${token.value}` has no `:depends-on` element to guard";
              next = guarded;
            }
          else
            let
              # Recursion, not a skip, so a stacked `#+sbcl #+unix "x"` is
              # handled by the same case, and so an excluded element that is a
              # LIST -- `#-sbcl (:require "sb-cover")` -- is still stepped
              # over as one unit rather than walked into.
              inner = dependencyElementAt guarded;
            in
            {
              names = if holds then inner.names else [ ];
              next = inner.next;
            }
        else if token.type == "open" then
          let
            head =
              if index + 1 < tokenCount && (tokenAt (index + 1)).type == "atom" then
                lib.toLower (tokenAt (index + 1)).value
              else
                null;
            next = endOfListAt index 0;
            # The index of this element's own `)`; `endOfListAt` returns the
            # token after it.
            closeIndex = next - 1;
          in
          if head == ":version" then
            # `(:version <designator> "1.1.0")` states a lower bound on an
            # edge that is otherwise an ordinary dependency. The bound is
            # ASDF's business at load time; here only the designator is.
            {
              names = [ (dependencyNameAt (index + 2)) ];
              inherit next;
            }
          else if head == ":require" then
            # `(:require "sb-cover")` asks the implementation for one of its
            # own modules. It is not an ASDF system, so no source registry
            # entry can ever satisfy it and naming it here would send the
            # caller looking for a repository that cannot exist.
            {
              names = [ ];
              inherit next;
            }
          else if head == ":feature" then
            # `(:feature <feature-expression> <dependency-def>)` is ASDF's own
            # spelling of the reader conditional above, and the two must agree
            # -- `cl+ssl`, `usocket`, `cffi` and `bordeaux-threads` all use
            # it, so a caller reaching outside the org will meet it. The
            # dependency-def is recursive, hence the call back into this
            # function rather than a designator read.
            let
              expression = featureExpressionAt (index + 2);
              inner = dependencyElementAt expression.next;
            in
            {
              names =
                if expression.next >= closeIndex then
                  fail "`(:feature ...)` element has no dependency to guard"
                else if inner.next != closeIndex then
                  fail "`(:feature ...)` element guards more than one dependency"
                else if expression.value then
                  inner.names
                else
                  [ ];
              inherit next;
            }
          else
            {
              names = fail "`:depends-on` element starting ${describeToken (index + 1)} is none of `:version`, `:require` or `:feature`";
              inherit next;
            }
        else
          {
            names = [ (dependencyNameAt index) ];
            next = index + 1;
          };

      # Read the `:depends-on` list whose `(` sits at `index` and return
      # `{ names, next }`, `next` being the token just past its `)`. Consuming
      # the list here instead of letting `scan` walk through it is what keeps
      # `scan`'s paren-depth bookkeeping honest: the list is balanced, so it is
      # traversed exactly once as a unit and `scan` resumes at the depth it
      # left. Source order and repeats survive; see `asdSystemDependencies`.
      dependencyListAt =
        index:
        let
          step =
            index: names:
            if index >= tokenCount then
              # A truncated file. Report what was read rather than complaining
              # about paren balance -- the same stance `scan` takes at end of
              # input, and for the same reason: that is the Lisp reader's job.
              {
                inherit names;
                next = index;
              }
            else if (tokenAt index).type == "close" then
              {
                inherit names;
                next = index + 1;
              }
            else
              let
                element = dependencyElementAt index;
              in
              # `names ++ element.names` is never forced here, which is what
              # lets a single unreadable element poison this list's value
              # while the walk itself completes and `fromAsdSystem` sails past.
              step element.next (names ++ element.names);
        in
        step (index + 1) [ ];

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
                    dependencies = [ ];
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
          else if token.type == "atom" && lib.toLower token.value == ":depends-on" then
            let
              # Both failures below POISON the owning form's `dependencies`
              # with an unforced `throw` and let the walk continue, rather
              # than failing here. `defsystemForms` is shared: `fromAsdSystem`
              # and `asdSystemVersions` read the same forms and have no
              # interest in dependency syntax, so a `:depends-on` this lexer
              # cannot read must not stop them from returning a version.
              # Laziness makes that exact -- only `asdSystemDependencies` ever
              # forces `dependencies`, and it still fails just as loudly.
              poison =
                message:
                map (
                  form:
                  if form.depth == depth then
                    form // { dependencies = fail "system ${builtins.toJSON form.system} ${message}"; }
                  else
                    form
                ) open;
            in
            if !(builtins.any (form: form.depth == depth) open) then
              # Same guard, same reason as `:version` above. A `:depends-on`
              # one level down belongs to a component and names sibling FILES
              # within this system, not systems; attributing those to the
              # system would invent dependencies on things like "package".
              scan (index + 1) depth open closed
            else if index + 1 >= tokenCount then
              scan (index + 1) depth (poison "ends the file with a `:depends-on` option that has no value") closed
            else if
              (tokenAt (index + 1)).type == "atom" && lib.toLower (tokenAt (index + 1)).value == "nil"
            then
              # `:depends-on nil` is `:depends-on ()`: NIL *is* the empty list
              # in Common Lisp, not a stand-in for one, and ECL's own cmp.asd
              # spells it that way. Contributing nothing is the whole of it.
              scan (index + 2) depth open closed
            else if (tokenAt (index + 1)).type != "open" then
              # Quote the offending token, and say `end of file` only when
              # that is what it is: "must be followed by a list" alone left
              # the reader to find which of thirty options was meant.
              scan (index + 1) depth
                (poison "has `:depends-on` followed by ${describeToken (index + 1)}, which is neither a list nor `nil`")
                closed
            else
              let
                list = dependencyListAt (index + 1);
              in
              # `depth` is unchanged: `dependencyListAt` consumed a balanced
              # list, so `list.next` sits at the same nesting level as `index`.
              scan list.next depth (map (
                form:
                if form.depth == depth then form // { dependencies = form.dependencies ++ list.names; } else form
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
  #
  # A `:depends-on` option this lexer cannot read does NOT fail here. Nineteen
  # repositories call this function for a version string and have no stake in
  # dependency syntax; making them share `asdSystemDependencies`'s strictness
  # would break them over a shape they never asked about.
  fromAsdSystem =
    asdFile:
    let
      fail = mkFail "fromAsdSystem" asdFile;
      forms = defsystemForms "fromAsdSystem" asdFile featuresUnused;
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
      forms = defsystemForms "asdSystemVersions" asdFile featuresUnused;
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

  # asdSystemDependencies ::
  #   { asd :: path, features :: [ string ] }
  #   -> { <systemName> = [ <dependencyName> ]; ... }
  #
  # Every defsystem's own `:depends-on` designators, keyed by the same
  # normalised system name `asdSystemVersions` uses, so the two results can be
  # joined. Intended for building a CL_SOURCE_REGISTRY: the answer is which
  # other systems have to be reachable before this one will load.
  #
  # `features` is the implementation's feature list -- `[ "sbcl" ]`, `[ "ecl" ]`
  # -- and is REQUIRED, deliberately without a default. The answer genuinely
  # differs between implementations: `cl-cli.asd` writes
  # `:depends-on ("uiop" #+sbcl "cl-host-kit")` so that ECL never sees a system
  # that wraps `sb-posix`, and each entry here becomes a derivation built for
  # one implementation. A default would have to guess, and guessing wrong
  # produces a build for the wrong implementation, so the caller -- which
  # always knows, `lispDerivation` has `lispImplementation` right there -- says
  # it out loud. Both `#+`/`#-` conditionals and ASDF's own
  # `(:feature <expr> <dep>)` are evaluated against it.
  #
  # Unlike asdSystemVersions, a form with no `:depends-on` is KEPT, with `[ ]`.
  # The asymmetry is deliberate and follows from what a missing entry would
  # mean in each case. There is no such thing as a system with no version, so
  # an absent `:version` is unknown data, and recording it as some placeholder
  # would let it flow silently into `lispDerivation`'s `version`; omitting it
  # makes the use site throw instead. "Depends on nothing" is by contrast a
  # true and common answer -- fourteen systems across the org declare
  # `:depends-on ()` outright -- and one a caller can act on, so it is reported
  # rather than hidden behind a key that looks like a parse failure.
  #
  # The value is a list, not a set: order is source order and repeats survive.
  # A dependency named twice is drift the caller must be able to see, exactly
  # as `versions` is a list for the same reason. Deduplicating here would erase
  # the evidence and leave the .asd wrong forever.
  asdSystemDependencies =
    {
      asd,
      features,
    }:
    builtins.listToAttrs (
      map (form: lib.nameValuePair form.system form.dependencies) (
        defsystemForms "asdSystemDependencies" asd features
      )
    );
}
