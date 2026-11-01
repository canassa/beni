# Resident diagnostic revisions

The external test driver calls the public Session API on disk revisions of
Main.beni. It reuses one Session, refreshes its public SourceStore and emits
only the ordinary diagnostic documents. The same cached warning appears once
in each of the first two runs, the next run has one type error, and repairing
the source gives an empty diagnostic array. The registered black-box scenario
compares the complete transcript with one worker. The driver does
not inspect workers or clear diagnostics itself.
