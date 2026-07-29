# forge-preset (repo-rooted docs)

The second docs shape: the site is rooted at the repository, not at its own
directory, because the changelog page snippet-includes the top-level
`CHANGELOG.md` and `pymdownx.snippets` resolves paths against the working
directory `mkdocs` runs in.

This is what `cl-weave` does, and it is why `mkPackageFlake`'s `docs`
argument is passed through to `mkDocsSite` rather than reduced to a single
`root`.
