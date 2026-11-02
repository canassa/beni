
---
### aturon 2015-05-28T17:40:09Z

What's going on here is that `foo` gets to assume that `'b: 'a`, but this isn't actually checked when producing `f`.

This assumption was thought to be valid because any nested reference type `&'a &'b T` has to guarantee it for well-formedness. But variance currently allows you to switch around the lifetimes before actually passing in the witnessing argument.


---
### nikomatsakis 2015-05-28T18:02:02Z

One solution is to be more aggressive about checking WFedness, but there are other options to consider.


---
### nikomatsakis 2015-06-02T19:35:08Z

triage: P-high T-lang


---
### nikomatsakis 2015-06-02T19:35:50Z

I've been working on some proposal(s) that address this bug (among others), so assigning to me.


---
### nikomatsakis 2015-06-15T16:41:23Z

There is a related problem that doesn't require variance on argument types. The current codebase doesn't check that the _expected_ argument type is well-formed, only the provided one, which is a subtype of the expected one. This is insufficient (but easily rectified).


---
### Stebalien 2015-09-30T01:40:22Z

@nikomatsakis I believe you meant to close this.


---
### nikomatsakis 2015-09-30T18:58:25Z

The work needed to close this has not yet landed. It's in the queue though, once we finish up rust-lang/rfcs#1214.


---
### Stebalien 2015-09-30T19:05:02Z

Sorry, I saw the commit but didn't notice that it hadn't been merged.


---
### pnkfelix 2016-01-21T08:44:42Z

One interesting thing to note, in light of the new WF checks that have landed with the preliminary implementation of rust-lang/rfcs#1214, is that if we change the definition of `fn foo` like this (where we rewrite the implied lifetime bounds to be _explicitly_ stated in a where-clause  :

``` rust
fn foo<'a, 'b, T>(_: &'a &'b (), v: &'b T) -> &'a T where 'b: 'a { v }
```

then it seems like the code is rejected properly.

I am currently trying to puzzle through whether this kind of "switch from implicit to explicit", assuming it were done as a kind of desugaring by the compiler, if that would be effectively the same as "remove support for contravariance" from the language, or if it represents some other path...


---
### pnkfelix 2016-01-22T13:20:04Z

Here's a variation on the original example that retains explicit types (rather than resorting to `_` as a type like I did in the description):

``` rust
fn foo<'a, 'b, T>(_false_witness: Option<&'a &'b ()>, v: &'b T) -> &'a T { v }

fn bad<'c, 'd, T>(x: &'c T) -> &'d T {
    // below is using contravariance to assign `foo` to `f`,
    // side-stepping the obligation to prove `'c: 'd`
    // implicit in the original `fn foo`.
    let f: fn(Option<&'d &'d ()>, &'c T) -> &'d T = foo;
    f(None, x)
}

fn main() {
    fn inner() -> &'static String {
        bad(&format!("hello"))
    }

    let x = inner();
    println!("x: {}", x);
}
```


---
### pnkfelix 2016-01-22T13:42:53Z

> I am currently trying to puzzle through whether this kind of "switch from implicit to explicit", assuming it were done as a kind of desugaring by the compiler, if that would be effectively the same as "remove support for contravariance" from the language

After some reflection, I think this does represent a (perhaps appropriately) _weakened_ variation on "remove contravariance from the language"

In particular, if we did the desugaring right (where implied lifetime bounds from a `fn`-signature would get transformed into where clauses on the `fn`), then we could still have useful contravariance for `fn`'s that have _no such_ implied bounds.


---
### pnkfelix 2016-01-22T13:51:43Z

as an aside, part of me does think that it would be _better_ if we also added some way to write the proposed implied `where`-clauses explicitly as part of the `fn`-type.  I.e. if you consider the following example:

``` rust
fn bad<'a, 'b>(g: fn (&'a &'b i32) -> i32) {
    let _f: fn(x: &'b &'b i32) -> i32 = g;
}
```

under my imagined new system, the above assignment of `g` to `_f` would be illegal, due to the implied bounds attached to `g` (that are not part of the type of `_f`).

But it might be nice if we could actually _write_:

``` rust
fn explicit_types<'a, 'b>(callback: fn (&'a i32, &'b i32) -> i32 where 'a: 'b) {
    ...
}
```

(note that the `where` clause there is part of the type of `callback`)


---
### RalfJung 2016-01-22T15:55:27Z

I take it from your comments that removing or restricting the variance is actually considered as a solution to this?

That's surprising me. I cannot see variance at fault here. The observation underlying the issue is that implicit bounds are not properly preserved under variance. The most obvious solution (for me, anyways) would be to make the implicit bounds explicit: If "fn foo<'a, 'b, T>(&'a &'b (), &'b T) -> &'a T" would be considered mere syntactic sugar for "fn foo<'a, 'b, T>(&'a &'b (), &'b T) -> &'a T where 'b: 'a, 'a: 'fn, T: 'b" (using `'fn` for the lifetime of the function), and from then on the checks are preserved and adapted appropriately when applying variance or specializing lifetimes, wouldn't that also catch the trouble? (Making implied bounds explicit was also discussed in https://github.com/rust-lang/rfcs/pull/1327, since implied bounds are also a trouble for drop safety.)


---
### pnkfelix 2016-01-22T16:12:06Z

@RalfJung 

> I cannot see variance at fault here.

I've been saying the similar things to @nikomatsakis 

But the first step for me was to encode the test case in a way that made made it apparent (at least to me) that contravariance is (part of) why we are seeing this happen.

I think that https://github.com/rust-lang/rust/issues/25860#issuecomment-173926193 is very much the same as what you are describing: 1. Ensure the implicit bounds are actually part of the `fn`-type itself (even if most users will not write the associated `where` clause explicitly) and are checked before allowing any calls to a value of a given `fn`-type, and then 2. fix the subtyping relation between `fn`-types to ensure that such `where`-clauses are preserved.


