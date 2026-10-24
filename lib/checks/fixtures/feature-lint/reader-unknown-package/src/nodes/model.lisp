(in-package "fixture/valid/nodes")

(defstruct node)

(defvar *foreign-public* unknown.reader.pkg:external-symbol)
(defvar *foreign-internal* unknown.reader.pkg::internal-symbol)
