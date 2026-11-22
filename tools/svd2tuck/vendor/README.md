# Vendored parser front half

Copied verbatim from EmbeddedNim/svd2nim v0.6.2
(https://github.com/EmbeddedNim/svd2nim), MIT licensed; see `LICENSE-MIT`.

| File | Role |
| --- | --- |
| `basetypes.nim` | typed SVD model (`SvdDevice`, `SvdRegisterTreeNode`, …) |
| `svdparser.nim` | XML reader (`readSVD`) |
| `transformations.nim` | `derivedFrom`, dim expansion, property resolution |
| `utils.nim` | identifier and placeholder helpers |

The upstream `codegen.nim`, CLI and test suite are deliberately absent: this
tool emits Tuck, not Nim. No local edits were made to these four files.
