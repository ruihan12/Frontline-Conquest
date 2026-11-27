/* glibc compatibility for the Linux builds of the Luau extension (tools/luau_ext/build.sh).
 *
 * The build machine has glibc 2.39; Godot 4.5.1's official Linux binaries need only glibc 2.28, so a server
 * on an older distribution runs Godot but would refuse to load an extension that asks for newer symbol
 * versions. This object is linked into libgdluau and defines, with hidden visibility, every symbol the
 * library would otherwise import at a version above 2.28. Each one forwards to the oldest version of the
 * same glibc symbol (bound with .symver), or is implemented here where older glibc has no such function.
 * After the build, `objdump -T` must list nothing above GLIBC_2.28 (build.sh checks it).
 */
#define _GNU_SOURCE 1
#include <dlfcn.h>
#include <link.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/random.h>
#include <unistd.h>

#if defined(__x86_64__)
#define GLIBC_OLD "GLIBC_2.2.5"
#elif defined(__aarch64__)
#define GLIBC_OLD "GLIBC_2.17"
#else
#error "glibc_compat.c: unsupported architecture"
#endif

#define HIDDEN __attribute__((visibility("hidden")))
#define OLD(local, sym) __asm__(".symver " #local "," #sym "@" GLIBC_OLD)

/* math: glibc 2.29 / 2.38 added new versions of these; the old ones give the same results. */
extern double old_fmod(double, double); OLD(old_fmod, fmod);
extern float old_fmodf(float, float); OLD(old_fmodf, fmodf);
extern double old_exp(double); OLD(old_exp, exp);
extern double old_log(double); OLD(old_log, log);
extern double old_log2(double); OLD(old_log2, log2);
extern double old_pow(double, double); OLD(old_pow, pow);
HIDDEN double fmod(double x, double y) { return old_fmod(x, y); }
HIDDEN float fmodf(float x, float y) { return old_fmodf(x, y); }
HIDDEN double exp(double x) { return old_exp(x); }
HIDDEN double log(double x) { return old_log(x); }
HIDDEN double log2(double x) { return old_log2(x); }
HIDDEN double pow(double x, double y) { return old_pow(x, y); }

/* strto*: glibc 2.38 headers redirect C++ callers to the C23 versions (which also accept 0b prefixes). */
extern long old_strtol(const char *, char **, int); OLD(old_strtol, strtol);
extern unsigned long old_strtoul(const char *, char **, int); OLD(old_strtoul, strtoul);
extern long long old_strtoll(const char *, char **, int); OLD(old_strtoll, strtoll);
extern unsigned long long old_strtoull(const char *, char **, int); OLD(old_strtoull, strtoull);
HIDDEN long __isoc23_strtol(const char *s, char **e, int b) { return old_strtol(s, e, b); }
HIDDEN unsigned long __isoc23_strtoul(const char *s, char **e, int b) { return old_strtoul(s, e, b); }
HIDDEN long long __isoc23_strtoll(const char *s, char **e, int b) { return old_strtoll(s, e, b); }
HIDDEN unsigned long long __isoc23_strtoull(const char *s, char **e, int b) { return old_strtoull(s, e, b); }

/* pthread (libstdc++'s weak references): in libc.so.6 since 2.34, in libpthread.so.0 before; the old
 * versions exist in both, and Godot itself loads the threads library. */
extern int old_pthread_once(void *, void (*)(void)); OLD(old_pthread_once, pthread_once);
extern int old_pthread_key_create(void *, void (*)(void *)); OLD(old_pthread_key_create, __pthread_key_create);
HIDDEN int pthread_once(void *once, void (*fn)(void)) { return old_pthread_once(once, fn); }
HIDDEN int __pthread_key_create(void *key, void (*dtor)(void *)) { return old_pthread_key_create(key, dtor); }

/* libstdc++ reads this to skip atomics in single-threaded processes (glibc 2.32); 0 = always use atomics. */
HIDDEN char __libc_single_threaded = 0;

/* arc4random (glibc 2.36; std::random_device): fill from getrandom (2.25). */
HIDDEN uint32_t arc4random(void) {
	uint32_t v = 0;
	while (getrandom(&v, sizeof(v), 0) != (ssize_t)sizeof(v)) {
	}
	return v;
}

/* _dl_find_object (glibc 2.35): libgcc's unwinder uses it to find the .eh_frame_hdr of the object that
 * contains a PC (C++ exceptions, which Luau uses for errors). Same answer from dl_iterate_phdr. */
struct find_ctx {
	uintptr_t pc;
	struct dl_find_object *out;
	int found;
};

static int find_cb(struct dl_phdr_info *info, size_t size, void *data) {
	(void)size;
	struct find_ctx *c = (struct find_ctx *)data;
	uintptr_t lo = UINTPTR_MAX, hi = 0;
	int hit = 0;
	const void *eh = NULL;
	for (int i = 0; i < info->dlpi_phnum; i++) {
		const ElfW(Phdr) *p = &info->dlpi_phdr[i];
		if (p->p_type == PT_LOAD) {
			uintptr_t a = info->dlpi_addr + p->p_vaddr;
			uintptr_t b = a + p->p_memsz;
			if (a < lo) lo = a;
			if (b > hi) hi = b;
			if (c->pc >= a && c->pc < b) hit = 1;
		} else if (p->p_type == PT_GNU_EH_FRAME) {
			eh = (const void *)(info->dlpi_addr + p->p_vaddr);
		}
	}
	if (!hit) return 0;
	c->out->dlfo_flags = 0;
	c->out->dlfo_map_start = (void *)lo;
	c->out->dlfo_map_end = (void *)hi;
	c->out->dlfo_link_map = NULL;
	c->out->dlfo_eh_frame = (void *)eh;
	c->found = 1;
	return 1;
}

HIDDEN int _dl_find_object(void *pc, struct dl_find_object *result) {
	struct find_ctx c = {(uintptr_t)pc, result, 0};
	dl_iterate_phdr(find_cb, &c);
	return c.found ? 0 : -1;
}
