// Проверка JIT: флаг отладки и пробная страница RW → RX.
#include "forge_jit.h"
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>

int csops(pid_t pid, unsigned ops, void *useraddr, size_t usersize);

int forge_jit_debugged(void) {
	uint32_t flags = 0;
	if (csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, sizeof flags) != 0) return 0;
	return (flags & 0x10000000 /* CS_DEBUGGED */) != 0;
}

int forge_jit_probe(void) {
	size_t size = (size_t)getpagesize();
	void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
	if (p == MAP_FAILED) return 0;
	*(volatile uint32_t *)p = 0xd65f03c0;  // ret
	int ok = mprotect(p, size, PROT_READ | PROT_EXEC) == 0;
	munmap(p, size);
	return ok;
}