---
### RalfJung 2016-01-22T16:16:04Z

> I think that #25860 (comment) is very much the same as what you are describing: 1. Ensure the implicit bounds are actually part of the fn-type itself (even if most users will not write the associated where clause explicitly) and are checked before allowing any calls to a value of a given fn-type, and then 2. fix the subtyping relation between fn-types to ensure that such wshere-clauses are preserved.

Yes, that sounds like we're talking about the same idea.


---
### nikomatsakis 2016-01-22T18:55:21Z

I do not consider the problem to be fundamentally about contravariance -- but I do consider removing contravariance from fn arguments to be a pragmatic way to solve the problem, at least in the short term. In one of the drafts for RFC rust-lang/rfcs#1214, I wrote [the section pasted below](https://github.com/nikomatsakis/rfcs/blob/sionara-contravariance/text/0000-wf-and-variance.md#appendix-forwhere-an-alternative-view), which I think is a good explanation of the problem as I understand it:

### Appendix: for/where, an alternative view

The natural generalization of our current `fn` types is adding the ability to attach arbitrary where clauses to higher-ranked types. That is, a type like `for<'a,'b> fn(&'a &'b T)` might be written out more explicitly by adding the implied bounds as explicit where-clauses attached to the `for`:

```
for<'a,'b> where<'b:'a, T:'b> fn(&'a &'b T)
```

These where-clauses must be discharged before the fn can be called. They can also be discharged through subtyping, if no higher-ranked regions are involved: that is, there might be a typing rule that allows a where clause to be dropped from the type so long as it can be proven in the current environment (similarly, having fewer where clauses would be a subtype of having more.)

You can view the current notion of implied bounds as being a more limited form of this formalism where the `where` clauses are exactly the implied bounds of the argument types. However, making the `where` clauses explicit has some advantages, because it means that one can vary the types of the arguments (via contravariance) while leaving the where clauses intact.

For example, if you had a function:

```
fn foo<'a,'b,T>(&'a &'b T) { ... }
```

Under this RFC, the type of this function is:

```
for<'a,'b> fn(&'a &'b T)
```

Under the for/where scheme, the full type would be:

```
for<'a,'b> where<'b:'a, T:'b> fn(&'a &'b T)
```

Now, if we upcast this type to only accept static data as argument, the where clauses are unaffected:

```
for<'a,'b> where<'b:'a, T:'b> fn(&'static &'static T)
```

Viewed this way, we can see why the current fn types (in which one cannot write where clauses explicitly) are invariant: changing the argument types is fine, but it also changes the where clauses, and the new where clauses are not a superset of the old ones, so the subtyping relation does not hold. That is, if we write out the implicit where clauses that result implicitly, we can see why variance on fns causes problems:

```
for<'a,'b> where<'b:'a, T:'b> fn(&'a &'b T, &'b T) -> &'a T 
<:
for<'a,'b> fn(&'static &'static T, &'b T) -> &'a T
? (today yes, under this RFC no)
```

Clearly, this subtype relationship should not hold, because the where clauses in the subtype are not implied by the supertype.


---
### arielb1 2016-01-22T20:56:54Z

