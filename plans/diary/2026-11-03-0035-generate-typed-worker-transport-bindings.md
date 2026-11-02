# Generate typed worker transport bindings

The native catalogue now supplies typed Worker construction, endpoint identity,
postMessage, termination, global event targets and native error projection.
Only documented constructor and clone failures become values; unknown thrown
objects keep their identity. The worker peer migration can use these bindings
without moving native handles through Js.Value.

Message-data projection shares the approved runtime graph check with
Js.Data.checked. One source body generates both adapters. Plain records,
arrays and cycles pass; functions, native objects and accessors do not. This
factoring leaves the program-type native scalar witness for the later compiler
step; it does not resolve that outstanding work.

Native validation passes. NativeMessageData and WorkerNativeAdapters pass in
development and release, including getter/callback non-invocation, exact error
mapping, native identity, listener removal and native rejection metadata.
SchemaReportInput also passes after sharing the runtime check.
