# Keep browser storage areas typed

Web Storage now uses generated native operations instead of storing its area
in Js.Value. The source module keeps the existing unavailable/quota values,
with typed key accumulation. The native adapters catch only SecurityError on
area access and QuotaExceededError on writes, both actual DOMExceptions.
Unknown throws retain their identity.

The StorageAdapters run fixture checks normal operations, unavailable areas,
quota errors, disappearing keys and unknown exceptions in development and
release. Native catalogue validation and StorageBasics also pass.
