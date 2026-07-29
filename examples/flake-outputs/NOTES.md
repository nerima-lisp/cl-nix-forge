# Planted fixture

A tracked, perfectly legitimate file that the build nonetheless does not read.
`mkLispSource` keeps it out by default, so editing it cannot rebuild the
package. Files a build genuinely needs are opted in with `include` -- see the
`docs/` tree, which the `forge-demo-source-filter` check pulls in that way.
