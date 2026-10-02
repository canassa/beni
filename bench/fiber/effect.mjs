// The Effect v4 side of the fiber runtime benchmark (docs/design/research/44-effects-runtime-spike.md §7):
// the same workloads as Bench.beni, written the way Effect's own benchmarks
// and documentation write them. Pinned to effect@4.0.0-rc.116, the version
// references/effect is checked out at.

import { Deferred, Effect, Fiber, Ref, Schedule } from "effect";
import { TestClock } from "effect/testing";

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

// `n` zero-length sleeps: Effect's real clock answers `sleep(0)` with
// `yieldNow`.
export const sleepZero = (n) =>
  Effect.runPromise(
    Effect.gen(function* () {
      let acc = 0;
      for (let i = 0; i < n; i++) {
        yield* Effect.sleep(0);
        acc += 1;
      }
      return acc;
    }),
  );

// Report 23 case 5.5: work that fails three times, retried on an
// exponential schedule of one hour, driven ten hours on the `TestClock`.
// Answers the number of attempts.
export const tenHours = () => {
  let n = 0;
  const flaky = Effect.suspend(() => {
    n++;
    return n < 4 ? Effect.fail("no") : Effect.succeed(n);
  });
  const program = Effect.gen(function* () {
    const f = yield* Effect.forkChild(flaky.pipe(Effect.retry(Schedule.exponential("1 hour"))));
    yield* TestClock.adjust("10 hours");
    return yield* Fiber.join(f);
  });
  return Effect.runPromise(program.pipe(Effect.provide(TestClock.layer())));
};

// `forEach` over `n` items, `concurrency: 16`, each answering its item.
export const forEachSixteen = (n) =>
  Effect.runPromise(
    Effect.forEach(Array.from({ length: n }, (_, i) => i + 1), (i) => Effect.succeed(i), { concurrency: 16 }).pipe(
      Effect.map((xs) => xs.reduce((a, b) => a + b, 0)),
    ),
  );

// `n` times, `all` of two effects that answer at once, run concurrently.
export const parFast = (n) =>
  Effect.runPromise(
    Effect.gen(function* () {
      let acc = 0;
      for (let i = 0; i < n; i++) {
        const [a, b] = yield* Effect.all([Effect.succeed(1), Effect.succeed(1)], { concurrency: "unbounded" });
        acc += a + b - 1;
      }
      return acc;
    }),
  );

// `n` times, `raceFirst` of two branches that each yield once.
export const raceParked = (n) =>
  Effect.runPromise(
    Effect.gen(function* () {
      let acc = 0;
      const branch = Effect.as(Effect.yieldNow, 1);
      for (let i = 0; i < n; i++) acc += yield* Effect.raceFirst(branch, branch);
      return acc;
    }),
  );

// `n` times, `timeoutOption` of a minute around an effect that answers at
// once.
export const timeoutFast = (n) =>
  Effect.runPromise(
    Effect.gen(function* () {
      let acc = 0;
      for (let i = 0; i < n; i++) {
        const got = yield* Effect.timeoutOption(Effect.succeed(1), "1 minute");
        acc += got._tag === "Some" ? got.value : 0;
      }
      return acc;
    }),
  );
