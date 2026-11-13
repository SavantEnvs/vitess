package main

// Importing "C" makes the toolchain link externally, so the KAT probe is a dynamically linked ELF.
// verify-repo's sabotage check LD_PRELOADs a shim that _exit(0)s non-system executables; a static
// Go binary would ignore it and mayhem/test.sh could not detect a neutered program. build.sh
// asserts the probe is dynamically linked.

/*
#include <stdlib.h>
*/
import "C"

var _ = C.EXIT_SUCCESS
