// The Effect v4 side of the fiber runtime benchmark (docs/design/research/44-effects-runtime-spike.md §7):
// the same workloads as Bench.beni, written the way Effect's own benchmarks
// and documentation write them. Pinned to effect@4.0.0-rc.116, the version
// references/effect is checked out at.

import { Deferred, Effect, Fiber, Ref } from "effect";

// `n` synchronous operations chained by `flatMap`: Effect's interpreter
// step, the thing a beni suspension point on its fast path replaces.
export const loopFlatMap = (n) => {
  const go = (i, acc) => (i === 0 ? Effect.succeed(acc) : Effect.flatMap(Effect.sync(() => acc + 1), (a) => go(i - 1, a)));
  return Effect.runSync(Effect.suspend(() => go(n, 0)));
};

// The same with a generator, the style Effect's documentation leads with.
export const loopGen = (n) =>
  Effect.runSync(
    Effect.gen(function* () {
      let acc = 0;
      for (let i = 0; i < n; i++) acc = yield* Effect.sync(() => acc + 1);
      return acc;
    }),
  );

// `n` suspension points that really park: `yieldNow`.
export const loopYielding = (n) =>
  Effect.runPromise(
    Effect.gen(function* () {
      let acc = 0;
      for (let i = 0; i < n; i++) {
        yield* Effect.yieldNow;
        acc += 1;
      }
      return acc;
    }),
  );

// `n` child fibers, each yielding once and answering its index; joined in
// order and summed.
export const fanOut = (n) =>
  Effect.runPromise(
    Effect.gen(function* () {
      const fibers = [];
      for (let i = 1; i <= n; i++) fibers.push(yield* Effect.forkChild(Effect.as(Effect.yieldNow, i)));
      let sum = 0;
      for (const f of fibers) sum += yield* Fiber.join(f);
      return sum;
    }),
  );

// `n` hand-offs through a `Deferred`: a forked fiber awaits a new one, the
// caller succeeds it, and the waiter is joined.
export const deferredHandoff = (n) =>
  Effect.runPromise(
    Effect.gen(function* () {
      let acc = 0;
      for (let i = 0; i < n; i++) {
        const d = yield* Deferred.make();
        const f = yield* Effect.forkChild(Deferred.await(d));
        yield* Effect.yieldNow;
        yield* Deferred.succeed(d, 1);
        acc += yield* Fiber.join(f);
      }
      return acc;
    }),
  );

// `n` times a new `Deferred` succeeded and then awaited: the await answers
// at once.
export const deferredReady = (n) =>
  Effect.runPromise(
    Effect.gen(function* () {
      let acc = 0;
      for (let i = 0; i < n; i++) {
        const d = yield* Deferred.make();
        yield* Deferred.succeed(d, 1);
        acc += yield* Deferred.await(d);
      }
      return acc;
    }),
  );

// `n` updates of one `Ref`.
export const refUpdates = (n) =>
  Effect.runSync(
    Effect.gen(function* () {
      const r = yield* Ref.make(0);
      for (let i = 0; i < n; i++) yield* Ref.update(r, (x) => x + 1);
      return yield* Ref.get(r);
    }),
  );

// `n` detached fibers, each forked and joined in turn.
export const detachJoin = (n) =>
  Effect.runPromise(
    Effect.gen(function* () {
      let acc = 0;
      for (let i = 0; i < n; i++) acc += yield* Fiber.join(yield* Effect.forkDetach(Effect.succeed(1)));
      return acc;
    }),
  );
