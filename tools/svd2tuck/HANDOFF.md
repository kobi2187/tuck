# svd2tuck — handoff

Standalone Nim SVD-to-Tuck generator is built and green. It vendors the MIT
svd2nim parser front half, emits absolute-address `register` modules with
notes for dropped SVD features, and has committed STM32F103 full and Blue Pill
outputs. The generated register module imports cleanly on Nim, Odin and D after
the compiler seam fix, and the Blue Pill LED fixture boots to idle under QEMU
with the same result as the hand-written one. Next work belongs to T9/T10
(clock tree, board self-checks) or, if register semantics grow, a language
decision about typestate — not to this tool.
