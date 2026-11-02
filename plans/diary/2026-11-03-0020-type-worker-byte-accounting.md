# Type worker byte accounting

The byte-budget work stack now uses the shared typed Chain. UTF-8 pricing uses
the existing generated TextEncoder and Uint8Array operations; record traversal
uses typed data keys. The native-buffer branch is removed because Wire rejects
native graphs before this helper.

A managed ByteLimits fixture checks UTF-8 boundaries, outstanding reservations
and capacity after a ticket completes. It and the focused bootstrap, options,
list, generic and mixed Wire fixtures pass in Chromium. Behavioral goldens for
existing fixtures stayed unchanged.
