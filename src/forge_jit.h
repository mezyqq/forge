#ifndef FORGE_JIT_H
#define FORGE_JIT_H

// Флаг CS_DEBUGGED (процесс «под отладчиком» — так JIT включают StikDebug, SideStore, LiveContainer).
int forge_jit_debugged(void);

// Пробует выдать память под код так же, как ORC JIT: mmap(RW) → mprotect(RX). 1 — получилось.
// Нужна для способов, которые не выставляют CS_DEBUGGED (например, Lara). Код в пробной странице не исполняется.
int forge_jit_probe(void);

#endif
