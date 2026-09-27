{ lib }:
let
  # Every failure carries the file, because the caller's Nix expression only
  # mentions a path -- the offending line is in a .asd they have to go open.
  # `caller` is the public function's own name so a failure points at the entry
  # point that the caller used.
  mkFail =
    caller: asdFile: message:
    throw "cl-nix-forge ${caller}: ${message} in ${toString asdFile}";

  # `defsystemForms` needs the caller's feature set to decide which reader
  # conditionals in a `:depends-on` list fire. The version-only entry points
  # have no feature set to offer and never force `dependencies`, so they pass
  # this sentinel: if that ever stops being true the result is a loud internal
  # error naming the mistake, not a silent `[ ]` that would restore
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
  # This lexer handles strings and the two comment forms needed to avoid
  # accepting commented-out metadata. A .asd is arbitrary Lisp; the moment we would
  # have to evaluate it to know the answer, the right response is to fail and
  # make the caller pass `version` explicitly.
  #
  # Every walk over the file -- the lexer, the defsystem scan, and the element
  # loops of a `:depends-on` list or a feature connective -- is a
  # `builtins.genericClosure` rather than a recursive function. Nix does not
  # eliminate tail calls, so recursion costs one evaluator frame per character
  # or token, and a .asd of a few tens of kilobytes exceeded the default
  # `max-call-depth` of 10000. genericClosure iterates over a work list, and it
  # forces each item's `key` before producing the next item, so every `key`
  # below `seq`s the state the next step reads: without that, the unforced
  # state would be a thunk chain as long as the file, and forcing it at the
  # end would recurse just as deeply. Only structure is forced that way,
  # never a feature test or a dependency name, which keeps the deferred-throw
  # contract above.
  defsystemForms =
    caller: asdFile: features:
    let
      fail = mkFail caller asdFile;

      # The lexer steps over units, not characters: every character it treats
      # specially is a unit on its own and each run of other characters is one
      # unit. In every lexer mode a run behaves exactly as its characters taken
      # one at a time (appended to an atom or string, or skipped inside a
      # comment; after a `\` escape only its first character is escaped, and
      # the rest are appended regardless), so the result is the same while a
      # step covers a whole word.
      units = builtins.filter (unit: unit != "") (
        map (part: if builtins.isList part then builtins.head part else part) (
          builtins.split "([ \t\r\n\"\\\\;#|()])" (builtins.readFile asdFile)
        )
      );
      unitCount = builtins.length units;
      unitAt = index: builtins.elemAt units index;
      isWhitespace =
        unit:
        builtins.elem unit [
          " "
          "\t"
          "\n"
          "\r"
        ];
      isPairAt =
        index: first: second:
        unitAt index == first && index + 1 < unitCount && unitAt (index + 1) == second;

      # One lexer step: the state after the unit at `state.key`. `mode` is
      # `normal`, `atom`, `string`, `line` (a `;` comment) or `block` (a
      # `#| |#` comment, nesting to `depth`); `text` is the atom or string
      # read so far. `emit` holds the tokens this step completed and `ends`
      # the `(`-index to past-`)`-index pairs it closed, which `opens`, the
      # stack of unmatched `(` token indices, exists to compute. `width` is 2
      # when the step consumed a two-unit `#|`, `|#` or `\` escape.
      lexStep =
        state:
        let
          index = state.key;
          unit = unitAt index;
          # A unit read in normal mode, either directly or right after it
          # ended the atom in `pending`.
          normal =
            pending:
            let
              tokenIndex = state.count + builtins.length pending;
            in
            if isWhitespace unit then
              { emit = pending; }
            else if unit == ";" then
              {
                mode = "line";
                emit = pending;
              }
            else if isPairAt index "#" "|" then
              {
                mode = "block";
                depth = 1;
                width = 2;
                emit = pending;
              }
            else if unit == "(" then
              {
                emit = pending ++ [ { type = "open"; } ];
                opens = state.opens ++ [ tokenIndex ];
              }
            else if unit == ")" then
              {
                emit = pending ++ [ { type = "close"; } ];
              }
              // lib.optionalAttrs (state.opens != [ ]) {
                opens = lib.init state.opens;
                ends = [
                  {
                    name = toString (lib.last state.opens);
                    value = tokenIndex + 1;
                  }
                ];
              }
            else if unit == "\"" then
              {
                mode = "string";
                text = "";
                escaped = false;
                emit = pending;
              }
            else
              # `#` is not an atom terminator, so `#:cl-prolog-kit` and
              # `:cl-prolog-kit` each come back as ONE atom; `systemNameAt`
              # relies on that to strip the designator prefix textually
              # instead of re-lexing.
              {
                mode = "atom";
                text = unit;
                emit = pending;
              };
          changes =
            if state.mode == "normal" then
              normal [ ]
            else if state.mode == "atom" then
              if
                isWhitespace unit
                || builtins.elem unit [
                  "("
                  ")"
                  ";"
                  "\""
                ]
                || isPairAt index "#" "|"
              then
                {
                  mode = "normal";
                }
                // normal [
                  {
                    type = "atom";
                    value = state.text;
                  }
                ]
              else
                { text = state.text + unit; }
            else if state.mode == "string" then
              if unit == "\"" then
                {
                  mode = "normal";
                  emit = [
                    {
                      type = "string";
                      value = state.text;
                      inherit (state) escaped;
                    }
                  ];
                }
              else if unit == "\\" then
                if index + 1 >= unitCount then
                  fail "unterminated string escape"
                else
                  {
                    text = state.text + unitAt (index + 1);
                    escaped = true;
                    width = 2;
                  }
              else
                { text = state.text + unit; }
            else if state.mode == "line" then
              lib.optionalAttrs (unit == "\n") { mode = "normal"; }
            else if isPairAt index "#" "|" then
              {
                depth = state.depth + 1;
                width = 2;
              }
            else if isPairAt index "|" "#" then
              {
                width = 2;
              }
              // (if state.depth == 1 then { mode = "normal"; } else { depth = state.depth - 1; })
            else
              { };
          next =
            state
            // {
              emit = [ ];
              ends = [ ];
              width = 1;
            }
            // changes;
          count = state.count + builtins.length next.emit;
        in
        next
        // {
          inherit count;
          key = builtins.deepSeq [
            next.mode
            next.depth
            next.text
            next.escaped
            count
            next.opens
          ] (index + next.width);
        };
      lexStates = builtins.genericClosure {
        startSet = [
          {
            key = 0;
            mode = "normal";
            depth = 0;
            text = "";
            escaped = false;
            count = 0;
            opens = [ ];
            emit = [ ];
            ends = [ ];
          }
        ];
        operator = state: if state.key >= unitCount then [ ] else [ (lexStep state) ];
      };
      finalLexState = lib.last lexStates;
      tokens =
        builtins.concatMap (state: state.emit) lexStates
        ++ (
          if finalLexState.mode == "atom" then
            [
              {
                type = "atom";
                value = finalLexState.text;
              }
            ]
          else if finalLexState.mode == "string" then
            fail "unterminated string literal"
          else if finalLexState.mode == "block" then
            fail "unterminated block comment"
          else
            [ ]
        );
      tokenCount = builtins.length tokens;
      tokenAt = index: builtins.elemAt tokens index;
      listEnds = builtins.listToAttrs (builtins.concatMap (state: state.ends) lexStates);

      # The elements of the list whose first element is at `index`, each read
      # by `readAt` (which returns a record with a structural `next`), as
      # `{ elements, end }`: `end` is the index of the closing `)`, or
      # `tokenCount` for a truncated file. `next` always advances, so no key
      # repeats and the closure visits every element.
      listElementsFrom =
        index: readAt:
        let
          isEnd = index: index >= tokenCount || (tokenAt index).type == "close";
          items = builtins.genericClosure {
            startSet = [
              {
                key = index;
                element = readAt index;
              }
            ];
            operator =
              item:
              if isEnd item.key then
                [ ]
              else
                [
                  {
                    key = item.element.next;
                    element = readAt item.element.next;
                  }
                ];
          };
        in
        {
          # The last item is the end itself, never an element.
          elements = map (item: item.element) (lib.init items);
          end = (lib.last items).key;
        };

      # The three spellings that actually occur in the wild: bare (the form used
      # inside `(in-package #:asdf-user)`, which is what ASDF's own template
      # emits) and the two package-qualified ones -- ASDF exports `defsystem`
      # from both the `asdf` and `asdf/defsystem` packages. Nothing else is
      # guessed at; an unrecognised operator is not a defsystem form.
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
      # mixed-case system names are unsupported, and a caller that hit
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
      # same rule. The caller's `features` go through it too, so passing
      # `[ ":sbcl" ]` cannot silently disagree with a `#+sbcl` in the
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
      # `index` must be a `(`; an unclosed list ends at `tokenCount`. The lexer
      # matched every paren already, so this is a lookup, not a walk.
      endOfListAt = index: listEnds.${toString index} or tokenCount;

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
            # Every branch of `featureExpressionAt` advances past at least one
            # token unless it is looking at the closing `)`, which
            # `listElementsFrom` tests first, so this terminates on any input.
            arguments =
              map (element: element.value)
                (listElementsFrom (index + 2) featureExpressionAt).elements;
            listEnd = endOfListAt index;
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
          # This does NOT consume the `)`: the caller has to see it to
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
            next = endOfListAt index;
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
          list = listElementsFrom (index + 1) dependencyElementAt;
        in
        {
          # Never forced by the walk, which is what lets a single unreadable
          # element poison this list's value while the walk itself completes
          # and `fromAsdSystem` sails past.
          names = builtins.concatMap (element: element.names) list.elements;
          # A truncated file ends at `tokenCount`. Report what was read rather
          # than complaining about paren balance -- the same stance `scan`
          # takes at end of input, and for the same reason: that is the Lisp
          # reader's job.
          next = if list.end >= tokenCount then list.end else list.end + 1;
        };

      # `open` is the stack of defsystem forms whose closing paren has not been
      # seen yet, each tagged with the paren depth of its OWN option plist. That
      # tag is the whole point: a `:version` inside a `:components` entry sits
      # one level deeper and is therefore never attributed to the system.
      #
      # `scan` handles the token at `index` and returns the state for the next
      # one, built by `continue`. Its `key` forces `depth`, both lists and each
      # form's record, but no form's `system`, `versions` or `dependencies`,
      # which stay as lazy as the deferred-throw design needs.
      continue = index: depth: open: closed: {
        key = builtins.deepSeq [
          depth
          (map builtins.isAttrs open)
          (map builtins.isAttrs closed)
        ] index;
        inherit depth open closed;
      };
      scan =
        index: depth: open: closed:
        let
          token = tokenAt index;
        in
        if token.type == "open" then
          continue (index + 1) (depth + 1) (
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
          continue (index + 1) (depth - 1) (lib.filter (form: form.depth < depth) open) (
            closed ++ lib.filter (form: form.depth == depth) open
          )
        else if token.type == "atom" && lib.toLower token.value == ":version" then
          if !(builtins.any (form: form.depth == depth) open) then
            # A `:version` that is not a defsystem option -- a `defparameter`,
            # a component's own version -- is not system metadata. Skip it
            # BEFORE the literal-string checks, so unrelated code in the .asd
            # cannot make extraction fail.
            continue (index + 1) depth open closed
          else if index + 1 >= tokenCount || (tokenAt (index + 1)).type != "string" then
            fail "`:version` must be followed by a literal string"
          else if (tokenAt (index + 1)).escaped then
            fail "`:version` must not use string escapes"
          else
            continue (index + 2) depth (map (
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
            continue (index + 1) depth open closed
          else if index + 1 >= tokenCount then
            let
              poisoned = poison "ends the file with a `:depends-on` option that has no value";
            in
            continue (index + 1) depth poisoned closed
          else if
            (tokenAt (index + 1)).type == "atom" && lib.toLower (tokenAt (index + 1)).value == "nil"
          then
            # `:depends-on nil` is `:depends-on ()`: NIL *is* the empty list
            # in Common Lisp, not a stand-in for one, and ECL's own cmp.asd
            # spells it that way. Contributing nothing is the whole of it.
            continue (index + 2) depth open closed
          else if (tokenAt (index + 1)).type != "open" then
            # Quote the offending token, and say `end of file` only when
            # that is what it is: "must be followed by a list" alone left
            # the reader to find which of thirty options was meant.
            continue (index + 1) depth
              (poison "has `:depends-on` followed by ${describeToken (index + 1)}, which is neither a list nor `nil`")
              closed
          else
            let
              list = dependencyListAt (index + 1);
            in
            # `depth` is unchanged: `dependencyListAt` consumed a balanced
            # list, so `list.next` sits at the same nesting level as `index`.
            continue list.next depth (map (
              form:
              if form.depth == depth then form // { dependencies = form.dependencies ++ list.names; } else form
            ) open) closed
        else
          continue (index + 1) depth open closed;
      scanStates = builtins.genericClosure {
        startSet = [ (continue 0 0 [ ] [ ]) ];
        operator =
          state:
          if state.key == tokenCount then [ ] else [ (scan state.key state.depth state.open state.closed) ];
      };
      scanned = lib.last scanStates;
    in
    # A truncated file leaves forms open. Report the available context rather
    # than validating paren balance -- that is the Lisp reader's job, and
    # a half-written .asd will fail loudly at build time anyway.
    scanned.closed ++ scanned.open;

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
  # -- and is required without a default. The answer
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
