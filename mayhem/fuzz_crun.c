/* Mayhem entry point over the in-tree crun harness (tests/tests_libcrun_fuzzer.c).
   The upstream file selects its target at run time with FUZZING_MODE; here the
   mode is fixed per binary with -DFUZZ_MODE=<n> so each mode is its own target.
   FUZZ_MODE=100 runs the small string parsers (modes 3, 6, 7, 8, 9) in one binary.  */
#define main crun_upstream_main
#define LLVMFuzzerTestOneInput crun_upstream_one_input
#include "../tests/tests_libcrun_fuzzer.c"
#undef main
#undef LLVMFuzzerTestOneInput

#ifndef FUZZ_MODE
#error "compile with -DFUZZ_MODE=<n>"
#endif

int
LLVMFuzzerTestOneInput (const uint8_t *data, size_t size)
{
  uint8_t *buf;

  if (size == 0)
    return -1;

  /* The upstream code takes a mutable buffer and reads buf[0] in places.  */
  buf = malloc (size);
  if (buf == NULL)
    return -1;
  memcpy (buf, data, size);

#if FUZZ_MODE == 100
  run_one_test (3, buf, size);
  run_one_test (6, buf, size);
  run_one_test (7, buf, size);
  run_one_test (8, buf, size);
  run_one_test (9, buf, size);
#else
  run_one_test (FUZZ_MODE, buf, size);
#endif

  free (buf);
  return 0;
}
