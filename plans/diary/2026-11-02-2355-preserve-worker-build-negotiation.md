## Preserve worker build negotiation across private layouts

**What I did**

Kept transport headers and Hello/Defect labels stable across development and
release. Fingerprint rejection now precedes interpretation of the other build's
control layout. Added a Chrome fixture that routes each page to the real worker
artifact from the opposite build and checks ProtocolVersionMismatch before init.
Added a positive assertion for numeric release Request frames. Replaced the two
encoded dollar spellings and documented the release-only private-object exception
in boundary §4. Tracked the spelling/provenance guard in #1733.

**What I learned**

Within-build agreement is not enough for a protocol optimizer. The negotiation
envelope must remain readable before peers know whether their layouts agree.
