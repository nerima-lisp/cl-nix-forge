# forge-preset

The common docs shape: everything the site needs lives under `docs/`, so
`mkPackageFlake` is told `docs = { root = ./docs; }` and fills in the package
name and the version from the `.asd` itself.

This is what `cl-prolog-kit` and `cl-json-kit` do.
