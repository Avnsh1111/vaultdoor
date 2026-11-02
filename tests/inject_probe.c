/* Plays the part of a library injected into the vault to read its memory. */
#include <stdio.h>
__attribute__((constructor)) static void hello(void) { puts("INJECTED"); }
