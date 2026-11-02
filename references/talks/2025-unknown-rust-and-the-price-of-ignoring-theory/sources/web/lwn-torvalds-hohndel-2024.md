---
title: LWN: Linus and Dirk show, Open Source Summit Europe 2024
source: https://lwn.net/Articles/990534/
retrieved: 2026-11-02
---

> **Ready to give LWN a try?**
>
> With a subscription to LWN, you can stay current with what is happening in the Linux and free-software community and take advantage of subscriber-only site features. We are pleased to offer you **[a free trial subscription](https://lwn.net/Promo/nst-trial1/claim)**, no credit card required, so that you can see for yourself. Please, join us!

By **Jake Edge**  
September 25, 2024

------------------------------------------------------------------------

[OSSEU](/Archives/ConferenceByYear/#2024-Open_Source_Summit_Europe)

The "Linus and Dirk show" has been a fixture at Open Source Summit for as long as the conference has existed; it started back when the conference was called LinuxCon. Since Linus Torvalds famously does not like to give talks, as he said during this year's edition at [Open Source Summit Europe](https://events.linuxfoundation.org/open-source-summit-europe/) (OSSEU) in Vienna, Austria, he and Dirk Hohndel have been sitting down for an informal chat on a wide range of topics as a keynote session. That way, Torvalds does not need to prepare, but also does not know what topics will be brought up, which makes it "so much more fun for one of us", Hohndel said with a grin. The topics this time ranged from the just-released 6.11 kernel and the upcoming Linux 6.12, through Rust for the kernel, to the recurring topic of succession and the graying of Linux maintainers.

After Torvalds suggested that they had been doing these talks for 20 years, though Hohndel pointed out that the tradition began in 2012, the conversation turned to the weather—a common topic after the surprisingly horrible weather in much of Europe due to [Storm Boris](https://edition.cnn.com/2024/09/16/weather/storm-boris-floods-europe-intl/index.html). In a massive understatement, Hohndel said that it had been a "wee bit windy" the day before, which he and Torvalds had hoped to use as a sightseeing day, but the day before the conference started (September 15) was not a day to stray far from your hotel. It did give Torvalds plenty of time to do the [6.11 kernel release](/Articles/990307/), which they discussed next.

#### 6.11 and 6.12

[![\[Dirk Hohndel\]](https://static.lwn.net/images/2024/osseu-hohndel-sm.png "Dirk Hohndel")](/Articles/991536/)

Hohndel asked what was interesting in 6.11, but Torvalds replied that, like most every other kernel release over the last 15 years so, it was not particularly exciting, which is exactly how it is supposed to be. The release signals the opening of the two-week merge window, of course, which Torvalds chose to start while he was on the road for OSSEU (as well as the [Maintainers Summit](/Articles/990740/) and [Linux Plumbers Conference](https://lpc.events/)). The merge window is where "we're getting all the new code for the next release and that's the fun part" for him. Hohndel noted that Torvalds had been pulling patches on his laptop backstage while they were waiting for the session, "so it is just-in-time delivery of the Linux kernel".

Hohndel said that the bulk of what is being pulled these days seems to be drivers of various sorts, which Torvalds agreed is the case. More than half of the kernel is drivers, which has generally been true over the years, because that is "literally the point of a kernel" since it is meant to "abstract out all the hardware details". So, much of the code flowing in is meant to enable new hardware or to fix the hardware support already in the kernel.

For Torvalds, the surprise is that, after working on Linux for a third of a century now, there are still plenty of changes to the core kernel that are being made. Half of what he merged that day were low-level changes to the virtual filesystem (VFS) layer and there have been lots of discussions lately in the area of memory management. Those core changes are ultimately being driven by expansion in the hardware base, but also by new users, with new ways to use the kernel.

The [extensible scheduler class](/Articles/922405/) (sched_ext), which allows scheduling decisions to be made by BPF programs, will be coming in 6.12, he said, in answer to a question from Hohndel. Torvalds had not yet merged it, but it was in his queue (and was [merged](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=88264981f208) later in the week). Some of the core kernel maintainers are at the conferences this week, so he got a lot of early pull requests the previous week, because they did not want to deal with them during their travel. "I'm stuck with that part", he said to laughter.

The conclusion of the 20-year project to get the realtime patches upstream was another thing that would be part of the next kernel, Torvalds confirmed. (In fact, he [pulled](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=baeb9a7d8b60) the enablement patches on September 20, the day after [receiving them in a rather different form](/Articles/990985/).) People think that kernel development is rapid because of the pace of releases, but any given feature "may have been developed over months or years or, in some cases, decades". That development happens in the open on the mailing lists, but people typically do not see the background work that goes into a new feature that seems to just appear in the kernel. But, he agreed, the realtime patches are an outlier in terms of development time, in part because they "touched every single area in the kernel", so there is a lot of convincing and coordination that needed to be done; he knows of no other similar project out there.

#### Rust

Hohndel said that one of the topics that has been generating a lot of discussion in the community recently is "obviously Rust". He noted that one of the Rust-for-Linux maintainers [stepped down](/Articles/987635/) citing "'non-technical nonsense' as the reason"; beyond that, there have been [problems](/Articles/988438/) getting the Apple graphics driver written in Rust merged. He asked: "why is this so hard?"

[![\[Linus Torvalds\]](https://static.lwn.net/images/2024/osseu-torvalds-sm.png "Linus Torvalds")](/Articles/991537/)

"I actually enjoy it, I enjoy arguments", Torvalds said; one of the nice things about the Rust effort is that it "has livened up some of the discussions". Some of those arguments "get nasty" and people do "decide that this is not worth my time", but it is interesting and "kind of shows how much people care". He is not sure why Rust, in particular, has been so contentious, however.

The whole "Rust versus C discussion is taking almost religious overtones" that remind him of the vi versus Emacs fights from when he was young, which, Hohndel reminded, still go on. "C is, in the end, a very simple language", Torvalds said, which is why he and lots of other programmers enjoy it. The other side of that, though, is that it is also easy to make mistakes in C. Rust is quite different and there are those who do not like that difference; "that's OK".

There is no one who understands the entire kernel, he said; he relies heavily on the maintainers of various subsystems, since there are only a few areas that he gets personally involved in. There are C people who do not know Rust and the reverse is true as well, which is also fine. One of the nice things about the kernel is that people can specialize: some people care about drivers, others about specific architectures, or still others who like filesystems. "And that's how it should be."

There are, obviously, some people who do not like "the notion of Rust and having Rust encroach on their area". He finds it all interesting, however. People have "even talked about the Rust integration being a failure", which is way too early to determine. Even if that happens, "and I don't think it will, that's how you learn". He sees the Rust effort as a "positive, even if the arguments are not necessarily always".

Torvalds noted that kernel C is "not normal C"; there are a lot of rules on how the code can be written and there are tools to help detect when things go awry. There is memory-safety infrastructure within the kernel project that is not part of the C language, but it has been built up incrementally over the years, which allowed it to avoid any major outcry. The "Rust change is, obviously, a much bigger and a much more in-your-face" thing.

Hohndel agreed that it was too early to say that Rust in the kernel was a failure, but that he had been hearing about efforts to build a Rust kernel from the bottom up as an alternative. He wondered if that was a potential outcome if there continues to be a struggle to get Rust into Linux; "an alternative universe" could perhaps arise from [Redox](/Articles/979524/), [Maestro](https://github.com/maestro-os/maestro), or some other Rust kernel. In terms of languages for building a kernel, Torvalds said, there is not a lot of choice; unless you are going to write in assembly, you have to choose one of the C-like languages—or Rust. Linux is not everywhere, these days, in part because it has gotten "very big" over the last three decades; some developers are looking for something smaller, safer, and "not quite as fully-fledged", which is an area where Rust kernels could perhaps make an impact.

Hohndel disagreed somewhat with that, though he did agree that there are "deeply embedded" use cases where Linux is not used; but for general-purpose systems, "it is everywhere". He noted that most 5G modem chips have a complete Linux distribution running inside; "in your iPhone is a chip that runs, as its firmware, Linux". Torvalds reminded attendees of the old "joke" about "world domination", but "that joke became reality and isn't funny any more", he said to laughter.

Torvalds seemed optimistic that "some clueless young person will decide 'how hard can it be?'" and start their own operating system in Rust or some other language. If they keep at it "for many, many decades", they may get somewhere; "I am looking forward to seeing that". Hohndel clarified that by "clueless", Torvalds was referring to his younger self; "Oh, absolutely, yeah, you have to be all kinds of stupid to say 'I can do this'", he said to more laughter. He could not have done it without the "literally tens of thousands of other people"; the "only reason I ever started was that I didn't know how hard it would be, but that's what makes it fun".

#### Gray hair and burnout

The [kernel Maintainers Summit](/Articles/990740/) was being held the next day, Hohndel said, and he expected the topic of burnout to come up. Maintainers are "an aging group", many with less or not "the right color of hair"—though Torvalds interjected: "gray is the right color". Meanwhile, kernel development is showing no signs of slowing down, Hohndel said; in fact, it is "accelerating in many ways, Rust being one of them". He wonders, as maintainers get older and burnout becomes more widespread, if there is a need to talk about "mini-Linus" who would be a successor.

"We have been talking about that forever", Torvalds replied, "some people are probably still disappointed that I'm still here". While it is definitely true that kernel maintainers are aging, the positive spin on that is that he does not know of many projects where maintainers—and not just him—have stuck around for more than three decades. The idea that people "burn out and go away" is true, but that is the norm for most projects; the fact that some stick around on the kernel project for decades is unusual, "and I think that's, to some degree, a good sign".

On the other hand, new developers may look at the project and not really see a place for themselves when they see people who have been with the project for a long time, he said. The kernel project is unlike other open-source projects, since the number of developers just seems to grow; there is a "fairly healthy developer subsystem" in the kernel. "The whole '[monkey dance](https://knowyourmeme.com/memes/steve-ballmer-monkey-dance)' about 'developers, developers, developers'—we've got them"; he does not see the presence of some graying developers as a "huge problem".

Hohndel said that he was not claiming that the older maintainers were a problem, per se, just that it indicates things will have to change down the road. Torvalds has been doing Linux for 33 years, but Hohndel suggested that in another 33, he would not be—"possibly" was the reply. The current backup is Greg Kroah-Hartman, "who has even less hair than the two of us" and is around the same age as they are, Hohndel said. "How do we get the next generation to gain the experience" needed so that they can take over Torvalds's role in "10, 15, 20, 30 years", he wondered.

Since the kernel project has so many developers, it has always had a lot of competent people that could step up if needed, Torvalds said. Hohndel had mentioned Kroah-Hartman, but he has not always been the backup, Torvalds said. "Before Greg, there were Andrews \[Morton\] and Alans \[Cox\], and after Greg there will be Shannons and Steves, who knows?" It comes down to a matter of trust, he said; there will need to be a person or group of people that the community can trust.

Part of being trusted is having been around for "long enough that people know how you work", but that does not have to be 30 years. There are top-level maintainers for major subsystems who got there in just a few years, he said. In truth, being a maintainer is "not as glorious as it is sometimes conceived"; there are maintainers "who would be more than happy to get new people in to come and help".

#### Starting out

When they got their start in open source, that world was a smaller and simpler place, Hohndel said; these days, everything is "hype versus reality", and he was "not just talking about AI", with projects focused on making "the quick buck, about the quick exit, versus things that are making a difference". If Torvalds were starting today, did he think it "would be easy to find interesting, rewarding, long-term useful projects"?

Torvalds replied: "I don't think that has ever been easy". But setting up an open-source project is much easier these days; "do a few web clicks and you have a GitHub repository where you can start doing open source". In addition, you do not have to "explain why you are doing open source, because people take that for granted now". That means there are a lot of small projects out there "that you would never have seen 30 years ago".

That said, "it was never easy to find something meaningful that you could spend decades doing", which is still true today. You have to come up with an idea that you are interested in, Torvalds said, "but at the same time, you are not the only one interested in it". People often say "do what you love", but if that is "something that nobody else cares about, you are not going to create the next big, successful open-source project".

Finding something meaningful is particularly hard in the tech industry, where there is so much hype. "Everybody is following everybody else like lemmings off a cliff trying to chase the next big thing." Torvalds does not think that is a successful strategy; instead, "find something that isn't what everybody else does and excel at that". Hohndel interjected that they were out of time; he had hoped to end with something inspirational along the lines of "Linus telling the community where to go and make a difference", but, what he got was lemmings falling off a cliff, he said with a chuckle. That way, though, the session itself ended with laughter.

\[ I would like to thank LWN's travel sponsor, the Linux Foundation, for travel assistance to Vienna for Open Source Summit Europe. \]

  

[TABLE]

  

------------------------------------------------------------------------

to post comments

### surprisingly horrible weather in much of Europe due to Storm Boris.

Posted Sep 25, 2024 14:07 UTC (Wed) by **Wol** (subscriber, \#4433) \[[Link](/Articles/991705/)\]

Trust our ex Prime Minister to cause trouble :-)  

Cheers,  
Wol  

### C is not as simple as it seems

Posted Sep 25, 2024 20:11 UTC (Wed) by **roc** (subscriber, \#30627) \[[Link](/Articles/991737/)\] (36 responses)

Linus says "C is a very simple language" but then goes on to say "there are a lot of rules on how the code can be written and there are tools to help detect when things go awry".... which tells a story. When you first write some programs which produce correct output, you think C is simple. Then you gradually learn the rules and get better at applying them, until it's not really simple at all, but you still think it's simple from your first impression. In the meantime, you have unfortunately written a lot of garbage C code.  

People learning C should have their programs subjected to sanitizers and fuzz testing from their very first program. Then they'll get an accurate impression of how simple C is.  

### C is not as simple as it seems

Posted Sep 25, 2024 21:09 UTC (Wed) by **Sesse** (subscriber, \#53779) \[[Link](/Articles/991741/)\] (35 responses)

C is a simple language (though all the rules around integers get me every time), but it is not simple to program in C. At least not if you want a bug-free program. :-)  

### C is not as simple as it seems

Posted Sep 25, 2024 22:10 UTC (Wed) by **andy_shev** (subscriber, \#75870) \[[Link](/Articles/991745/)\]

Exactly! Many things and rules are dictated by the hardware. But in principle a good software engineer (developer) has to know how hardware works (at least on the levels of understanding cache colouring and posted or combined IO writes, as an example).  

### C is not as simple as it seems

Posted Sep 25, 2024 23:38 UTC (Wed) by **NYKevin** (subscriber, \#129325) \[[Link](/Articles/991743/)\] (33 responses)

C is simple if you learn it wrong. For example, if you are told that pointers are integers representing the (arbitrary) memory address of a variable, then you will think that pointers are "simple." But pointers are not, on the abstract machine, integers referencing memory addresses. Rather, a pointer is an opaque handle given out by the abstract machine which may only be manipulated in very specific ways, or else it's UB. In particular:  

\* You cannot compare pointers for inequality (\<, \<=, etc.) unless they both point within the same array or struct. Under a careful read of the standard's precise wording, it \*appears\* to me that it is even UB if we have an array of structs, one of the pointers points to a field of one of those structs, and the other pointer points to a field of a different struct in the same array (the standard specifies comparisons involving two "structure members" and comparisons involving two "array elements," but does not appear to contemplate a mixture of the two). For example, if we know that foo is a struct with a field called bar, and x and y point to elements of some array of struct foo, then the compiler may optimize &(x-\>bar) \<= &(y-\>bar) to 1 without regard for the values of x and y (if they both point to the same struct foo, then the expression is true, and if not, then it's UB). Note that this rule does not apply to == and !=, which are required to work correctly in this case. Of course any right-thinking person writes x \<= y instead, but this is a toy example. You may hypothesize that the compiler does some level of constant propagation, inlining, and other code movement to get to this case.  
\* You cannot perform arbitrary arithmetic on pointers - you may only construct other pointers within or one past the end of the same array (but, for the purpose of this rule, an object which is not in any array is considered to belong to a one-element array). Any other arithmetic is UB, regardless of whether you dereference the pointer.  
\* Subtracting two pointers produces a result of type ptrdiff_t, if the subtraction is legal, but ptrdiff_t is not required to be wide enough to hold all possible pointer subtractions. It can overflow, and that is UB.  
\* Type punning through a pointer cast is generally UB, even in cases where the object representation is necessarily valid, unless the types are "compatible" or one of them is some variation of char\*. But at least in this case, you don't get UB until you actually dereference the pointer... unless the resulting pointer violates the alignment requirements of the target type, which is immediate UB.  
\* Function pointers are not required to have the same representation as object pointers. Unlike object pointers, the implementation is not required to let you inspect the byte representation of a function through a char\* cast (or indeed any other object pointer cast), and functions are not even required to live in the same address space as objects.  
\* Null pointers are initialized with a literal zero or with the NULL macro (that is defined as either a literal zero, or a literal zero cast to void\*), but are not required to have an all-bits-zero representation or to type cast into an integer zero.  
\* You can cast pointers to integers. Overflow is UB even if the target type is unsigned and you do nothing more with that integer.  
\* You can cast integers to pointers. Doing so may produce a trap representation, so the only safe way to do this is to start with a pointer and round-trip it through an integer.  
\* As of C23, you can safely cast a pointer to (u)intptr_t, if the implementation provides it. In practice, you can usually get away with using size_t, but formally the standard does not require them to be wide enough.  
\* Pointer arithmetic is not required to distribute over conversion to integer. If x has type char\* and points to a valid object (not one-past-the-end), then (uinptr_t)(x + 1) is not required to equal ((uintptr_t)x) + 1 (but you're going to have a hard time finding an implementation which makes them unequal!).  

### C is not as simple as it seems

Posted Sep 26, 2024 6:51 UTC (Thu) by **LtWorf** (subscriber, \#124958) \[[Link](/Articles/991770/)\] (4 responses)

What would be the use case for pointer arithmetic between things that are in 2 different memory allocations?  

### Look up a pointer to get associated tag.

Posted Sep 26, 2024 7:55 UTC (Thu) by **gmatht** (guest, \#58961) \[[Link](/Articles/991779/)\]

If you have a pointer to some fixed data structure that you can't (or shouldn't) modify, you may want to attach a tag to a pointer and then look up that tag in a binary tree. For example, imagine you have a hashing algorithm for some very large const strings that will not be deallocated. Internal to the hashing algorithm, you may wish to look up the nice short pointer/integer in a binary tree to find a cached hash. In this case, the order on the pointers doesn't really matter so long as there is a well-defined order.  

### C is not as simple as it seems

Posted Sep 26, 2024 19:58 UTC (Thu) by **NYKevin** (subscriber, \#129325) \[[Link](/Articles/991921/)\]

I'm not saying all (or even most) of these things have actual use cases. I'm just saying that pointers have a lot of complicated rules that are often not taught correctly or at all. Students are told that pointers are integers, and they are not.  

### C is not as simple as it seems

Posted Sep 26, 2024 20:22 UTC (Thu) by **intelfx** (subscriber, \#130118) \[[Link](/Articles/991923/)\] (1 responses)

\> What would be the use case for pointer arithmetic between things that are in 2 different memory allocations?  

Memmove between overlapping regions?  

### C is not as simple as it seems

Posted Sep 26, 2024 20:23 UTC (Thu) by **intelfx** (subscriber, \#130118) \[[Link](/Articles/991924/)\]

Correction, \_potentially\_ overlapping regions.  

### C is not as simple as it seems

Posted Sep 26, 2024 9:32 UTC (Thu) by **joib** (subscriber, \#8541) \[[Link](/Articles/991814/)\] (24 responses)

Zero chance of this ever happening, but occasionally I think the ISO C committee should just give up on the idea of a somewhat high level abstract machine. Just say that memory is a big array, and pointers really are just integers. Get rid of TBAA. Etc. In essence, make C be the "portable macro-assembler" that many people stubbornly believe it is.  

Just look at how convoluted it gets when they try to retrofit something like pointer provenance.  

Of course for architectures with segmented memory, Harvard architectures, etc. you might have several of these big arrays representing the system memory, there you need some implementation-defined logic how comparing pointers to different segments would work. If you want a language with a more abstract view of the machine, choose another language designed with that in mind from the beginning. Like Rust?  

### C is not as simple as it seems

Posted Sep 26, 2024 10:36 UTC (Thu) by **smurf** (subscriber, \#17840) \[[Link](/Articles/991821/)\] (1 responses)

On a Harvard architecture system (like embedded 8-bit Atmel CPUs) plain C doesn't know \*anything\* about which part of the architecture your pointer refers to. It's just a value in a register. Literally everything you do with pointers that refer to the "wrong" address space (e.g. read-only strings stored in Flash) requires compiler-specific extensions, macros, and/or special functions.  

Fortunately GCC has some extensions that warn you if you use the wrong kind of pointer, but for any new project on these things I'd use Rust instead.  

### C is not as simple as it seems

Posted Sep 26, 2024 20:38 UTC (Thu) by **Cyberax** (**✭ supporter ✭**, \#52523) \[[Link](/Articles/991928/)\]

Technically, pointers can have attributes in C. Like the bad old FAR and NEAR pointers in x86-16.  

### C can't do provenance

Posted Sep 26, 2024 22:47 UTC (Thu) by **NYKevin** (subscriber, \#129325) \[[Link](/Articles/991926/)\] (21 responses)

\> Just look at how convoluted it gets when they try to retrofit something like pointer provenance.  

After spending way too much time thinking about this, and a fair amount of time scrutinizing the draft standard, I do not believe provenance is feasible in C23. For a start, if you wanted to make a C implementation with full provenance, you would have to do at least the following:  

\* Make == compare pointers for provenance, which either requires hardware support (e.g. on CHERI or the like) or fat pointers with runtime allocator support (i.e. the allocator has to give every allocation a unique ID which is not reused on free and "never" overflows). This is necessary because the standard says that, if malloc does not fail, then the following code may not be UB on any code path (and the assert may not fire): int \*x = malloc(sizeof(int)); free(x); int \*y = malloc(sizeof(int)); if(x == y){ \*x = 2; assert(\*y == 2);}. The standard also says that == is transitive and so if we already knew that x == z, then you can dereference z instead of x, which effectively means that we can't give == a secret side effect that somehow propagates provenance from y to x (because z still would not have provenance).  
\* Do not provide (u)intptr_t at all, and document that your pointers cannot be represented by any integral type (not even size_t or intmax_t). This makes all pointer-to-integer casts UB, which is necessary because the standard specifies that once such a cast has legally happened, the rest of the round-trip must produce a pointer that compares equal to the original (and therefore, as we just saw, it can be used to access the same allocation, effectively removing provenance altogether since you can reconstitute a pointer from non-pointer data). If you're feeling generous, you can emit an error on such casts (let's not get into the language-lawyering about whether or not you have to prove that all code paths reach the cast before you can refuse to compile it).  

But that's not good enough. A pointer is an object, and like any object, you may inspect the pointer's object representation through a char\*. The standard also specifies that objects other than float NaNs must compare equal if their object representations are identical. So the enterprising programmer is allowed to convert a pointer into raw bytes and then reconstitute the pointer elsewhere from those bytes, and since the pointer is required to compare equal to the original, it also must be possible to dereference it and access the same object. You can even do something really crazy, like writing the object representation into some arbitrarily-complicated IPC mechanism, and then having another part of your program retrieve it. CHERI is obviously not going to support that, even if it could somehow track simple byte copies around your local address space.  

I can only think of one loophole that might be used to prohibit this, but it's a real stretch: You could declare that pointers produced in this manner are trap representations, and thus UB to create. The problem with that is that the standard explicitly specifies that trap representations are not valid object representations, so the programmer is within their rights to assume that a representation they got from a valid pointer (or any other properly initialized object) is not a trap representation. There does not appear to be any wiggle room in the standard for the same object representation sometimes being valid and sometimes being a trap, and I think it would be an absurd reading of the standard to allow such a thing.  

This could be fixed by amending the standard, most likely by stealing C++'s notion of a "trivially copyable type" and stating that pointers are trivially copyable unless the implementation specifies otherwise (and all other types are always trivially copyable, with the usual float NaN caveat). Of course, pointers are trivially copyable even in C++, so you'd presumably want to amend that standard as well, if you want provenance to exist in C++.  

### C can't do provenance

Posted Sep 27, 2024 3:34 UTC (Fri) by **SLi** (subscriber, \#53131) \[[Link](/Articles/991934/)\] (9 responses)

Fixed? But I don't think we have sane pointer provenance in C++ either, although it's in a better shape than C?  

This, I believe, is the problem. There are the classical two kinds of people:  

1\. Those who treat C as a high level assembler  
2. The abstract machine types.  

Most of the (1) do not realize how little performance there will be left without alias analysis, which cannot be done without pointer provenance.  

Many or most of (2) probably don't realize pointer provenance likely cannot be done in C or C++ as they exist.  

What compilers end up doing is assuming that we can do pointer provenance anyway, and hope that we don't run into impossible to debug absurdities because of the contradiction. I don't think that's a good way to do this, either...  

### C can't do provenance

Posted Sep 27, 2024 17:24 UTC (Fri) by **NYKevin** (subscriber, \#129325) \[[Link](/Articles/992051/)\] (7 responses)

\> Most of the (1) do not realize how little performance there will be left without alias analysis, which cannot be done without pointer provenance.  

Neither Rust nor C(++) depend on provenance to do alias analysis. Rust uses lifetime-based alias analysis (i.e. if you have &mut T, it may not alias anything, and if you have &T, the pointee must be immutable or protected by an UnsafeCell) and C and C++ both use type-based alias analysis (i.e. if you have two pointers to distinct types, and neither type is char or a variation of char, then the pointers may not alias). In the case of Rust, it is difficult to uphold those invariants without some degree of provenance, but Rust handles this by splitting the language into safe and unsafe Rust. In safe Rust, borrow checking is far stricter than mere provenance, and in unsafe Rust, there is no such thing as provenance - you can manufacture whatever pointers or references you like, as long as any such references obey the aliasing and lifetime requirements (that is, a reference must always point at a valid allocation for the entire duration of the reference's lifetime, plus the two aliasing requirements mentioned before).  

Rust does have a provenance model documented in its ptr module, but it is non-normative and experimental (according to that very same documentation), and there's almost no information about it in the Rustonomicon. Based on a previous discussion we've had on this site, it is my understanding that some people take the view that it is wrong to claim that Rust has no provenance, because of the existence of this non-normative and experimental model. I disagree with that position but will mention it for completeness (and to save those very same people the trouble of telling me that I'm wrong in comment replies). What I think we can agree on, regardless, is the fact that Rust's aliasing analysis, as it is currently implemented in stable versions of the compiler, is not dependent on this (or any other) provenance model.  

### C can't do provenance

Posted Sep 27, 2024 21:34 UTC (Fri) by **joib** (subscriber, \#8541) \[[Link](/Articles/992074/)\] (4 responses)

\> Neither Rust nor C(++) depend on provenance to do alias analysis.  

I don't think this is correct (I don't know enough about the Rust compiler to say much about its internal workings, so the following applies to C(++)). For a trivial example, for something like  

int \*a = malloc(10);  
int \*b = malloc(10);  

the alias analysis can determine that a and b point to disjoint objects. They may not call it provenance, as that term became popular only relatively recently, but what is if not making use of provenance to help alias analysis? The various provenance proposals are mostly about formalizing what compilers are already doing, and of course covering all (well, more of them at least) the corner cases.  

Type-based alias analysis is another bit of data the compiler can use to implement alias analysis, but not the only one.  

### C can't do provenance

Posted Sep 29, 2024 9:44 UTC (Sun) by **NYKevin** (subscriber, \#129325) \[[Link](/Articles/992125/)\] (3 responses)

As I explained, the compiler is required to allow the programmer to reconstitute an arbitrary valid pointer from non-pointer data in multiple ways. So the optimization you describe is only possible if the compiler can either prove that you have not done that in a particular case, or if it can somehow prove that the pointers must not alias despite the fact that they may not obey strict provenance rules. In other words, this optimization only works in "easy" cases, and does not cover all legal uses of pointers. The compiler is required to disable it if it is not provably correct in a given case.  

Provenance is not a matter of optimization. It is not "optional," and you cannot simply turn it off when it becomes inconvenient. It is a real feature of some hardware (e.g. CHERI) that makes it impossible to dereference a possibly-invalid pointer. On that hardware, manufacturing (and dereferencing) an arbitrary pointer out of non-pointer data traps. Walking off the end of an array traps. UAF and double free both trap. And there are probably several other things that trap, but I think you get the idea. All of these traps happen even if the pointer is numerically equal to a valid pointer that exists elsewhere in the program, and could be validly dereferenced at the same exact address. This is because, on that hardware, every pointer has associated metadata that tells the hardware whether it is valid, and over what range of addresses, so the hardware can check every dereference for validity (similar to Valgrind's memcheck tool, but much stricter because it is not required to be compatible with C). In the context of programming languages, "pointer provenance" generally means the set of restrictions that must be enforced in order for the language to be compatible with CHERI and similar architectures. I have not seen the term used to refer generically to knowing where some specific pointer came from - that's usually called escape analysis or pointer analysis.  

### C can't do provenance

Posted Sep 29, 2024 10:43 UTC (Sun) by **SLi** (subscriber, \#53131) \[[Link](/Articles/992133/)\] (2 responses)

I do think "where the pointer came from" is a big part of it necessarily. Here's how Rust Unsafe Code Guidelines define it (it admits that "The exact form of provenance in Rust is unclear"):


### C can't do provenance

Posted Sep 29, 2024 21:55 UTC (Sun) by **NYKevin** (subscriber, \#129325) \[[Link](/Articles/992173/)\] (1 responses)

Yes, where the pointer came from is the whole point of provenance. That's because if the pointer came "from nowhere," or from an unrelated pointer, then on CHERI it will not have the correct metadata (or any metadata), and so dereferencing it will trap. The Rust provenance rules are intended to make it possible for a (currently hypothetical) CHERI backend to emit the necessary instructions to preserve every pointer's metadata.  

What I'm getting at is that provenance is not an optimization technique. It is a hardware constraint.  

### C can't do provenance

Posted Sep 29, 2024 22:30 UTC (Sun) by **Cyberax** (**✭ supporter ✭**, \#52523) \[[Link](/Articles/992177/)\]

\> Yes, where the pointer came from is the whole point of provenance. That's because if the pointer came "from nowhere," or from an unrelated pointer, then on CHERI it will not have the correct metadata (or any metadata), and so dereferencing it will trap.   

This can technically happen with "far" pointers on the 32-bit segmented x86 architecture. Simply reading or trying to create a pointer to an invalid segment can cause an exception.  

### C can't do provenance

Posted Sep 27, 2024 22:36 UTC (Fri) by **SLi** (subscriber, \#53131) \[[Link](/Articles/992077/)\]

Yes, it's definitely possible to do alias analysis (or even remove the need for it) without pointer provenance, in general. I just don't believe it's possible for C or C++.  

### Rust has provenance

Posted Oct 4, 2024 8:45 UTC (Fri) by **deltragon** (guest, \#159552) \[[Link](/Articles/992880/)\]

Since [RFC \#3559](https://github.com/rust-lang/rfcs/blob/master/text/3559-rust-has-provenance.md) (titled "Rust Has Provenance") was accepted in February, Rust certainly has provenance. It is true that the documentation has not quite caught up to this yet (and still refers to the Strict/Permissive Provenance APIs as "experimental"), this is also [changing](https://github.com/rust-lang/rust/pull/130350) along with the stabilisation of these APIs.

### C can't do provenance

Posted Sep 27, 2024 21:11 UTC (Fri) by **joib** (subscriber, \#8541) \[[Link](/Articles/992073/)\]

\> Most of the (1) do not realize how little performance there will be left without alias analysis, which cannot be done without pointer provenance.  

Do we have some quantitative data on this? I'm not aware of any. -fno-strict-aliasing disables only part of the alias analysis machinery (TBAA), but it's impact seems moderate for most codebases.  

### C can't do provenance

Posted Sep 27, 2024 8:37 UTC (Fri) by **Wol** (subscriber, \#4433) \[[Link](/Articles/991946/)\]

Probably the only way round it is to declare a new --pointer-provenance flag - which cannot be the default - which then says any and all integer\<-\>pointer conversions that can be detected will be treated as pointer provenance errors by the compiler.  

Bit like the laws of the Medes and the Persians :-) You're not declaring such conversions illegal, you're just saying that you're not allowed to use them in combination with pointer provenance.  

Cheers,  
Wol  

### C can't do provenance

Posted Sep 27, 2024 21:06 UTC (Fri) by **joib** (subscriber, \#8541) \[[Link](/Articles/992070/)\] (9 responses)

It's been a while, but I'm not sure my recollection of the various provenance suggestions matches yours.  

\> \* Make == compare pointers for provenance, which either requires hardware support (e.g. on CHERI or the like) or fat pointers with runtime allocator support (i.e. the allocator has to give every allocation a unique ID which is not reused on free and "never" overflows). This is necessary because the standard says that, if malloc does not fail, then the following code may not be UB on any code path (and the assert may not fire): int \*x = malloc(sizeof(int)); free(x); int \*y = malloc(sizeof(int)); if(x == y){ \*x = 2; assert(\*y == 2);}. The standard also says that == is transitive and so if we already knew that x == z, then you can dereference z instead of x, which effectively means that we can't give == a secret side effect that somehow propagates provenance from y to x (because z still would not have provenance).  

I'm 75% sure that comparing the pointer value of a freed pointer is already UB, although it's somewhat common in practice.  

\> document that your pointers cannot be represented by any integral type  

Eh, I don't think this will fly at all. Like it or not, pointer\<=\>integer conversions and roundtrips are a fact of life in the C world , and any proposal must continue to support them.  

\> But that's not good enough. A pointer is an object, and like any object, you may inspect the pointer's object representation through a char\*.   

Yes. I think this makes the "PVI" provenance proposal intractable, since it's not feasible for a compiler to keep track of provenance via arbitrary integer manipulations (arithmetic, IO, IPC, etc.). Hence these various "PVNI" proposals that seem to be the ones the C committee is looking more seriously at.  

\> I can only think of one loophole that might be used to prohibit this, but it's a real stretch: You could declare that pointers produced in this manner are trap representations, and thus UB to create.   

No, why? In the PVNI proposals there's no requirement for perfect knowledge by the compiler, which is you point out is intractable. It just means the compiler must treat a pointer constructed in such a way as potentially aliasing any escaped pointer (called "exposed" in the PVNI proposals but AFAICS this is more or less the same thing as what compiler people call an address or pointer escaping).  

### C can't do provenance

Posted Sep 28, 2024 3:54 UTC (Sat) by **foom** (subscriber, \#14868) \[[Link](/Articles/992084/)\] (1 responses)

\> comparing the pointer value of a freed pointer is already UB  

Correct.  

From C23 "6.2.4 Storage durations of objects" (earlier versions say effectively the same):  
\> If a pointer value is used in an evaluation after the object the pointer points to (or just past) reaches the end of its lifetime, the behavior is undefined. The representation of a pointer object becomes indeterminate when the object the pointer points to (or just past) reaches the end of its lifetime.  

### C can't do provenance

Posted Sep 29, 2024 21:59 UTC (Sun) by **NYKevin** (subscriber, \#129325) \[[Link](/Articles/992174/)\]

Then someone needs to correct <https://en.cppreference.com/w/c/memory/free>, which says the following:  

\> The behavior is undefined if after free() returns, an access is made through the pointer ptr (unless another allocation function happened to result in a pointer value equal to ptr).  

### C can't do provenance

Posted Sep 29, 2024 22:04 UTC (Sun) by **NYKevin** (subscriber, \#129325) \[[Link](/Articles/992175/)\] (6 responses)

\> I'm 75% sure that comparing the pointer value of a freed pointer is already UB, although it's somewhat common in practice.  

Unfortunately, text in <https://en.cppreference.com/w/c/memory/free> misled me into thinking the standard allowed this (and then I couldn't find language in the draft standard directly contradicting it).  

\> Eh, I don't think this will fly at all. Like it or not, pointer\<=\>integer conversions and roundtrips are a fact of life in the C world , and any proposal must continue to support them.  

C23 explicitly says that intptr_t is optional. If you don't provide it, then there is no line in the standard requiring pointer-to-integer conversions to be possible.  

\> No, why? In the PVNI proposals   

Please link to the proposal you are discussing, Google can't find anything by that name. It did find a link to something under open-std.org titled "A Provenance-aware Memory Object Model for C," which does not contain the word "PVNI" anywhere on the page, but the page is not loading for me, so I can't examine it to determine whether it has anything to do with what you are saying.  

\> there's no requirement for perfect knowledge by the compiler, which is you point out is intractable. It just means the compiler must treat a pointer constructed in such a way as potentially aliasing any escaped pointer (called "exposed" in the PVNI proposals but AFAICS this is more or less the same thing as what compiler people call an address or pointer escaping).  

As I have repeatedly explained throughout this thread, provenance is not an optimization. It is a hardware constraint. You can't simply turn it off in difficult cases, because the dereference will trap whether the compiler wants it to or not.  

### C can't do provenance

Posted Sep 29, 2024 22:11 UTC (Sun) by **NYKevin** (subscriber, \#129325) \[[Link](/Articles/992176/)\] (4 responses)

Just to further clarify: I am aware that provenance proposals usually do have an escape hatch for "exposed" addresses. But to my understanding, such an escape hatch does not exist on CHERI or other hardware, so any such escape hatch would need to be emulated by the kernel if it's going to work at all. While that is technically possible to implement, it leaves a ton of performance on the table and requires OS support.  

### C can't do provenance

Posted Sep 30, 2024 7:19 UTC (Mon) by **joib** (subscriber, \#8541) \[[Link](/Articles/992188/)\] (3 responses)

I don't think the 'escape hatch' is needed on CHERI, assuming the code uses the (special in CHERI-C) intptr_t type for any pointer\<=\>integer roundtrips.  

The escape hatch is needed for mainstream implementations where the HW does not carry around any provenance information, and the compiler is not tracking provenance once a pointer is 'exposed' (and in some cases, is fundamentally incapable to at compile time).  

\> it leaves a ton of performance on the table  

It would be nice to have some quantitative data backing that statement.  

I don't have any quantitative data proving otherwise either, but AFAICS the 'escape hatch' is activated in situations like  

1\) Pointer a is exposed, creating an integer a1.  

2\) Some time later, a pointer b is created 'out of thin air'. Maybe b is created via a1, maybe not, the compiler doesn't know.  

Now the compiler must assume that a and b potentially alias, and thus some fancy optimizations cannot be done. But crucially, the compiler can still use provenance to reason about pointer c which has not been exposed, and do optimizations related to that pointer accordingly. Given that situations like the above are hopefully somewhat rare, I'm not buying the story about a major performance impact without benchmarks.  

I also don't understand what OS support would be needed? Or are you assuming that on mainstream HW the OS would emulate CHERI and "manually" keep track of provenance in the kernel, somehow?  

Perhaps this is where we disagree; I see the provenance proposals mainly as an effort to codify existing practices by optimizing compilers. I see CHERI as a separate effort trying to make computing safer by detecting violations at runtime, using provenance as a crucial tool to implement said detection. And there has been some collaboration between the CHERI folks and the ones writing the provenance proposals (which is very nice, I would very much like to see CHERI or something like it becoming mainstream, and it would be a bummer if C would go in an incompatible direction). But I don't think that if any of the provenance proposals is adopted, that it would require implementations to somehow emulate CHERI on non-CHERI hw. C-with-provenance on mainstream hardware would still be as dangerous and error-prone as it is today. Just hopefully with a bit less ambiguity whether something the compiler does is a miscompilation or perfectly allowed, once compilers implement the provenance rules.  

### C can't do provenance

Posted Sep 30, 2024 19:52 UTC (Mon) by **NYKevin** (subscriber, \#129325) \[[Link](/Articles/992338/)\] (2 responses)

\> I don't think the 'escape hatch' is needed on CHERI, assuming the code uses the (special in CHERI-C) intptr_t type for any pointer\<=\>integer roundtrips.  

It is required for pointer \<=\> char\[\], which in C23 is legal for any type, including all pointers. It is not practically possible for the compiler to emit provenance-preserving operations for every byte that the program manipulates, so I would think it obvious that you have to draw a boundary there.  

The other problem is that intptr_t is a number. It is not an opaque object that is allowed to have magical properties. If any part of the program becomes aware of that number, by any means whatsoever, then it is allowed to reconstruct and dereference the pointer (provided the allocation still exists). That means you can flatten it into ASCII base 10 (or any other base), send it to a remote host as JSON (or any other format), receive it back from that same host or a different one, unpack it all back into a pointer, and dereference it. No hardware in the world will ever support tracking provenance across that sequence of operations.  

\> The escape hatch is needed for mainstream implementations where the HW does not carry around any provenance information, and the compiler is not tracking provenance once a pointer is 'exposed' (and in some cases, is fundamentally incapable to at compile time).  

Then you don't need to do anything special. UB means that the standard doesn't cover a situation. It does not mean that the compiler is forbidden from introducing an extension to make UB defined. The compiler can just say in its documentation "as an extension, on all architectures other than X, Y, and Z, provenance does not exist and all pointer \<=\> data conversions that were valid in C23 are still valid and the resulting pointers may still be dereferenced." Of course, this would be based on some hypothetical future version of the standard, since as I have explained, C23 has no reasonable support for provenance.  

The other, far simpler option is for CNext to state that provenance rules only apply to a given platform (or configuration) if the compiler's documentation explicitly says that it does. Frankly, that strikes me as the obvious way to deal with this, and then none of these discussions are even necessary at all.  

\> It would be nice to have some quantitative data backing that statement.  

That statement was specific to hardware that has provenance and requires kernel emulation of exposed pointer dereferences. IMHO it is obvious that kernel emulation is slow, and it does not need to be measured (I don't even know if there are any operating systems that both support CHERI and implement exposed address emulation). Your discussion of platforms that do not have provenance is frankly irrelevant to my statement.  

\> But I don't think that if any of the provenance proposals is adopted, that it would require implementations to somehow emulate CHERI on non-CHERI hw.   

Of course not, I was assuming that all readers were familiar with the definition of UB and the fact that the implementation is encouraged to do whatever makes sense (performance-wise) on a given platform when UB happens. I don't understand how you read this into my comment, when I so explicitly characterized provenance as a hardware feature and disclaimed its relevance to non-CHERI-like platforms.  

### C can't do provenance

Posted Sep 30, 2024 22:45 UTC (Mon) by **Wol** (subscriber, \#4433) \[[Link](/Articles/992362/)\]

\> IMHO it is obvious that kernel emulation is slow, and it does not need to be measured (I don't even know if there are any operating systems that both support CHERI and implement exposed address emulation).   

The problem with common sense is that it is not common, and rarely makes sense.  

As such, a statement like "imho it is obvious" is almost certainly wrong. How often do we hear "it stands to reason", only to discover that said reasoning has missed the obvious and come to a conclusion diametrically opposed to empirical observation.  

Cheers,  
Wol  

### C can't do provenance

Posted Oct 1, 2024 11:02 UTC (Tue) by **farnz** (subscriber, \#17727) \[[Link](/Articles/992416/)\]

> The other, far simpler option is for CNext to state that provenance rules only apply to a given platform (or configuration) if the compiler's documentation explicitly says that it does. Frankly, that strikes me as the obvious way to deal with this, and then none of these discussions are even necessary at all.

The issue is that without provenance rules, alias analysis becomes intractable, since any integer could be cast to a pointer, including in other modules. And without alias analysis, you have to assume that any write through a pointer, including in other threads that have a suitable ordering with your thread, could write to any variable.

Compiler writers handle this by assuming that certain things can't alias, even though the language standard doesn't prohibit that form of aliasing, and then hoping that their gut feelings work out when they write optimizations that assume that (e.g.) an integer and a pointer to a struct don't alias. This works most of the time, since compiler writers aren't evil, and their assumptions match those that programmers tend to make.

Unfortunately, some of the assumptions that compiler authors make contradict each other; each of them technically breaks the letter of the standard (so neither one is "right"), and each of them results in an optimization that improves code without surprising C programmers, but the combination of optimizations that assume different things results in a miscompilation. The intention behind formalizing provenance rules is to get to a place where the standard can be used to determine which of those optimizations is at fault when the combination surprises people.

### C can't do provenance

Posted Sep 30, 2024 6:27 UTC (Mon) by **joib** (subscriber, \#8541) \[[Link](/Articles/992181/)\]

\> C23 explicitly says that intptr_t is optional. If you don't provide it, then there is no line in the standard requiring pointer-to-integer conversions to be possible.  

I believe if the implementation provides an integer type large enough to hold a pointer, it must be possible to do such a pointer-to-integer conversion. So even without specifically intptr_t (which, in the history of C is a recent-ish invention anyway as it was introduced only in C99) it can be done, and many C implementation through history have done so.  

That being said, I think you're correct in that there's nothing in the standard requiring an implementation to provide such large enough integer types capable of storing a pointer. But that gets into the distinction between the standard and that a lot of C code out there is written under the assumption that such an integer type exists.  

Now, CHERI C is a bit special in that they make intptr_t contain the bounds and capability tag, making it possible to do pointer\<=\>integer roundtrips only with that type. That's probably a good practical compromise between the purity of the capability model, standards conformance, and still allowing roundtripping with a modest porting effort.  

\> Please link to the proposal you are discussing, Google can't find anything by that name.   

It's a typo, I meant PNVI (\*sigh\*). I think the latest proposal is n3005 at https://open-std.org/JTC1/SC22/WG14/www/docs/n3005.pdf . That link doesn't work for me at the moment but you can find it in the wayback machine.  

\> As I have repeatedly explained throughout this thread, provenance is not an optimization. It is a hardware constraint. You can't simply turn it off in difficult cases, because the dereference will trap whether the compiler wants it to or not.  

Well, for CHERI it's a hardware constraint. But like it or not, non-CHERI hw will be the vast majority for the foreseeable future, and AFAIU there's no plan to make C-with-provenance (if that ever happens) non-implementable on such hardware. For mainstream environments, the practical effect of provenance is to provide compiler writers with guidance on what kinds of optimizations are allowed.  

### This is why so many programs use extensions

Posted Sep 27, 2024 2:18 UTC (Fri) by **DemiMarie** (subscriber, \#164188) \[[Link](/Articles/991932/)\] (1 responses)

In the Linux kernel, many of those undefined behaviors are actually well-defined, thanks to -fno-strict-aliasing, -fno-strict-overflow, -fno-delete-null-pointer-checks, and possibly some other compiler flags. Linux does not even try to conform to the C standard’s requirements for pointer arithmetic, and I agree with that decision.  

### This is why so many programs use extensions

Posted Sep 29, 2024 19:55 UTC (Sun) by **netbsduser** (guest, \#171655) \[[Link](/Articles/992170/)\]

Yes, the language the ISO standard defines is, to quote Dennis Ritchie himself, "an unreal language that no one can or will actually use". Needless to say if you can't rely on pointers at least mostly looking like and behaving in use as addresses, you can't write an operating system in the language. How would you ever deal with memory-mapped I/O, for instance?  

### C is not as simple as it seems

Posted Oct 2, 2024 3:01 UTC (Wed) by **alison** (subscriber, \#63752) \[[Link](/Articles/992570/)\]

Do you have a blog? The comment is the outline of a fine ACCU conference talk.  

### "the right color of hair"

Posted Sep 26, 2024 1:20 UTC (Thu) by **carlosrodfern** (subscriber, \#166486) \[[Link](/Articles/991753/)\] (8 responses)

That was an unfortunate comment. I have one 80+ years old engineer coworker and he is still teaching others a thing or two.  

### "the right color of hair"

Posted Sep 26, 2024 10:31 UTC (Thu) by **farnz** (subscriber, \#17727) \[[Link](/Articles/991820/)\] (7 responses)

I think you're possibly missing the point, though. Having the 80/90 year olds around and helping is awesome - they've got a depth of experience; however, would you bet the survival of your company on the 80+ years old engineer being around for the next 10 years? 20 years? 50 years?

At some point, the older generation is going to become unavailable to work on things. If the plan for the future is "I'll never retire, I'll never die, I'll never suffer a nasty disease like dementia", your project has a problem. If the plan is "well, we've got 3 employees under 50 who between them could replace the 80+ employee if necessary", you've got a future.

### "the right color of hair"

Posted Sep 26, 2024 15:13 UTC (Thu) by **carlosrodfern** (subscriber, \#166486) \[[Link](/Articles/991901/)\] (6 responses)

I did get the point from the beginning. Linus corrected him, and then he clarified his point. Nevertheless, he started with such a statement, which in general reflects the sentiment of many in this industry.  

### "the right color of hair"

Posted Sep 26, 2024 16:54 UTC (Thu) by **jake** (editor, \#205) \[[Link](/Articles/991909/)\] (3 responses)

\> Nevertheless, he started with such a statement, which in general reflects the sentiment of many in this industry.  

I personally think he was just commenting on the fact that the color of (and/or amount of) kernel maintainers' hair has changed over the years. I pretty strongly doubt he was making an ageist statement, anyway ...  

jake  

### "the right color of hair"

Posted Sep 26, 2024 19:04 UTC (Thu) by **carlosrodfern** (subscriber, \#166486) \[[Link](/Articles/991915/)\] (2 responses)

It could also be just a sarcastic/humor statement to introduce the topic. Dirk Hohndel has lots of gray hair too :D.  

### "the right color of hair"

Posted Oct 3, 2024 19:08 UTC (Thu) by **mikebenden** (guest, \#74702) \[[Link](/Articles/992840/)\] (1 responses)

JFC, the fact that y'all felt obligated to go over this obviously self-deprecating joke with such a fine toothed comb, for a total of 6 back-and-forth comments (and counting), is just... sad... :(  

### "the right color of hair"

Posted Oct 4, 2024 9:54 UTC (Fri) by **farnz** (subscriber, \#17727) \[[Link](/Articles/992882/)\]

That's the trouble with older generations - they're such sensitive snowflakes :-)

More seriously, this is the trouble with humour - it doesn't always translate well across media or cultural boundaries.

### "the right color of hair"

Posted Oct 3, 2024 18:05 UTC (Thu) by **dirkhh** (subscriber, \#50216) \[[Link](/Articles/992830/)\] (1 responses)

I believe it's pretty clear, if you watch the recording, that I was talking about the color of Linus' and especially my hair.  
I used to be a red-haired. I am decidedly not any more. So mostly this was a tongue in cheek comment about myself and Linus.  

### "the right color of hair"

Posted Nov 9, 2024 5:08 UTC (Sat) by **carlosrodfern** (subscriber, \#166486) \[[Link](/Articles/997593/)\]

I didn't even know these comments were still going here. Sorry, that's right, I realized that later when I watched the video. I enjoyed watching your interviews, BTW.  

### Lemmings off a cliff

Posted Nov 2, 2024 4:53 UTC (Sat) by **soheil** (guest, \#102255) \[[Link](/Articles/996744/)\]

\> lemmings off a cliff  

What if the lemmings don't know they're following the other lemmings and think they're doing their own thing?  
