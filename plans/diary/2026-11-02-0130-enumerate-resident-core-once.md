# Enumerate resident core once

Session queued embedded or disk core again on every resident run, after the
store had already numbered the first run's files. Duplicate modules replaced
the second run's diagnostics. Track successful core enumeration in Session and
reuse those store rows; the external driver keeps core_package enabled.

The complete warning, cached-warning, Int-versus-unit and repaired transcript
now runs against both embedded and disk core with a DebugAllocator. Both
scenarios fail on duplicate modules before the enumeration guard and pass after.
Removed the driver's needless serial dependency on the safe executable; its
library import already carries generated-file dependencies and backend options.
