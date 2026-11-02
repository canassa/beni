---
title: We need a safer systems programming language (MSRC, 2019)
source: https://msrc.microsoft.com/blog/2019/07/we-need-a-safer-systems-programming-language/
retrieved: 2026-11-02
note: retrieved via web.archive.org snapshot; msrc.microsoft.com returned 403
---

This blog post is older than a year. The information provided below may be outdated.

- [blog](/web/20240226205255/https://msrc.microsoft.com/blog/)
- [2019](/web/20240226205255/https://msrc.microsoft.com/blog/2019/)
- [07](/web/20240226205255/https://msrc.microsoft.com/blog/2019/07/)
- we-need-a-safer-systems-programming-language/

# We need a safer systems programming language

[Security Research & Defense](/web/20240226205255/https://msrc.microsoft.com/blog/categories/security-research-defense/ "Security Research & Defense")

/ By [MSRC Team](/web/20240226205255/https://msrc.microsoft.com/blog/authors/sebastian-fernandez/ "Read more posts by the author MSRC Team") / July 18, 2019 / 6 min read

In our [first post in this series](https://web.archive.org/web/20240226205255/https://msrc-blog.microsoft.com/2019/07/16/a-proactive-approach-to-more-secure-code/), we discussed the need for proactively addressing memory safety issues. Tools and guidance are demonstrably not preventing this class of vulnerabilities; memory safety issues have represented almost the same proportion of vulnerabilities assigned a CVE for over a decade. We feel that using memory-safe languages will mitigate this in ways that tools and training have not been able to.

In this post, we’ll explore some real-world examples of vulnerabilities found in Microsoft products (after testing and static analysis) that could be prevented by using a memory-safe language.

## Memory Safety [](#memory-safety)

[Memory safety](https://web.archive.org/web/20240226205255/https://en.wikipedia.org/wiki/Memory_safety) is a property of programming languages where all memory access is well defined. Most programming languages in use today *are* memory-safe because they use some form of garbage collection. However, *systems-level languages* (i.e., languages used to build the underlying systems other software depends on, like OS kernels, networking stacks, etc.) which cannot afford a heavy runtime like a garbage collector are usually not memory-safe.

As was pointed out in our [previous post](https://web.archive.org/web/20240226205255/https://msrc-blog.microsoft.com/2019/07/16/a-proactive-approach-to-more-secure-code/), the root cause of approximately 70% of security vulnerabilities that Microsoft fixes and assigns a CVE (Common Vulnerabilities and Exposures) are due to memory safety issues. This is despite mitigations including intense code review, training, static analysis, and more.

[![Patch year graph](/web/20240226205255im_/https://msrc.microsoft.com/blog/2019/07/we-need-a-safer-systems-programming-language/wp-content-uploads-2019-07-image-1.png)](/web/20240226205255/https://msrc.microsoft.com/blog/2019/07/we-need-a-safer-systems-programming-language/wp-content-uploads-2019-07-image-1.png)

~70% of the vulnerabilities Microsoft assigns a CVE each year continue to be memory safety issues

While many experienced programmers can write correct systems-level code, it’s clear that no matter the amount of mitigations put in place, it is near impossible to write memory-safe code using traditional systems-level programming languages *at scale*.

Let’s look at some real-life examples of security vulnerabilities that have been caused by the use of languages without a memory safety guarantee.

### Spatial memory safety [](#spatial-memory-safety)

*Spatial memory safety* refers to ensuring that all memory accesses are within bounds of the type that is being accessed. Doing this requires code to both track these sizes and correctly check all memory operations against these sizes.

Checks can either be absent for an edge case of control flow or can be implemented incorrectly due to not accounting for the intricacies of integer sign, integer promotion, or integer overflow. Let’s consider this example from Microsoft Edge, found by Alexandru Pitis (CVE-2018-8301):

[![CVE-2018-8301 example](/web/20240226205255im_/https://msrc.microsoft.com/blog/2019/07/we-need-a-safer-systems-programming-language/wp-content-uploads-2019-07-code1_hudba2a7fed04b14d0654105c11391bdd1_27311_800x0_resize_box_3.png)](/web/20240226205255/https://msrc.microsoft.com/blog/2019/07/we-need-a-safer-systems-programming-language/wp-content-uploads-2019-07-code1_hudba2a7fed04b14d0654105c11391bdd1_27311_800x0_resize_box_3.png)

The check at \[0\] is correct. However, \[1\] can modify the size of the string invalidating the retrieved offset. The function at \[2\] calls a copy function which ends up being different than the expected offset, triggering an exploitable out of bounds write.

The fix for this vulnerability is easy: move the “offset check” closer to the time of use. The problem is that this is very error-prone in complex code bases and a simple refactor of the code could open this vulnerability again. Modern C++ offers [span](https://web.archive.org/web/20240226205255/https://en.cppreference.com/w/cpp/container/span) to enforce bounds checked array accesses. Unfortunately, it is not the default, and so it is the responsibility of the developer to opt into using it. In practice, enforcing the usage of such constructs is difficult.

If the language could automatically track and verify sizes for us, we as programmers would no longer need to worry about having to implement these checks correctly, and we could be certain that none of these issues exist in our code.

### Temporal memory safety [](#temporal-memory-safety)

*Temporal memory safety* refers to ensuring that pointers still point to valid memory at the time of dereference.

A common use-after-free pattern comes from taking a reference to some memory in a local pointer, executing a complex series of operations that could result in freeing or moving the memory, making the local pointer become stale, and then dereferencing it when it is no longer valid. Consider this source code example from Edge found by Steven Hunter (CVE-2017-8596):

[![Code example](/web/20240226205255im_/https://msrc.microsoft.com/blog/2019/07/we-need-a-safer-systems-programming-language/wp-content-uploads-2019-07-code2.png)](/web/20240226205255/https://msrc.microsoft.com/blog/2019/07/we-need-a-safer-systems-programming-language/wp-content-uploads-2019-07-code2.png)

This bug is possible because of how many complex APIs interact with each other and the programmer not being able to enforce ownership of memory throughout the codebase. At \[0\], the program gets a pointer to a buffer owned by a JavaScript object. Then at \[1\], because of the language complexity, to get another variable, it might execute more JavaScript code. At \[2\], it will use the buffer and width to create a new JavaScript object with the contents of that pointer.

The problems are:

1.  The program uses a combination of garbage collection and manual memory management. The garbage collector tracks the JavaScript objects but it doesn’t know if there is a pointer to an internal part of the object
2.  Because VarToInt reenters into JavaScript, the JS program can modify the state and clear the owner of the pointer it aliased at \[1\]

The vulnerability is similar to an iterator invalidation bug where all the pointers to the internal state of JavaScript might become dangling if the state is modified. This issue can be solved in many ways. However, statically proving that this error does not happen again is nearly impossible in programs as complex as browsers. The root of the problem comes from aliasing pointers that point to mutable state. C and C++ do not have the tools to enforce the prevention of such errors. However, it’s recommended to always use “*smart pointers”* for tracking memory ownership.

### Data races [](#data-races)

A *data race* occurs when two or more threads in a single process concurrently access the same memory location, at least one of the accesses is for writing, and the threads are not using any exclusive locks to control their accesses to that memory. When considering shared data across multi-threaded execution, keeping spatial and temporal memory safety becomes even more difficult and error prone. Even small windows of time of unsynchronized memory sharing might allow another thread to modify data that can be used to reference memory. This allows, among other things, time-of-check vs time-of-use vulnerabilities that trigger spatial and temporal memory safety vulnerabilities

Jordan Rabet’s VMSwitch vulnerability, [presented](https://web.archive.org/web/20240226205255/https://i.blackhat.com/us-18/Thu-August-9/us-18-Rabet-Hardening-Hyper-V-Through-Offensive-Security-Research.pdf) at Blackhat 2018, shows one potential impact of a data race. This code is called when a virtual machine sends a specific message to the host. This means that it can be called in parallel to the processing of other control messages and packets. This is problematic because the handlers for those control messages use information that is modified without any locking being done \[0\].

[![{ hostData-&gt;BufferId = BufferId; \[0\] hostData-&gt;Buffer = Buffer; \[1\] // hostData-&gt;BufferSize = BufferSize; hostData-&gt;CtrlMessagesAllocatedBufferSize = BufferSections \[NumBufferSections-1\]. SubAllocationSize; for (controlAllocIndex = 0; { controlAllocIndex &lt; RNDISDEV_HOST_MAX_PENDING_CONTROL_MESSAGES; ++controlAllocIndex) status = RndisDevHostInternalAllocateSingleSubAllocation( hostData, hostData-&gt;CtrlMessages AllocatedBufferSize, &amp;(opHostData-&gt;AllocatedRanges), &amp;(opHostData-&gt;AllocatedBuffer)); } }](/web/20240226205255im_/https://msrc.microsoft.com/blog/2019/07/we-need-a-safer-systems-programming-language/wp-content-uploads-2019-07-code3.png)](/web/20240226205255/https://msrc.microsoft.com/blog/2019/07/we-need-a-safer-systems-programming-language/wp-content-uploads-2019-07-code3.png)

Looking at the next snippet, which is used for several control message completion handlers, we can see how the information being updated is used:

[![\[2\] destination = (PVOID) ((UINT_PTR) HostData-&gt;Buffer + currentRanges-&gt;Range\[0\].ByteOffset + offsetIntoCurrentRanges); currentBytesToCopy = currentRanges-&gt;Range\[0\].ByteCount-offsetIntoCurrentRanges; if (currentBytesToCopy &gt; bytes LeftToCopy) { currentBytesToCopy = bytes LeftToCopy; } \[3\] RtlCopyMemory (destination, (PVOID) ((UINT_PTR)Buffer + (BufferSize - bytesLeftToCopy)), currentBytesToCopy);](/web/20240226205255im_/https://msrc.microsoft.com/blog/2019/07/we-need-a-safer-systems-programming-language/wp-content-uploads-2019-07-code4.png)](/web/20240226205255/https://msrc.microsoft.com/blog/2019/07/we-need-a-safer-systems-programming-language/wp-content-uploads-2019-07-code4.png)

Due to this unsynchronized access, it’s possible for the new buffer base to be used with the old opHostData-\>AllocatedRanges \[1\] values, leading to an out-of-bounds write \[3\].

Preventing these types of vulnerabilities requires locking the data structures accessed by different threads for the time necessary to complete its processing. However, there is no easy way to statically enforce checks for these types of vulnerabilities in C++.

## What We Can Do About it [](#what-we-can-do-about-it)

Addressing the issues highlighted above required taking several different measures. “Modern” constructs in C++ like [span\<T](https://web.archive.org/web/20240226205255/https://docs.microsoft.com/en-us/dotnet/api/system.span-1?view=netstandard-2.1)\> can prevent at least some classes of memory safety issues, and other modern C++ features such as smart pointers should be used wherever possible. However, modern C++ is still not completely memory-safe and data-race free. What’s more, usage of such features relies on programmers always “doing the right thing” which in large and ambiguous codebases may be impossible to enforce. C++ also lacks good tools for wrapping unsafe code in safe abstractions meaning while it might be possible to enforce correct coding practices on a local level, it can prove extremely difficult to build software components in C or C++ that compose safely.

Beyond this, whenever possible software should eventually be moved to a completely memory-safe language like C# or F# that ensure memory safety through runtime checks and garbage collection. After all, you should only incur the complexity of having to think about memory management when necessary.

If there are legitimate reasons for needing the speed, control and predictability of a language like C++, see if you can move to a systems-level programming language that is memory safe. In our next post, we’ll explore why we think [the Rust programming language](https://web.archive.org/web/20240226205255/https://rust-lang.org/) is currently the best choice for the industry to adopt whenever possible due to its ability to write systems-level programs in a memory-safe way.

*Ryan Levick, Principal Cloud Developer Advocate*

*Sebastian Fernandez, Security Software Engineer*

- [Memory Safety](/web/20240226205255/https://msrc.microsoft.com/blog/tags/memory-safety/)
- [Rust](/web/20240226205255/https://msrc.microsoft.com/blog/tags/rust/)
- [Safe Systems Programming Languages](/web/20240226205255/https://msrc.microsoft.com/blog/tags/safe-systems-programming-languages/)
- [Secure Development](/web/20240226205255/https://msrc.microsoft.com/blog/tags/secure-development/)

------------------------------------------------------------------------

[Previous Post](/web/20240226205255/https://msrc.microsoft.com/blog/2019/07/announcing-the-microsoft-dynamics-365-bounty-program/)

[Next Post](/web/20240226205255/https://msrc.microsoft.com/blog/2019/07/why-rust-for-safe-systems-programming/)

### Related Posts

- [Security Analysis of CHERI ISA](/web/20240226205255/https://msrc.microsoft.com/blog/2020/10/security-analysis-of-cheri-isa/ "Security Analysis of CHERI ISA")
- [Control Flow Guard for Clang/LLVM and Rust](/web/20240226205255/https://msrc.microsoft.com/blog/2020/08/control-flow-guard-for-clang-llvm-and-rust/ "Control Flow Guard for Clang/LLVM and Rust")
- [The Safety Boat: Kubernetes and Rust](/web/20240226205255/https://msrc.microsoft.com/blog/2020/04/the-safety-boat-kubernetes-and-rust/ "The Safety Boat: Kubernetes and Rust")

[![RSS feed](/web/20240226205255im_/https://msrc.microsoft.com/blog/images/rss.png)Subscribe](/web/20240226205255/https://msrc.microsoft.com/blog/rss/)

### [Categories](/web/20240226205255/https://msrc.microsoft.com/blog/categories/)

- [MSRC](/web/20240226205255/https://msrc.microsoft.com/blog/categories/msrc/) (1062)
- [Japan Security Team](/web/20240226205255/https://msrc.microsoft.com/blog/categories/japan-security-team/) (1024)
- [Security Research & Defense](/web/20240226205255/https://msrc.microsoft.com/blog/categories/security-research-defense/) (380)
- [BlueHat](/web/20240226205255/https://msrc.microsoft.com/blog/categories/bluehat/) (189)
- [Bug Bounty Programs](/web/20240226205255/https://msrc.microsoft.com/blog/categories/bug-bounty-programs/) (5)
- [Microsoft Threat Hunting](/web/20240226205255/https://msrc.microsoft.com/blog/categories/microsoft-threat-hunting/) (5)

### [Tags](/web/20240226205255/https://msrc.microsoft.com/blog/tags/)

- [セキュリティ情報](/web/20240226205255/https://msrc.microsoft.com/blog/tags/%E3%82%BB%E3%82%AD%E3%83%A5%E3%83%AA%E3%83%86%E3%82%A3%E6%83%85%E5%A0%B1/) (465)
- [脆弱性](/web/20240226205255/https://msrc.microsoft.com/blog/tags/%E8%84%86%E5%BC%B1%E6%80%A7/) (248)
- [アドバイザリ](/web/20240226205255/https://msrc.microsoft.com/blog/tags/%E3%82%A2%E3%83%89%E3%83%90%E3%82%A4%E3%82%B6%E3%83%AA/) (175)
- [Internet Explorer (IE)](/web/20240226205255/https://msrc.microsoft.com/blog/tags/internet-explorer-ie/) (156)
- [Security Update](/web/20240226205255/https://msrc.microsoft.com/blog/tags/security-update/) (140)
- [Security Advisory](/web/20240226205255/https://msrc.microsoft.com/blog/tags/security-advisory/) (135)
- [Security Bulletin](/web/20240226205255/https://msrc.microsoft.com/blog/tags/security-bulletin/) (133)
- [Mitigations](/web/20240226205255/https://msrc.microsoft.com/blog/tags/mitigations/) (128)
- [Community-based Defense](/web/20240226205255/https://msrc.microsoft.com/blog/tags/community-based-defense/) (109)
- [Microsoft Windows](/web/20240226205255/https://msrc.microsoft.com/blog/tags/microsoft-windows/) (106)
- [View all Tags](/web/20240226205255/https://msrc.microsoft.com/blog/tags/)

### [Recent Posts](/web/20240226205255/https://msrc.microsoft.com/blog/)

- [An Obsession With Impact: The Inspiring Journey of a Dreamer That Led to a Career at Microsoft](/web/20240226205255/https://msrc.microsoft.com/blog/2024/02/an-obsession-with-impact-the-inspiring-journey-of-a-dreamer-that-led-to-a-career-at-microsoft/)
- [New Security Advisory Tab Added to the Microsoft Security Update Guide](/web/20240226205255/https://msrc.microsoft.com/blog/2024/02/new-security-advisory-tab-added-to-the-microsoft-security-update-guide/)
- [Congratulations to the Top MSRC 2023 Q4 Security Researchers!](/web/20240226205255/https://msrc.microsoft.com/blog/2024/01/congratulations-to-the-top-msrc-2023-q4-security-researchers/)
- [Microsoft Actions Following Attack by Nation State Actor Midnight Blizzard](/web/20240226205255/https://msrc.microsoft.com/blog/2024/01/microsoft-actions-following-attack-by-nation-state-actor-midnight-blizzard/)
- [BlueHat India Call for Papers is Now Open!](/web/20240226205255/https://msrc.microsoft.com/blog/2024/01/bluehat-india-call-for-papers-is-now-open/)

### [Archives](/web/20240226205255/https://msrc.microsoft.com/blog/archives/)

- [February 2024](/web/20240226205255/https://msrc.microsoft.com/blog/2024/02/) (4)
- [January 2024](/web/20240226205255/https://msrc.microsoft.com/blog/2024/01/) (6)
- [December 2023](/web/20240226205255/https://msrc.microsoft.com/blog/2023/12/) (3)
- [November 2023](/web/20240226205255/https://msrc.microsoft.com/blog/2023/11/) (10)
- [October 2023](/web/20240226205255/https://msrc.microsoft.com/blog/2023/10/) (9)
- [View full Archive](/web/20240226205255/https://msrc.microsoft.com/blog/archives/)
