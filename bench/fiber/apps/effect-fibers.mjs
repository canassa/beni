// Fibers.beni in Effect v4, for size.mjs: a scope, an acquire/release, a
// fork into the scope, a join and a sleep.
import { Effect, Fiber } from "effect";

const worker = (n) => Effect.as(Effect.sleep(1), n * 2);

const program = Effect.scoped(
  Effect.gen(function* () {
    const r = yield* Effect.acquireRelease(Effect.succeed(21), () => Effect.void);
    const fiber = yield* Effect.forkScoped(worker(r));
    return yield* Fiber.join(fiber);
  }),
);

Effect.runFork(Effect.map(program, (answer) => console.log(String(answer))));