To make the point clearer, the principal part of the issue involves higher-ranked types. The rank 0 issue should not be that hard to solve (by requiring WF when instantiating a function - I am a bit surprised we don't do so already).

An example of the problem path (I am intentionally making the problem binder separate from the problem where-clause-container):

``` Rust

fn foo<'a, 'b, T>() -> fn(Option<&'a &'b ()>, &'b T) -> &'a T {
    fn foo_inner<'a, 'b, T>(_witness: Option<&'a &'b ()>, v: &'b T) -> &'a T {
        v
    }
    foo_inner
}

fn bad<'c, 'd, T>(x: &'c T) -> &'d T {
    // instantiate `foo`
    let foo1: for<'a, 'b> fn() -> fn(Option<&'a &'b ()>, &'b T) -> &'a T = foo;
    // subtyping: instantiate `'b <- 'c`
    let foo2: for<'a> fn() -> fn(Option<&'a &'c ()>, &'c T) -> &'a T = foo1;
    // subtyping: contravariantly 'c becomes 'static
    let foo3: for<'a> fn() -> fn(Option<&'a &'static ()>, &'c T) -> &'a T = foo2;
    // subtyping: instantiate `'a <- 'd`
    let foo4: fn() -> fn(Option<&'d &'static ()>, &'c T) -> &'d T = foo3;
    // boom!
    foo4()(None, x)
}

fn main() {
    fn inner() -> &'static String {
        bad(&format!("hello"))
    }

    let x = inner();
    println!("x: {}", x);
}
```


---
### brson 2016-06-23T16:37:27Z

@rust-lang/lang no activity in a while. Still P-high? Anybody working on it or can we lower it?


---
### pnkfelix 2016-06-23T21:31:57Z

(this issue really wants input from @nikomatsakis )


---
### nikomatsakis 2016-07-01T15:54:59Z

I think we need to make progress on this issue, but I've been saying that for a year and we haven't. I would put this on the list of "important soundness issues" to address but I'm not sure how to prioritize that work in general relative to other tasks.

As far as the range of possible fixes I think nothing has changed from [this previous comment](https://github.com/rust-lang/rust/issues/25860#issuecomment-174011431):
- We can ban contravariance, at least for fn arguments.
- We can make `for` carry a notion of bounds, at least internally. 

From a purely theoretical point-of-view, I would prefer the latter but I am wary of trying to implement it. It seems obvious that it will be hard to do in a complete way if we are talking about arbitrary sets of bounds. On the other hand, it may be that if we are just talking about _implied bounds_, we can implement the checks in a pretty simple way, since the bounds in question will have particular forms. I've been meaning to take some time and think about this more -- I think that some of the work being done for lazy normalization may help here -- but I've not really done so.

As far as the user-visible language changes that would result, removing contravariance for fn args is a nice simplification, but it is almost certainly more backwards incompatible than something based on making `for` carry a notion of bounds. When I first checked, the impact was small, but we have tarried quite some time and I don't know if that is still true.


---
### aturon 2016-07-07T21:25:47Z

The lang team met and determined that we should move to P-medium; no one is going to close this in the near future, but we want to keep it on the radar.


---
### nikomatsakis 2017-03-03T13:40:58Z

After some further thought -- and in particular working more on chalk -- I have started to have some hope that we would be able to close this using the [more principled approach described here](https://github.com/rust-lang/rust/issues/25860#issuecomment-174011431). Basically the idea would be that `for<'a> fn(...)` has "implied bounds" that are sufficient to make the `fn` well-formed, and that when we upcast we have to prove an "entailment" for the type that we are casting to. I used to be afraid of this entailment but I am... less afraid now. =) More investigation needed, of course.

---
### RalfJung 2019-07-28T09:29:31Z

Cc https://crates.io/crates/fake-static

---
### XX 2021-04-18T03:20:17Z

What is the current status of fixing this bug? Rust-haters use this hole to demonstrate that the language is not safe.

---
### ssokolow 2021-04-18T04:24:50Z

@XX This one specifically? As someone with no background in programming language theory, I'm curious what makes this one so special.

---
### RalfJung 2021-04-18T08:30:13Z

I don't think there was any progress, unfortunately.

That said, haters gonna hate -- I don't think that is a healthy reason to do anything.^^ There are much better reasons.

> As someone with no background in programming language theory, I'm curious what makes this one so special.

As someone with background in PL theory, I don't know. ;) I assume it's just because it's one of the oldest still-unresolved soundness bugs.

---
### stanislav-tkach 2021-04-21T15:46:07Z

I have also seen code snippets exploiting this issue as a response for "safe rust guaranties..." claims more than once.

> I assume it's just because it's one of the oldest still-unresolved soundness bugs.

I guess this is true. Personally, I also think that having this issue open for five years is kind of disturbing. :upside_down_face: 

---
### Cerber-Ursi 2022-01-17T03:15:40Z

Bumping an issue, since it was found [(link to the corresponding URLO post)](https://users.rust-lang.org/t/negative-views-on-rust-language-based-operating-systems/70449/26) that this problem allows one to easily write `transmute` in safe code (without any IO, like `totally_safe_transmute` does, only by exploiting the soundness hole).

---
### lcnr 2022-02-05T15:45:31Z

wrote a blog post summarizing this issue and adding an example why I believe removing contravariance is not enough to fix this bug.

https://lcnr.de/blog/2022/02/05/diving-deep-implied-bounds-and-variance.html

---
### crlf0710 2022-02-06T07:07:59Z

I took a brief look into this issue, and it seems rust language contravariance rules and borrow checker can do the needed detection.

Here's my inspection, i'm using `arielb`'s example code as starting point. It's obvious that the first incorrect cast is the foo2 to foo3 conversion.
```rust
fn bad<'c, 'd, T>(x: &'c T) -> &'d T {
    // instantiate `foo`
    let foo1: for<'a, 'b> fn() -> fn(Option<&'a &'b ()>, &'b T) -> &'a T = foo;
    // subtyping: instantiate `'b <- 'c`
    let foo2: for<'a> fn() -> fn(Option<&'a &'c ()>, &'c T) -> &'a T = foo1;
    // subtyping: contravariantly 'c becomes 'static
    let foo3: for<'a> fn() -> fn(Option<&'a &'static ()>, &'c T) -> &'a T = foo2;
    // subtyping: instantiate `'a <- 'd`
    let foo4: fn() -> fn(Option<&'d &'static ()>, &'c T) -> &'d T = foo3;
    // boom!
    foo4()(None, x)
}
```

So, i implement my fake function pointer type, my own fake `FnOnce` trait(for simplicity, i removed `Output`), and separated the early and late generics parameters and bounds manually. And I use `&dyn FnOnce` to demostrate. The code is something like this:
```rust
use std::marker::PhantomData;

struct Foo<T>(PhantomData<T>);
trait MyFnOnce<Args> {}
impl<'a, 'c, T: 'c> MyFnOnce<(&'a &'c (), &'c T)> for Foo<T> {}

// this compiles
fn good<'c, T: 'c>() {
    let foo2: &dyn for<'a> MyFnOnce<(&'a &'c (), &'c T)> = &Foo::<T>(PhantomData);
}

// this doesn't compile
// fn bad<'c, T: 'c>() {
//    let foo3: &dyn for<'a> MyFnOnce<(&'a &'static (), &'c T)> = &Foo::<T>(PhantomData);
// }
```

The borrow checker can properly detect the invalid cast within `bad` function. So i think this should be just an implementation issue. I'm not very familar with the code, but i doubt the problem lives within this function:

https://github.com/rust-lang/rust/blob/master/compiler/rustc_middle/src/ty/relate.rs#L190-L214 

If it can type check similar to my example above, i think the original code will be rejected as expected.

EDIT: In case there's extra magic with the builtin `FnOnce` trait, here's a version with std `FnOnce`.
```rust
#![feature(fn_traits)]
#![feature(unboxed_closures)]
// nightly only
use std::marker::PhantomData;

struct Foo<T>(PhantomData<T>);

impl<'a, 'c, T: 'c> FnOnce<(&'a &'c (), &'c T)> for Foo<T> {
    type Output = ();
    extern "rust-call" 
    fn call_once(self, _: (&'a &'c (), &'c T)) -> Self::Output { todo!() }
}

// this compiles
fn bad1<'c, T: 'c>() {
    let x: &dyn for<'a> FnOnce(&'a &'c (), &'c T) = &Foo::<T>(PhantomData);
}

// this doesn't
// fn bad2<'c, T: 'c>() {
//    let x: &dyn for<'a> FnOnce(&'a &'static (), &'c T) = &Foo::<T>(PhantomData);
// }
```

And for reference, this is the return type example occurred in lcnr's blog.
```rust
// borrow checker properly handles this too.
// does not compile
// fn my<T: 'static>() {
//    let foo1: &dyn for<'a, 'b> FnOnce(&'a (), &'b T) -> (&'a &'b (), &'a T) = todo!();
//    let foo2: &dyn for<'b> FnOnce(&'static (), &'b T) -> (&'static &'b (), &'static T) = foo1;
//    let foo3: &dyn for<'b> FnOnce(&'static (), &'b T) -> (&'b &'b (), &'static T) = foo2;
//}
```



---
### SkiFire13 2022-02-06T11:08:04Z

> So, i implement my fake function pointer type, my own fake FnOnce trait

> EDIT: In case there's extra magic with the builtin FnOnce trait, here's a version with std FnOnce.

I believe this happens because traits objects are always invariant over their generic arguments. If `MyFnOnce` and `FnOnce` were contravariant over their generic arguments then both these examples would compile, but they don't:

```rust
fn should_compile1<'a, 'f>(f: &'f dyn FnOnce(&'a ())) -> &'f dyn FnOnce(&'static ()) {
    f
}

fn should_compile2<'c, F: for<'a, 'b> FnOnce(&'a &'b ())>(f: F) {
    let x: &dyn for<'a> FnOnce(&'a &'c ()) = &f;
    let y: &dyn for<'a> FnOnce(&'a &'static ()) = x;
}
```


---
### crlf0710 2022-02-07T03:41:47Z

@SkiFire13 You're correct that, dyn values doesn't suffer this issue because it doesn't use **contravariance** here. However it seems to me that my trait objects examples still shows that this issue **can** be solved by removing contravariance, in contradictionary to @lcnr's belief?

PS: Personally I'd love to see more aligning between `fn () -> ()` and `Box<dyn Fn() -> ()>`. I hope the later can act as "stateful callable" in any case, without missing functionality compared to the former...

---
### lcnr 2022-02-07T04:02:04Z

@crlf0710

in my post i have an implementation of `bad` which does not rely on contravariance anywhere, but instead uses covariance in the function return type.
```rust
// we again have an implied `'input: 'out` bound, this time because of the return type
fn foo<'out, 'input, T>(_dummy: &'out (), value: &'input T) -> (&'out &'input (), &'out T) {
    (&&(), value)
}

fn bad<'short, T>(x: &'short T) -> &'static T {
    // instantiate `foo`
    let foo1: for<'out, 'input> fn(&'out (), &'input T) -> (&'out &'input (), &'out T) = foo;

    // instantiate 'out as 'static
    let foo2: for<'input> fn(&'static (), &'input T) -> (&'static &'input (), &'static T) = foo1;

    // function return types are covariant,
    // go from 'static to 'input
    let foo3: for<'input> fn(&'static (), &'input T) -> (&'input &'input (), &'static T) = foo2;

    // instantiate 'input as 'short
    let foo4: fn(&'static (), &'short T) -> (&'short &'short (), &'static T) = foo3;

    // boom!
    foo4(&(), x).1
}
```
While completely removing variance inside of binders would fix this bug, that seems neither desirable nor feasible, considering the resulting breakage and loss of expressiveness.

---
### GuillaumeDIDIER 2022-02-07T14:05:59Z

@lcnr Would the RFC https://github.com/rust-lang/rust/issues/27579 https://github.com/rust-lang/rfcs/blob/master/text/1214-projections-lifetimes-and-wf.md fix the issue ?

---
### SkiFire13 2022-02-07T14:49:14Z

@GuillaumeDIDIER that RFC already mentions this issue (in [this section](https://github.com/rust-lang/rfcs/blob/master/text/1214-projections-lifetimes-and-wf.md#implied-lifetime-bounds)), saying it will be addressed in a separate RFC.

---
### LHolten 2022-02-12T11:36:00Z

To me it looks like function declarations assume all instances of the same lifetime in the signature to be identical.
But when sub-typing functions, you don't have to substitute all instances of a generic lifetime at the same time (thus breaking the assumption).
Meanwhile for functions generic over types (instead of lifetimes), all instances of the type have to be substituted at the same time.
So why not apply the same restriction to substituting generic function lifetimes?

---
### Cassy343 2022-07-06T04:12:12Z

I feel like the issue here isn't fundamental to variance or implied bounds. Let's look at the two more recent examples of this problem.

From @arielb1 
```rs
fn foo<'a, 'b, T>() -> fn(Option<&'a &'b ()>, &'b T) -> &'a T {
    fn foo_inner<'a, 'b, T>(_witness: Option<&'a &'b ()>, v: &'b T) -> &'a T {
        v
    }
    foo_inner
}

fn bad<'c, 'd, T>(x: &'c T) -> &'d T {
    // instantiate `foo`
    let foo1: for<'a, 'b> fn() -> fn(Option<&'a &'b ()>, &'b T) -> &'a T = foo;
    // subtyping: instantiate `'b <- 'c`
    let foo2: for<'a> fn() -> fn(Option<&'a &'c ()>, &'c T) -> &'a T = foo1;
    // subtyping: contravariantly 'c becomes 'static
    let foo3: for<'a> fn() -> fn(Option<&'a &'static ()>, &'c T) -> &'a T = foo2;
    // subtyping: instantiate `'a <- 'd`
    let foo4: fn() -> fn(Option<&'d &'static ()>, &'c T) -> &'d T = foo3;
    // boom!
    foo4()(None, x)
}
```

And from @lcnr 
```rs
// we again have an implied `'input: 'out` bound, this time because of the return type
fn foo<'out, 'input, T>(_dummy: &'out (), value: &'input T) -> (&'out &'input (), &'out T) {
    (&&(), value)
}

fn bad<'short, T>(x: &'short T) -> &'static T {
    // instantiate `foo`
    let foo1: for<'out, 'input> fn(&'out (), &'input T) -> (&'out &'input (), &'out T) = foo;

    // instantiate 'out as 'static
    let foo2: for<'input> fn(&'static (), &'input T) -> (&'static &'input (), &'static T) = foo1;

    // function return types are covariant,
    // go from 'static to 'input
    let foo3: for<'input> fn(&'static (), &'input T) -> (&'input &'input (), &'static T) = foo2;

    // instantiate 'input as 'short
    let foo4: fn(&'static (), &'short T) -> (&'short &'short (), &'static T) = foo3;

    // boom!
    foo4(&(), x).1
}
```

In both examples, the invalid cast is in the transition from `foo2` to `foo3`. The thing that both these examples have in common is that a guarantee given by the implied bound is erased by the cast. In the first example, `foo2` has the bound `'c: 'a`, but the cast erases this bound. This is clearly invalid: the function behind that pointer was allowed to rely on that bound but the caller may no longer respect it. Similarly in the second example, in `foo2` we have `'input: 'static`, but that bound is then erased. It seems like what's needed here is some kind of check for bound erasure when applying sub-typing.

---
### RalfJung 2022-07-06T13:33:15Z

> The thing that both these examples have in common is that a guarantee given by the implied bound is erased by the cast.

Indeed. So implied bounds are clearly fundamental to the problem.
And what's happening here isn't a cast, it's subtyping, hence the relation to variance.

---
### Cassy343 2022-07-06T13:46:30Z

The point I was trying to get across was that it wasn't an insurmountable problem with implied bounds and variance, rather I think it is fixable by incorporating implied bounds into variance in a way. I'm spitballing here because I have no formal experience with this stuff, but is it not possible to add a check along the lines of "T is a subtype of U only if the implied bounds associated with T imply those associated with U." So like with `for<'input> fn(&'static (), &'input T) -> (&'static &'input (), &'static T)` we have "for all `'input`, `'input: 'static`," but for `for<'input> fn(&'static (), &'input T) -> (&'input &'input (), &'static T)`, we just have "for all `'input`, `'input: 'input`," and the latter does not imply the former. Is such a condition not sufficient/not well-defined/not computable?

---
### RalfJung 2022-07-06T14:12:03Z

> The point I was trying to get across was that it wasn't an insurmountable problem with implied bounds and variance, rather I think it is fixable by incorporating implied bounds into variance in a way.

Oh, sure. The question is just how to actually implement that. :)

---
### safinaskar 2023-02-28T01:49:15Z

I think this problem is solvable. We just need to include PTS checker ( https://en.wikipedia.org/wiki/Pure_type_system ) to rustc (or some similar type system). :) This will fix not only this bug, but (I think) many other similar bugs. In very elegant and general way. So, let me explain my idea. I will try to explain clearly, so that everyone will understand. I assume the reader has basic type system knowledge. If not, I suggest reading slides 41-58 of https://www.williamjbowman.com/resources/wjb-defense.pdf .

In the end I will show you why PTS will give us ability to reject that faulty code.

Okay, so I assume you have read the slides, so now I will freely use symbols λ and Π. Now let me actually describe my plan.

I will write λ and Π expressions like so: [Π a : B. C]. Note the dot here between [B] and [C]

- I propose translating Rust code to PTS expressions. I will write in this text Rust code like this: `Vec<T>` and PTS expressions like this: [star->star] (i. e. in square brackets)
- I will call "type" everything which can be type for something. Note that "type" is not necessary Rust type. Also note that `Vec<i32>` is type, but `Vec` is not
- I will call [star] the type of all Rust types, such that values of such Rust types can be passed as argument to a Rust function. For example, `Vec<i32>` is instance of [star] (i. e. `Vec<i32>` has type [star], i. e. [Vec i32 : star]). `Vec` is not instance of [star] (because it is not a type at all). `std::convert::identity` is not instance of [star], because it is generic, and one cannot pass generic functions to functions. But `std::convert::identity::<i32>` is instance of [star]. Also `for<'a> fn(&'a i32)` is instance of [star]. [star] is not instance of [star], because [star] is not Rust type
- [prop] is the type of propositions. Propositions themselves are types ( https://en.wikipedia.org/wiki/Curry%E2%80%93Howard_correspondence )
- [lifetime] is the type of lifetimes
- [outlives] is a predicate, which specifies that one lifetime outlives another. It is written [outlives 'a 'b], this means `'a : 'b` (`'a` outlives `'b`). [outlives] has this type: [outlives : lifetime -> lifetime -> prop]
- [type_outlives] is another predicate. [type_outlives T 'a] means that type [T] outlives lifetime ['a] (`T: 'a`). As we all know, types such as `i32` outlive everything. The only interesting case here is when type contains some embedded references. Type for [type_outlives]: [type_outlives : star -> lifetime -> prop]
- [ref] is constant for creating shared reference types. One may think that to create a reference type you need some type and some lifetime. So it seems one need to use [ref] so: [ref 'a T]. And thus its type seems to be [ref : lifetime -> star -> star]. But I propose different mechanism, and here goes very good part of PTS. `&'a T` has sense only if `T: 'a`. **So we require proof object of `T: 'a` as argument to [ref]. This will mean that this will not be possible to even construct reference type if `T: 'a` is not true!** So I propose this type for [ref]: [ref : Π 'a: lifetime. Π T: star. (type_outlives T 'a -> star)]
- We have constant ['static]. And we have axiom [axstatic], which says that ['static] outlives everything: [axstatic : Π 'a: lifetime. outlives 'static 'a]
- We have unit type [unittype]. Obviously [unittype : star]. And we have unit value itself, [unit]. We have [unit : unittype]. Also, we have axiom [axunit : type_outlives unittype 'static].
- We have axiom about refs: `&'a T : 'a`. This is how it is written in PTS: [axref : Π 'a : lifetime. Π T : star. Π proof : type_outlives T 'a. type_outlives (ref 'a T proof) 'a]
- We have axiom: if `T: 'a` and `'a: 'b`, then `T: 'b`. I. e. [axtrans : Π T : star. Π 'a: lifetime. Π 'b: lifetime. type_outlives T 'a -> outlives 'a 'b -> type_outlives T 'b]
- Also, `'a: 'a`. I. e. [axoutlivesrefl : Π 'a: lifetime. outlives 'a 'a]

Okay, so using all this stuff, we can now write in PTS first line of faulty example:
```rust
static UNIT: &'static &'static () = &&();
```
Here we go: [UNIT : ref 'static (ref 'static unittype axunit) (axref 'static unittype axunit)]

(Well, in fact I specified type of UNIT, not its value. But this is not important.)

Now let's prove some theorems. In PTS theorems are just short abbreviations for complex expressions. :)

The first theorem will simply state that unit type outlives everything. Here is this theorem with its proof:

[unitbig : (Π 'a : lifetime. type_outlives unittype 'a) = (λ 'a : lifetime. axtrans unittype 'static 'a axunit (axstatic 'a))]

Now let's try to write type of `foo`:
```rust
fn foo<'a, 'b, T>(_: &'a &'b (), v: &'b T) -> &'a T { v }
```

[foo: Π 'a : lifetime . Π 'b : lifetime . Π T : star. Π x : ref 'a (ref 'b unittype (unitbig 'b)) (???). Π v : ref 'b T (???). ref 'a T (???)]

Okay, what to write instead of "???"? We cannot write anything, because we have no proof objects for `T: 'b` and for `'b: 'a`.

**So, PTS requires us to pass all proof objects! Our example will not even typecheck, if we did not pass them! PTS will not allow us to make mistakes! So, we have to put implicit `where T: 'b, 'b: 'a` here.** Final code will look so:

[foo: Π 'a : lifetime . Π 'b : lifetime . Π T : star. Π tb: type_outlives T 'b. Π ba: outlives 'b 'a. Π x : ref 'a (ref 'b unittype (unitbig 'b)) (axtrans (ref 'b unittype (unitbig 'b)) 'b 'a (axref 'b unittype (unitbig 'b)) ba). Π v : ref 'b T tb. ref 'a T (axtrans T 'b 'a tb ba)]

Let's abbreviate type of [foo] for particular ['a], ['b], [T], [tb] and [ba] as [footype 'a 'b T tb ba]. I. e. let's introduce this:

[footype 'a 'b T tb ba = Π x : ref 'a (ref 'b unittype (unitbig 'b)) (axtrans (ref 'b unittype (unitbig 'b)) 'b 'a (axref 'b unittype (unitbig 'b)) ba). Π v : ref 'b T tb. ref 'a T (axtrans T 'b 'a tb ba)]

But we wrote _type_ for `foo`. What about its value? Well, let's try:

[foo = λ 'a : lifetime. λ 'b : lifetime. λ T : star. λ tb: (...). λ ba: (...). λ x: (...). λ v: (ref 'b T (...)). v]

Well, I left some "..." in the code, but this is not important. But our code will not typecheck anyway. Because [ref 'a T (...)] and [ref 'b T (...)] are two different types. We need subtyping.

Well, now let's introduce subtyping.

- Our PTS will not have any built-in subtyping. Instead all subtyping will happen explicitly
- As well as I understand it is assumed among Rust devs that lifetimes are types, and thus subtyping applies to lifetimes, too. I disagree. In my formalization lifetimes and types are different things. And subtyping applies to types only
- Okay, so we have constant [subtype]. [subtype T U] means that T is subtype of U. [subtype : star -> star -> prop]
- Every type is subtype of itself: [axsubtyperefl : Π T: star. subtype T T]
- Reference type is covariant in both lifetime and type. I. e. if `'a: 'b` and `T: U`, then `&'a T : &'b U`. I. e. [axrefcovar : Π 'a : lifetime. Π 'b : lifetime. Π T : star. Π U : star. Π proof1 : (...). Π proof2 : (...). outlives 'a 'b -> subtype T U -> subtype (ref 'a T (...)) (ref 'b U (...))] (some parts omitted).
- Functions are covariant in results and contravariant in arguments. I. e. if `R1: R2` and `A2: A1`, then `fn(A1)->R1: fn(A2)->R2`. So, [axfn: Π A1: star. Π A2: star. Π R1: star. Π R2: star. subtype R1 R2 -> subtype A2 A1 -> subtype (A1 -> R1) (A2 -> R2)]
- Okay, we have subtyping. But what we can actually do with it? Well, if `T: U`, then we can actually convert T to U! So, we have constant function [conv : Π T: star. Π U: star. subtype T U -> T -> U]

Now we can write value of function `foo`:

[foo = λ 'a : lifetime. λ 'b : lifetime. λ T : star. λ tb: (...). λ ba: (...). λ x: (...). λ v: (ref 'b T (...)). conv (ref 'b T (...)) (ref 'a T (...)) (...) v]

Again, I omitted something, but you can fill missing pieces. **It is important to know: if we made even single mistake, this will not typecheck! Variance, subtyping - all this is checked!**

Let's go to the next line!
```rust
fn bad<'a, T>(x: &'a T) -> &'static T {
```

This line gives us type for [bad] (I will omit it) and introduces for us the following context:
- ['a : lifetime]
- [T : star]
- [proof : type_outlives T 'a]
- [proof2 : type_outlives T 'static]
- [x : ref 'a T proof]

Now, next line:

```rust
let f: fn(_, &'a T) -> &'static T = foo;
```

So:
[f : (V1 -> ref 'a T proof -> ref 'static T proof2) = conv (footype V2 V3 V4 V5 V6) (V1 -> ref 'a T proof -> ref 'static T proof2) V7 (foo V2 V3 V4 V5 V6)]

(The line above was edited 28 Feb 13:00 UTC, original line was wrong.)

And now our rustc got really hard problem: it should fill something instead of V1, V2, V3, V4, V5, V6, V7. And do you know that? It will unable to do this no matter how hard it will try. Because this task simply has no solution. **So, this code will not typecheck, exactly as we need!**

Okay, so this bug (25860) is fixed. #106431 seems to be fixed now, too. (Well, I didn't read #106431 in full, but it begins with words "Rust currently correctly implies a `'inner: 'outer` bound when you have `&'outer &'inner _`. It is also incorrectly implying this for `&'outer fn(&'inner _)`". It is exactly kind of problem I solved.)

I think my solution can be easily extended to https://github.com/rust-lang/rust/issues/80176#issuecomment-748466836 and many other bugs mentioned in this thread.

Also, my solution proves that there is nothing wrong with contravariance.

Of course, I simplified everything. Actual pure type system is harder. See Barendregt, "Lambda calculi with types" ( http://hdl.handle.net/2066/17231 ) for actual definition of pure type system. PTS requires specifying so-called specification. Well, I don't want to provide one, I'm too lazy.

But if you want, I can think hard and provide specialization (well, I'm nearly sure I can provide one if I try). And I can fill other remaining pieces and even check my formulas in some PTS checker or prover. So, just write here "hey! provide specification. Fill missing parts! Actually proof in some prover" and I will do this.

I hope this post will inspire someone to dig to beautiful world of type systems. Ping @lcnr .

This post is answer to this: https://github.com/rust-lang/rust/issues/25860#issuecomment-1176273089 , i. e. "The question is just how to actually implement that". And to "less afraid now" from here: https://github.com/rust-lang/rust/issues/25860#issuecomment-283955348 . If we build everything on top of generic PTS, everything will be magically solved!

---
### noamtashma 2023-03-04T14:00:07Z

@safinaskar Let me check if I understand you correctly. To me it reads like:
1. Make IR explicitly state lifetime requirements and such, as part of the type. (similar to [this comment you indirectly referenced](https://github.com/rust-lang/rust/issues/25860#issuecomment-174011431)).
2. Stop variance from being a built-in, automatic part of IR, and instead desugar implicit subtyping in surface rust into explicit applications of "variance rules".
3. Check that with pure typesystem checker, that will hopefully be smaller and sound and simple. Bugs that are similar to this would supposedly fail here, because the desugaring step would produce untypable IR.

Correct?



---
### noamtashma 2023-03-04T14:06:31Z

Can anyone clear up why [niko's approach](https://github.com/rust-lang/rust/issues/25860#issuecomment-174011431) wasn't implemented?
Does it not work from a theoretical point of view? Or practically? Or it has actually been implemented, but didn't solve the issue?
Or just nobody got around to doing it?

---
### safinaskar 2023-03-04T15:27:34Z

> Correct?

@noamtashma, Yes

---
### lcnr 2023-03-06T10:46:37Z

the comment by @safinaskar is afaict pretty much the approach suggested by niko in https://github.com/rust-lang/rust/issues/25860#issuecomment-174011431 except that it also lowers our trait system to proof objects.

rustc currently does not do that. We prove trait bounds during type checking, forget that information (except for trait solver caching), and then reprove these same bounds during codegen.

While I would love to lower rusts trait system to a far simpler language at some point and verify both borrowck and trait solving in that simpler language, this is not what's currently done. Rustc uses pretty much the same trait system until we hand off the work to llvm. This is different from what's done by haskell afaik, where its very complex type system gets mapped to an intermediate type system which is far simpler.

The issue is that currently Rust is in no state to do anything like this. Similarly, the reason why niko's approach is not yet implemented is simply that getting the type system to a point where we even can implement this is Hard. Fixing this bug is blocked on replacing the existing trait solver(s): #107374. A clean fix for this issue (and the ability to even consider using proof objects), will then also be blocked blocked on coinductive trait goals and explicit well formed bounds. We should then be able to add implications to the trait solver.

So I guess the status is that we're slowly getting there but it is very hard, especially as we have to be incredibly careful to not break backwards compatibility.





---
### John-Nagle 2023-06-06T16:14:58Z

Publicized as a language design flaw at https://counterexamples.org/nearly-universal.html?highlight=Rust#nearly-universal-quantification

---
### ast-ral 2023-08-16T05:59:20Z

This code I've found also seems to exhibit a similar problem (on version 1.71.1):
```rust
use std::marker::PhantomData;

struct Bounded<'a, 'b: 'a, T>(&'a T, PhantomData<&'b ()>);

fn helper<'a, 'b, T>(
    input: &'a T,
    closure: impl FnOnce(&T) -> Bounded<'b, '_, T>,
) -> &'b T {
    closure(input).0
}

fn extend<'a, 'b, T>(input: &'a T) -> &'b T {
    helper(input, |x| Bounded(x, PhantomData))
}
```
I'm hesitant to file this as its own issue because I don't think it's different enough to justify doing so.

---
### Neutron3529 2023-12-11T14:29:13Z

> This code I've found also seems to exhibit a similar problem (on version 1.71.1):
> 
> ```rust
> use std::marker::PhantomData;
> 
> struct Bounded<'a, 'b: 'a, T>(&'a T, PhantomData<&'b ()>);
> 
> fn helper<'a, 'b, T>(
>     input: &'a T,
>     closure: impl FnOnce(&T) -> Bounded<'b, '_, T>,
> ) -> &'b T {
>     closure(input).0
> }
> 
> fn extend<'a, 'b, T>(input: &'a T) -> &'b T {
>     helper(input, |x| Bounded(x, PhantomData))
> }
> ```
> 
> I'm hesitant to file this as its own issue because I don't think it's different enough to justify doing so.

I tried to simplify your code, got:
```rust
fn extend<'a, T>(input: &'a T) -> &'static T {
    struct Bounded<'a, 'b: 'static, T>(&'a T, [&'b ();0]);
    let n:Box<dyn FnOnce(&T) -> Bounded<'static, '_, T>>=Box::new(|x| Bounded(x, []));
    n(input).0
}
fn extend_mut<'a, T>(input: &'a mut T) -> &'static mut T {
    struct Bounded<'a, 'b: 'static, T>(&'a mut T, [&'b ();0]);
    let mut n:Box<dyn FnMut(&mut T) -> Bounded<'static, '_, T>>=Box::new(|x| Bounded(x, []));
    n(input).0
}
```
deleting the `'b` would generate an compile error, but adding it is fine. I means, this code
```rust
fn extend<T>(input: &T) -> &'static T {
    struct Bounded<'a, T>(&'a T, [&'static ();0]);
    let n:Box<dyn FnOnce(&T) -> Bounded<'static, T>>=Box::new(|x| Bounded(x, []));
    n(input).0
}
```
yields
```
error: lifetime may not live long enough
 --> test2.rs:3:67
  |
3 |     let n:Box<dyn FnOnce(&T) -> Bounded<'static, T>>=Box::new(|x| Bounded(x, []));
  |                                                                -- ^^^^^^^^^^^^^^ returning this value requires that `'1` must outlive `'2`
  |                                                                ||
  |                                                                |return type of closure is Bounded<'2, T>
  |                                                                has type `&'1 T`

error: aborting due to previous error
```
It seems the restriction is inverted here, we need `'a:'b` to execute instructions like `&'a T as &'b T`, but we wrote `'b outlives 'a` (actually here I wrote `'b outlives 'static`)

---

What's more, the original implementation does not need an extra lifetime `'b` since we could obtain `'b` from `'static` directly.
```rust
pub fn make_static<'a, T>(input: &'a T) -> &'static T {
    fn helper<'a, T>(_: [&'static&'a();0], v: &'a T) -> &'static T { v }
    let f: fn([&'static&();0], &T) -> &'static T = helper;
    f([], input) // we need not to create a &'a&'b unit directly.
}
pub fn make_static_mut<'a, T>(input: &'a mut T) -> &'static mut T {
    fn helper_mut<'a, T>(_: [&'static&'a();0], v: &'a mut T) -> &'static mut T { v }
    let f: fn([&'static&'static();0], &'a mut T) -> &'static mut T = helper_mut;
    // let f: fn([&'static&();0], &mut T) -> &'static mut T = helper_mut; // it also works
    f([], input)
}
```

---
### Jules-Bertholet 2023-12-12T14:23:51Z

> ```rust
> fn extend<'a, T>(input: &'a T) -> &'static T {
>     struct Bounded<'a, 'b: 'static, T>(&'a T, [&'b ();0]);
>     let n:Box<dyn FnOnce(&T) -> Bounded<'static, '_, T>>=Box::new(|x| Bounded(x, []));
>     n(input).0
> }
> fn extend_mut<'a, T>(input: &'a mut T) -> &'static mut T {
>     struct Bounded<'a, 'b: 'static, T>(&'a mut T, [&'b ();0]);
>     let mut n:Box<dyn FnMut(&mut T) -> Bounded<'static, '_, T>>=Box::new(|x| Bounded(x, []));
>     n(input).0
> }
> ```

This is a new regression from 1.64 to 1.65: https://rust.godbolt.org/z/jGxrcrjTj

---
### bstrie 2024-02-20T12:50:02Z

@lcnr Github seems to think that #118247 will close this issue due to how your comment here is worded: https://github.com/rust-lang/rust/pull/118247#issuecomment-1883158719 . Can that be fixed?

---
### slanterns 2024-02-20T13:14:09Z

> * e.g. we intend to consider higher ranked implied bounds when subtyping to fix [Implied bounds on nested references + variance = soundness hole #25860](https://github.com/rust-lang/rust/issues/25860), I don't know how this will interact and don't feel confident making any prediction here.

#118247 is not directly related to this issue. It's Github's misunderstanding.

---
### Richardn2002 2024-02-20T16:42:58Z

A recent joke [repo](https://github.com/Speykious/cve-rs) exploiting this bug, segfaulting and buffer-overflowing in safe Rust.

---
### alexpyattaev 2024-02-20T18:58:14Z

This is not just a joke but also a nice example for malicious actors to sneak UB into "safe" crates. 

---
### nyabinary 2024-02-20T22:46:19Z

Yeah, this should probably be a priority to fix, lol. 

---
### lcnr 2024-02-20T23:09:47Z

we already had a crate published on crates.io before which used this bug to transmute in safe code, see https://github.com/rust-lang/rust/issues/25860#issuecomment-515747670.

this issue is a priority to fix for the types team and has been so for years now. there is a reason for why it is not yet fixed. fixing it relies on where-bounds on binders which are blocked on the next-generation trait solver. we are actively working on this and cannot fix the unsoundness before it's done.


---
### oli-obk 2024-02-21T07:32:21Z

I am locking this thread, since its 100+ comments have become impossible to navigate. Please open threads on zulip if you want to discuss this issue or related bugs
