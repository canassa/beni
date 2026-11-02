# Type browser render queues

Browser's after-render jobs, cancellation waiters and nested update inbox
now retain typed callbacks in the shared Chain module. Cancellation removes
its captured waiter link. Flush and phase callbacks have typed signatures;
hosted models and cached views use Maybe cells until initialized.

Rt snapshots render queues and calls their jobs through the typed protocol
invocation. Microtasks use the generated timer binding. Native DOM instance
storage and the Program/markup producer boundary remain for the next changes.

The focused TEA family passed 1,057 program runs in development and release,
including reentrant sends, after-render waits and defect cleanup. Behavioural
goldens were unchanged. HostFree remains off during the remaining migration;
full gates and run-hash recording are reserved for the final checkpoint.
