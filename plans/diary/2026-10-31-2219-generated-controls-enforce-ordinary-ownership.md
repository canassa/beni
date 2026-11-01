# Generated controls now use the ordinary APP ownership diagnostic route

2026-10-31T22:19:40+01:00, Dagon. Issue #1515; #1404 remains separate and unfixed.
Norm §23 was written before code. C76 is retained unchanged in the parent cost
checkpoint and the isolated Ref preflight lane. No production Task/Ref change.

Validated deterministic runtime source now selects the existing Session.core
option, just as ordinary CLI --core does, while GeneratedControls and the fixed
bridge have APP graph identity. Arbitrary GeneratedUnit.check stays core=false.
Imported Ref/Maybe identities stay CORE. This fixes the skipped ownership report
path, not ownership rules: own1 CORE reports previously required pack creation;
own2 CORE reports returned before application diagnostics.

The receipt now labels enforcement as sourceOwnershipEnforced and
generatedOwnershipEnforced, with owningStorageProved=false. Own2 source/generated
reports are retained from the actual checker runs and rendered directly, showing
unchecked callback bodies and zero demands. Missing warm evidence is unavailable;
there is no second checker run, text-derived certificate or full-owning claim.

The canonical ownership-conflict producer fault reaches real ordinary diagnostics
before provenance. Both own1/own2 report list_still_used with empty stdout. Full
actual JSON is retained in fixture files; source origins remain one document.

Validation: 2 new named fault cases pass, then expanded 22-case checked-controls
suite passes (0 skipped/failed/leaked). First suite run had one assertion failure:
it expected GeneratedControls before ControlBridge; actual deterministic graph
order prints the bridge first. Failure retained and assertion corrected. Focused
GeneratedUnit build passes; direct named replay is 10 semantic helper tests plus
2 infrastructure test_0 cases, all pass under existing budgets. Explicit unit
assertions pin APP/core=true for canonical runtime and APP/core=false for arbitrary
source. No full gates, cost run, LLVM, cap or budget changes.

Debug SHA6f9e96adb3dc9c0b9098435c743856fdf11952748d42512a13d083f5dd0e04dd.
Evidence: parent scratch/typed-control-ownership-fix. Root owns independent review
and full gates. This still proves ordinary typing/source mapping, not owning
Slot extraction, complete closure coverage, or runtime migration.
