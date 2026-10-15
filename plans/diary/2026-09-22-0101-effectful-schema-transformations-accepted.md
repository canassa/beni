## 2026-09-22 01:01 CEST — effectful schema transformations accepted

**What I did**

- Recorded the owner's agreement to support effectful transformations, with a
  synchronous first delivery permitted, in the queue and report 32's update notice.
  No implementation changed.

**What I learned**

- Separating validation and enrichment is a usage recommendation, not a restriction.
  Stored-function effect propagation, suspension and cancellation need investigation
  before committing to the schema representation; the capability decision does not
  itself resolve H4 or commission runtime implementation.
