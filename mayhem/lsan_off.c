/* Leak detection is off for every target; ASan and UBSan stay fully active. */
int __lsan_is_turned_off (void) { return 1; }
