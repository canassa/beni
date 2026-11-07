---
title: Why Discord is switching from Go to Rust
source: https://discord.com/blog/why-discord-is-switching-from-go-to-rust
retrieved: 2026-11-02
---

[](#)

Lorem ipsum dolor sit

  \>  

[Mi neque maecenas](#)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/611ed6b3ff0df3e75a6b3c28_1_BYeVEgTVQia4MD5LSLoUlA.png)

Engineering & Developers

# Why Discord is switching from Go to Rust

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/61241fc9e69b8b98583c89f8_1_tNrZL0th3ePB5oiniU6Ryg.png)

Jesse Howarth

February 4, 2020

Rust is becoming a first class language in a variety of domains. At Discord, we’ve seen success with Rust on the client side and server side. For example, we use it on the client side for our video encoding pipeline for Go Live and on the server side for [Elixir NIFs](https://blog.discordapp.com/using-rust-to-scale-elixir-for-11-million-concurrent-users-c6f19fc029d3). Most recently, we drastically improved the performance of a service by switching its implementation from Go to Rust. This post explains why it made sense for us to reimplement the service, how it was done, and the resulting performance improvements.

### The Read States service

Discord is a product focused company, so we’ll start with some product context. The service we switched from Go to Rust is the “Read States” service. Its sole purpose is to keep track of which channels and messages you have read. Read States is accessed every time you connect to Discord, every time a message is sent and every time a message is read. In short, Read States is in the hot path. We want to make sure Discord feels super snappy all the time, so we need to make sure Read States is quick.

With the Go implementation, the Read States service was not supporting its product requirements. It was fast most of the time, but every few minutes we saw large latency spikes that were bad for user experience. After investigating, we determined the spikes were due to core Go features: its memory model and garbage collector (GC).

### Why Go did not meet our performance targets

To explain why Go wasn’t meeting our performance targets, we first need to discuss the data structures, scale, access patterns, and architecture of the service.

The data structure we use to store read state information is conveniently called “Read State”. Discord has billions of Read States. There is one Read State per User per Channel. Each Read State has several counters that need to be updated atomically and often reset to 0. For example, one of the counters is how many @mentions you have in a channel.

In order to get quick atomic counter updates, each Read States server has a Least Recently Used (LRU) cache of Read States. There are millions of Users in each cache. There are tens of millions of Read States in each cache. There are hundreds of thousands of cache updates per second.

For persistence, we back the cache with a Cassandra database cluster. On cache key eviction, we commit your Read States to the database. We also schedule a database commit for 30 seconds in the future whenever a Read State is updated. There are tens of thousands of database writes per second.

In the picture below, you can see the response time and system cpu for a peak sample time frame for the Go service.¹ As you might notice, there are latency and CPU spikes roughly every 2 minutes.

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/611ed6f4d7cd20ec6f590cce_1*3v779KSfo2OkxUPfPptq_Q.png)

### So why 2 minute spikes?

In Go, on cache key eviction, memory is not immediately freed. Instead, the garbage collector runs every so often to find any memory that has no references and then frees it. In other words, instead of freeing immediately after the memory is out of use, memory hangs out for a bit until the garbage collector can determine if it’s truly out of use. During garbage collection, Go has to do a lot of work to determine what memory is free, which can slow the program down.

These latency spikes definitely smelled like garbage collection performance impact, but we had written the Go code very efficiently and had very few allocations. We were not creating a lot of garbage.

After digging through the Go source code, we learned that Go will force a garbage collection run every [2 minutes at minimum](https://github.com/golang/go/blob/895b7c85addfffe19b66d8ca71c31799d6e55990/src/runtime/proc.go#L4481-L4486). In other words, if garbage collection has not run for 2 minutes, regardless of heap growth, go will still force a garbage collection.

We figured we could tune the garbage collector to happen more often in order to prevent large spikes, so we implemented an endpoint on the service to change the garbage collector [GC Percent](https://golang.org/pkg/runtime/debug/#SetGCPercent) on the fly. Unfortunately, no matter how we configured the GC percent nothing changed. How could that be? It turns out, it was because we were not allocating memory quickly enough for it to force garbage collection to happen more often.

We kept digging and learned the spikes were huge not because of a massive amount of ready-to-free memory, but because the garbage collector needed to scan the entire LRU cache in order to determine if the memory was truly free from references. Thus, we figured a smaller LRU cache would be faster because the garbage collector would have less to scan. So we added another setting to the service to change the size of the LRU cache and changed the architecture to have many partitioned LRU caches per server.

We were right. With the LRU cache smaller, garbage collection resulted in smaller spikes.

Unfortunately, the trade off of making the LRU cache smaller resulted in higher 99th latency times. This is because if the cache is smaller it’s less likely for a user’s Read State to be in the cache. If it’s not in the cache then we have to do a database load.

After a significant amount of load testing different cache capacities, we found a setting that seemed okay. Not completely satisfied, but satisfied enough and with bigger fish to fry, we left the service running like this for quite some time.

During that time we were seeing more and more success with Rust in other parts of Discord and we collectively decided we wanted to create the frameworks and libraries needed to build new services fully in Rust. This service was a great candidate to port to Rust since it was small and self-contained, but we also hoped that Rust would fix these latency spikes. So we took on the task of porting Read States to Rust, hoping to prove out Rust as a service language and improve the user experience.²

### Memory management in Rust

> Rust is blazingly fast and memory-efficient: **with no runtime or garbage collector**, it can power performance-critical services, run on embedded devices, and easily integrate with other languages.³

Rust does not have garbage collection, so we figured it would not have the same latency spikes Go had.

Rust uses a relatively unique memory management approach that incorporates the idea of memory “ownership”. Basically, Rust keeps track of who can read and write to memory. It knows when the program is using memory and immediately frees the memory once it is no longer needed. It enforces memory rules at compile time, making it virtually impossible to have runtime memory bugs.⁴ You do not need to manually keep track of memory. The compiler takes care of it.

So in the Rust version of the Read States service, when a user’s Read State is evicted from the LRU cache it is immediately freed from memory. The read state memory does not sit around waiting for the garbage collector to collect it. Rust knows it’s no longer in use and frees it immediately. There is no runtime process to determine if it should be freed.

### Async Rust

But there was a problem with the Rust ecosystem. At the time this service was reimplemented, Rust stable did not have a very good story for asynchronous Rust. For a networked service, asynchronous programming is a requirement. There were a few community libraries that enabled asynchronous Rust, but they required a significant amount of ceremony and the error messages were extremely obtuse.

Fortunately, the Rust team was hard at work on making asynchronous programming easy, and it was available in the unstable nightly channel of Rust.

Discord has never been afraid of embracing new technologies that look promising. For example, we were early adopters of Elixir, React, React Native, and Scylla. If a piece of technology is promising and gives us an advantage, we do not mind dealing with the inherent difficulties and instability of the bleeding edge. This is one of the ways we’ve quickly reached 250+ million users with less than 50 engineers.

Embracing the new async features in Rust nightly is another example of our willingness to embrace new, promising technology. As an engineering team, we decided it was worth using nightly Rust and we committed to running on nightly until async was fully supported on stable. Together we dealt with any problems that arose and at this point Rust stable supports asynchronous Rust.⁵ The bet paid off.

### Implementation, load testing, and launch

The actual rewrite was fairly straight forward. It started as a rough translation, then we slimmed it down where it made sense. For instance, Rust has a great type system with extensive support for generics, so we could throw out Go code that existed simply due to lack of generics. Also, Rust’s memory model is able to reason about memory safety across threads, so we were able to throw away some of the manual cross-goroutine memory protection that was required in Go.

When we started load testing, we were instantly pleased with the results. The latency of the Rust version was just as good as Go’s and **had no latency spikes!**

Remarkably, we had only put very basic thought into optimization as the Rust version was written. **Even with just basic optimization, Rust was able to outperform the hyper hand-tuned Go version.** This is a huge testament to how easy it is to write efficient programs with Rust compared to the deep dive we had to do with Go.

But we weren’t satisfied with simply matching Go’s performance. After a bit of profiling and performance optimizations, **we were able to beat Go on every single performance metric**. Latency, CPU, and memory were all better in the Rust version.

The Rust performance optimizations included:

1.  Changing to a BTreeMap instead of a HashMap in the LRU cache to optimize memory usage.
2.  Swapping out the initial metrics library for one that used modern Rust concurrency.
3.  Reducing the number of memory copies we were doing.

Satisfied, we decided to roll out the service.

The launch was fairly seamless because we load tested. We put it out to a single canary node, found a few edge cases that were missing, and fixed them. Soon after that we rolled it out to the entire fleet.

Below are the results.

Go is purple, Rust is blue.

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/611ed6f4b2a3766fbb9964c1_1*-q1B4t622mnxoV8kvT9RwA.png)

### Raising the cache capacity

After the service ran successfully for a few days, we decided it was time to re-raise the LRU cache capacity. In the Go version, as mentioned above, raising the cap of the LRU cache resulted in longer garbage collections. We no longer had to deal with garbage collection, so we figured we could raise the cap of the cache and get even better performance. We increased the memory capacity for the boxes, optimized the data structure to use even less memory (for fun), and increased the cache capacity to 8 million Read States.

The results below speak for themselves. **Notice the average time is now measured in microseconds and max @mention is measured in milliseconds.**

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/611ed6f470390c9ef1cd8fc7_1*DkLOxc-PzkqgXUj_nnOPpA.png)

### Evolving ecosystem

Finally, another great thing about Rust is that it has a quickly evolving ecosystem. Recently, tokio (the async runtime we use) released version 0.2. We upgraded and it gave us CPU benefits for free. Below you can see the CPU is consistently lower starting around the 16th.

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/611ed6f4ff765c21c3ea810b_1*eT1PAnwaAcfCUikJ281v2g.png)

### Closing thoughts

At this point, Discord is using Rust in many places across its software stack. We use it for the game SDK, video capturing and encoding for Go Live, [Elixir NIFs](https://blog.discordapp.com/using-rust-to-scale-elixir-for-11-million-concurrent-users-c6f19fc029d3), several backend services, and more.

When starting a new project or software component, we consider using Rust. Of course, we only use it where it makes sense.

Along with performance, Rust has many advantages for an engineering team. For example, its type safety and borrow checker make it very easy to refactor code as product requirements change or new learnings about the language are discovered. Also, the ecosystem and tooling are excellent and have a significant amount of momentum behind them.

If you made it this far, you’re probably newly excited about Rust or have been excited for quite some time. If you want to work on interesting problems using Rust professionally, you should consider working here at Discord.

Also, a fun fact: the Rust team uses Discord to coordinate. There’s even a very helpful Rust community server that you can find us chatting in from time to time. [Click here to check it out.](https://discord.gg/tcbkpyQ)

\[1\] Go version 1.9.2. Edit: Graphs are from 1.9.2. We tried versions 1.8, 1.9, and 1.10 without any improvement. The initial port from Go to Rust was completed in May 2019.

\[2\] To be clear, we don’t think you should rewrite everything in rust just because.

\[3\] Quote from [https://www.rust-lang.org/](https://www.rust-lang.org/)

\[4\] Unless, of course, you use **unsafe**.

\[5\] [https://areweasyncyet.rs/](https://areweasyncyet.rs/)

Tags

No items found.

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/61241fc9e69b8b98583c89f8_1_tNrZL0th3ePB5oiniU6Ryg.png)

Jesse Howarth

Staff Software Engineer, Infrastructure

## related articles

[](/blog/making-content-from-discoverable-servers-easier-to-discover)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6ad92479d769414a9fb9c916_bloghero_1800x720.png)

Product & Features

### Making Content from Discoverable Servers Easier to Discover

[](/blog/discord-update-october-22-2026)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6ad671da39208567c405c1f9_654409dbbf40922256139a9a_Fall_October.png)

Product & Features

### Discord Update: October 22, 2026

[](/blog/discord-patch-notes-october-6-2026)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/683a385e31ae16bd173ee8d9_image2.png)

Product & Features

### Discord Patch Notes: October 6, 2026

[](/blog/halloween-2026)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6abd7a1923e7e893b8cecd7d_image4.png)

Product & Features

### Cauldron Bubble w/o the Trouble? It’s Discord Halloween, Witches

[](/blog/discord-update-september-25-2026)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/66ecb1eaa5561774cf2c00d5_650233ad5dcf4b6825522e09_Fall_September.png)

Product & Features

### Discord Update: September 25, 2026

[](/blog/adding-the-discord-updates-you-want-to-see)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6aa986373f113ee272c4c1c8_image4.png)

Product & Features

### Adding the Discord Updates YOU Want to See

[](/blog/discord-patch-notes-september-8-2026)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/683a385e31ae16bd173ee8d9_image2.png)

Product & Features

### Discord Patch Notes: September 8, 2026

[](/blog/link-world-of-warcraft-with-discord)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6a7a5b99beaeb69ba2e79997_image6.png)

Product & Features

### Link Discord and WoW to Keep the Guild Chatting Wherever You Are

[](/blog/discord-update-august-11-2026-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6360419dba12275999ef0eee_Summer_August.png)

Product & Features

### Discord Update: August 11, 2026 Changelog

[](/blog/discord-patch-notes-august-4-2026)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/683a385e31ae16bd173ee8d9_image2.png)

Product & Features

### Discord Patch Notes: August 4, 2026

[](/blog/improving-mobile-with-squircles-styles-and-spacing)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6a70ce2458ab09e58b7d5218_Blog%20Hero%20-%201800x720%20-%201x.png)

Product & Features

### Squircles, Styles, and Spacing: How Your Feedback is Helping Improve Mobile

[](/blog/introducing-profile-frames-decorative-borders-to-make-your-discord-profile-museum-worthy)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6a61726c3c4f3808daa86917_Blog%20Header%20-%201800x720.png)

Product & Features

### Introducing Profile Frames: Decorative Borders to Make Your Discord Profile Museum-Worthy

[](/blog/discord-patch-notes-july-7-2026)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/683a385e31ae16bd173ee8d9_image2.png)

Product & Features

### Discord Patch Notes: July 7, 2026

[](/blog/discord-is-now-on-meta-quest-reach-out-to-your-servers-while-in-vr)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6a42fb78addf50b41deb42cf_image2.png)

Product & Features

### Discord is Now on Meta Quest: Reach Out to Your Servers While in VR

[](/blog/discord-update-june-25-2026-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6494b1e02e40699d67a766e6_Summer_June.png)

Product & Features

### Discord Update: June 25, 2026 Changelog

[](/blog/you-bar)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6a2332d69dbeedfe7d0cbc92_image4.jpg)

Product & Features

### Introducing: You Bar

[](/blog/discord-patch-notes-june-4-2026)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/683a385e31ae16bd173ee8d9_image2.png)

Product & Features

### Discord Patch Notes: June 4, 2026

[](/blog/official-discord-integrations-for-steal-a-brainrot-grow-a-garden-brookhaven-rp-and-more)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6a17a67a014ad9969c3caf1e_image4.png)

Product & Features

### Official Discord Integrations for Steal a Brainrot, Grow a Garden, Brookhaven RP, and more

[](/blog/making-it-easier-than-ever-to-connect-with-friends-in-league-val)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6a0f41117da8d7b799ea1a1b_Riot-Integration-blog-gameart-centercrop-1800x720.png)

Product & Features

### Making It Easier Than Ever to Connect with Friends in League & VAL!

[](/blog/every-voice-and-video-call-on-discord-is-now-end-to-end-encrypted)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6a025bd747acaa792ad3ddad_image1.png)

Product & Features

### Every Voice and Video Call on Discord Is Now End-to-End Encrypted

[](/blog/nitro-rewards)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/69fb944c4e112d34c82f95b7_Blog_Banner.png)

Product & Features

### Nitro Now Comes with Xbox Game Pass and New Benefits. Welcome to Nitro Rewards.

[](/blog/rust-shop-on-discord-launch-sale)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/69fb913580d2452bfe2fd43a_RUST-Shop-blog-1800x720.png)

Product & Features

### Stock Up in the New Rust Shop! Enjoy a Discord-Only 20% Sale on Most Items until 5/21

[](/blog/discord-patch-notes-april-6-2026)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/683a385e31ae16bd173ee8d9_image2.png)

Product & Features

### Discord Patch Notes: April 6, 2026

[](/blog/discord-update-march-24-2026-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/65e0d5d41a1beac596a12aaa_March%20Changelog%20Headers.png)

Product & Features

### Discord Update: March 24, 2026 Changelog

[](/blog/discord-patch-notes-march-6-2026)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/683a385e31ae16bd173ee8d9_image2.png)

Product & Features

### Discord Patch Notes: March 6, 2026

[](/blog/bring-your-vibe-to-discord-with-new-themes-in-nitro)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/64121f8765e921a28f9a2b54_Discord%20HQ%20-%202.png)

Product & Features

### How to Change Your Theme to Bring Your Vibe to Discord

[](/blog/discord-patch-notes-february-4-2026)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/683a385e31ae16bd173ee8d9_image2.png)

Product & Features

### Discord Patch Notes: February 4, 2026

[](/blog/gift-ideas-for-the-discord-user)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/69370de739d6d3c5ec3739da_NitroHoliday_BlogHeader_Final_V2%20(1).png)

Product & Features

### Gift Ideas for the Dedicated Discord User in Your Life

[](/blog/checkpoint-2025-discord-year-in-review)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/692f703325021d1d0a33f1eb_BlogBanner_1800x720%20(1).png)

Product & Features

### Your Discord Checkpoint is Rolling Out! Celebrate What You Did in 2025

[](/blog/save-and-display-your-faves-add-discord-shop-marvel-rivals-items-to-your-profiles-wishlist)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6927808f2b033db8af5e4b59_Wishlist_Banner__MarvelRivals-Shop-1800x720.png)

Product & Features

### Save and Display Your Faves: Add Discord Shop & Marvel Rivals Items to Your Profile’s Wishlist

[](/blog/bringing-in-game-commerce-to-discord-communities)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/692616af8e8bab216f88af70_MarvelRivals-Shop-hero-BLOG-1800x720.png)

Product & Features

### Bringing In-Game Commerce to Discord Communities

[](/blog/discord-update-november-6-2025-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/636042835883b97b259ef618_Fall_November.png)

Product & Features

### Discord Update: November 6, 2025 Changelog

[](/blog/a-cornucopia-of-updates-make-discord-on-desktop-fresher-than-a-crisp-fall-breeze)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/690bd1527f131ae7862bbc5b_image11.png)

Product & Features

### A Cornucopia of Updates Make Discord on Desktop Fresher Than a Crisp Fall Breeze

[](/blog/discord-patch-notes-november-4-2025)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/683a385e31ae16bd173ee8d9_image2.png)

Product & Features

### Discord Patch Notes: November 4, 2025

[](/blog/discord-patch-notes-october-7-2025)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/683a385e31ae16bd173ee8d9_image2.png)

Product & Features

### Discord Patch Notes: October 7, 2025

[](/blog/discord-update-september-25-2025-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/66ecb1eaa5561774cf2c00d5_650233ad5dcf4b6825522e09_Fall_September.png)

Product & Features

### Discord Update: September 25, 2025 Changelog

[](/blog/new-looks-for-nitro-new-looks-for-you-get-yourself-a-nitro-exclusive-profile-bundle)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/68cdfa532b6b7b634417c4dd_Final%20Blog%20Banner-.png)

Product & Features

### New Looks for Nitro, New Looks for You. Get Yourself a Nitro-exclusive Profile Bundle!

[](/blog/transforming-game-discovery-with-instant-play-experiences-on-discord)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/689f7cdf79694c891764399a_GCDC_NvidiaLogoLockUp_Blog.png)

Product & Features

### Transforming Game Discovery with Instant Play Experiences on Discord

[](/blog/discord-orbs)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/687185569dd0ac147ad89a64_image5.jpg)

Product & Features

### Reward Your Play: Complete Quests. Earn Orbs. Get Sweet Stuff.

[](/blog/discord-update-june-30-2025-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6494b1e02e40699d67a766e6_Summer_June.png)

Product & Features

### Discord Update: June 30, 2025 Changelog

[](/blog/get-more-from-your-boosts-with-new-server-perks)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/684a07a2968307ee558f19dd_image5.png)

Product & Features

### Get More From Your Boosts With New Server Perks

[](/blog/gift-nitro-and-earn-a-flavorful-splash-for-your-avatar)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/684a0b131c3be3d6f58e5fe9_image3.png)

Product & Features

### Gift Nitro and Earn A Flavorful Splash for your Avatar

[](/blog/discord-social-sdk-updates-integrations)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/683a1be02c321cc94c5ad745_image7.png)

Product & Features

### Discord Social SDK Updates & Integrations

[](/blog/discord-patch-notes-june-3-2025)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/683a385e31ae16bd173ee8d9_image2.png)

Product & Features

### Discord Patch Notes: June 3, 2025

[](/blog/go-beyond-plus-ultra-with-the-my-hero-academia-collection)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6825245fd44e60c25bfd350c_image4.png)

Product & Features

### Go Beyond, Plus Ultra! with the My Hero Academia Collection

[](/blog/star-wars-makes-its-way-to-discord)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/68128a3b85b6f59abff99f3d_StarWars_BLOG%20BANNER%20720.jpg)

Product & Features

### STAR WARS™ Makes Its Way to Discord

[](/blog/discord-patch-notes-may-1-2025)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6657ad0a58988c5decbfbc53_Header_3.png)

Product & Features

### Discord Patch Notes: May 1, 2025

[](/blog/nameplates-land-in-the-shop)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6801703e88ed1f8cb5d6e459_(DMKT05-NP)Nameplates_BlogBanner_AB_FINAL_V1.png)

Product & Features

### Worthy of a Plaque: Nameplates Land in the Shop

[](/blog/nitro-members-keep-quest-rewards-longer)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/67f83b2996e977048a0bc26e_image1.png)

Product & Features

### Make More Closet Space! Nitro Members Can Now Keep Avatar Decoration Quest Rewards for Longer

[](/blog/discord-patch-notes-april-3-2025)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6657ad0a58988c5decbfbc53_Header_3.png)

Product & Features

### Discord Patch Notes: April 3, 2025

[](/blog/discord-update-march-25-2025-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/65e0d5d41a1beac596a12aaa_March%20Changelog%20Headers.png)

Product & Features

### Discord Update: March 25, 2025 Changelog

[](/blog/player-release-q12025)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/67e1a71360e0b28ee369fc83_(DMKT08-PQ1)_Blog_Banner_Static_Final_1800x720.png)

Product & Features

### Revamped Overlay & Refreshed Desktop Give Game Time a Boost

[](/blog/discord-patch-notes-march-11-2025)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6657ad0a58988c5decbfbc53_Header_3.png)

Product & Features

### Discord Patch Notes: March 11, 2025

[](/blog/discord-patch-notes-february-3-2025)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6657ad0a58988c5decbfbc53_Header_3.png)

Product & Features

### Discord Patch Notes: February 3, 2025

[](/blog/discord-update-december-19-2024-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/657a71a24b4bc2f1879762ea_Winter_December.png)

Product & Features

### Discord Update: December 19, 2024 Changelog

[](/blog/discord-patch-notes-december-5-2024)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6657ad0a58988c5decbfbc53_Header_3.png)

Product & Features

### Discord Patch Notes: December 5, 2024

[](/blog/discord-update-november-18-2024-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/636042835883b97b259ef618_Fall_November.png)

Product & Features

### Discord Update: November 18, 2024 Changelog

[](/blog/arcane-shop-collection)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/672e95661de7c16c8d8f7417_image2.png)

Product & Features

### Celebrate Arcane’s Second Season with a new Shop Collection

[](/blog/discord-patch-notes-november-1-2024)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6657ad0a58988c5decbfbc53_Header_3.png)

Product & Features

### Discord Patch Notes: November 1, 2024

[](/blog/discord-roll20-adventure-and-dnd-shop-collection)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/670ef8932fc56d10786649dd_(CCD_17_D%26D)_MKT_01_Blog%20Banner_Full.jpg)

Product & Features

### Set Out for a Discord Adventure! Check Out Our Roll20 Adventure & D&D Shop Collection

[](/blog/discord-patch-notes-october-1-2024)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6657ad0a58988c5decbfbc53_Header_3.png)

Product & Features

### Discord Patch Notes: October 1, 2024

[](/blog/discord-update-september-26-2024-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/66ecb1eaa5561774cf2c00d5_650233ad5dcf4b6825522e09_Fall_September.png)

Product & Features

### Discord Update: September 26, 2024 Changelog

[](/blog/discover-more-ways-to-play-with-apps-now-anywhere-on-discord)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/66e9ed278d78eb7c65473d11_image10.png)

Product & Features

### Discover More Ways to Play with Apps – Now Anywhere on Discord!

[](/blog/legacy-shop-favorites-emerge-from-the-vault-for-a-first-anniversary-encore)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/66d8cb358a1c941cb416372c_Blog%20Banner%20Styleframe.jpg)

Product & Features

### Legacy Shop Favorites Emerge from The Vault for a First Anniversary Encore!

[](/blog/discord-patch-notes-august-30-2024)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6657ad0a58988c5decbfbc53_Header_3.png)

Product & Features

### Discord Patch Notes: August 30, 2024

[](/blog/discord-update-august-28-2024-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6360419dba12275999ef0eee_Summer_August.png)

Product & Features

### Discord Update: August 28, 2024 Changelog

[](/blog/amazon-music-activity)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/66bf8f185b919e6dbac816c4_image1.png)

Product & Features

### Queue Up Your Playlists on Discord with the Amazon Music Listening Party Activity!

[](/blog/discord-patch-notes-august-1-2024)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6657ad0a58988c5decbfbc53_Header_3.png)

Product & Features

### Discord Patch Notes: August 1, 2024

[](/blog/see-whats-happening-on-discord-directly-from-your-xbox)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/62d0746010f70706d1341f68_image3.png)

Product & Features

### Now Available: See What’s Happening on Discord, Directly from your Xbox console

[](/blog/discord-update-july-26-2024-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/64c7e8751b517e9cc56a5238_Summer_July.png)

Product & Features

### Discord Update: July 26, 2024 Changelog

[](/blog/spongebob-shop-collection)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6691b8a2e59e9c4657d56d27_SpongeBob_Banner_blog%20header%201_B.png)

Product & Features

### WHO LIVES ON YOUR PROFILE FOR ALL TO SEE? 🎶 SPONGEBOB, IN THE SHOP!

[](/blog/discord-patch-notes-july-1-2024)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6657ad0a58988c5decbfbc53_Header_3.png)

Product & Features

### Discord Patch Notes: July 1, 2024

[](/blog/discord-update-june-20-2024-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6494b1e02e40699d67a766e6_Summer_June.png)

Product & Features

### Discord Update: June 20, 2024 Changelog

[](/blog/join-discord-calls-directly-from-ps5-no-phone-needed)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/666788d74e610cffdd4e4808_image1.jpg)

Product & Features

### How to Join Discord Calls Directly From Your PS5® — No Phone Needed!

[](/blog/feast-your-moniteyes-on-todays-exciting-developer-updates)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6660a79090f7f35de8735e0e_image2.png)

Product & Features

### Feast Your Monit-eyes on Today's Exciting Developer Updates!

[](/blog/discord-patch-notes-may-2024)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6657ad0a58988c5decbfbc53_Header_3.png)

Product & Features

### Discord Patch Notes: May 2024

[](/blog/refining-discords-mobile-experience-with-your-feedback)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/664ce605c29e6a3266d6ef95_image3.png)

Product & Features

### Refining Discord’s Mobile Experience With Your Feedback

[](/blog/discord-update-may-13-2024-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/646d3dfadaf245263be22231_Spring_May.png)

Product & Features

### Discord Update: May 13, 2024 Changelog

[](/blog/discord-patch-notes-april-2024)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/66315deb32012c249564aab3_Header_7.png)

Product & Features

### Discord Patch Notes: April 2024

[](/blog/discord-update-april-3-2024-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6441bd561f47091d8174e16c_Spring_April.png)

Product & Features

### Discord Update: April 3, 2024 Changelog

[](/blog/valorant-shop-collection)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6602021256195cd027a3f0b8_VLR_Blog_Header_Banner_1800x720px_V2.png)

Product & Features

### Lock in. Stand out. VALORANT arrives in the Shop.

[](/blog/discord-update-march-5-2024-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/65e0d5d41a1beac596a12aaa_March%20Changelog%20Headers.png)

Product & Features

### Discord Update: March 5, 2024 Changelog

[](/blog/discord-update-december-13-2023-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/657a71a24b4bc2f1879762ea_Winter_December.png)

Product & Features

### Discord Update: December 13, 2023 Changelog

[](/blog/improving-our-mobile-experience)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/656a67621c4ba32e7c3710fc_image14.png)

Product & Features

### Improving Our Mobile Experience

[](/blog/discord-update-october-19-2023-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/654409dbbf40922256139a9a_Fall_October.png)

Product & Features

### Discord Update: October 19, 2023 Changelog

[](/blog/avatar-decorations-collect-and-keep-the-newest-styles)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6514773178cb945e3c97705b_Discord_Collectible_BlogHeader%20Banner_V6_RESIZED.png)

Product & Features

### Avatar Decorations & Profile Effects: Collect and Keep the Newest Styles

[](/blog/discord-update-september-13-2023-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/650233ad5dcf4b6825522e09_Fall_September.png)

Product & Features

### Discord Update: September 13, 2023 Changelog

[](/blog/xbox-stream-to-discord-announcement)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/64f8ce1927fcd30fdfe80a56_23_117_Xbox_Social_1800x720.png)

Product & Features

### Now Available: Stream Your Xbox Games Directly to Discord

[](/blog/discord-update-july-29-2023-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/64c7e8751b517e9cc56a5238_Summer_July.png)

Product & Features

### Discord Update: July 29, 2023 Changelog

[](/blog/meme-up-some-fun-with-remix)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/649e03012c058e734627d965_Remixing-Blog-Header.png)

Product & Features

### Meme Up Some Fun with Remix

[](/blog/discord-update-june-22-2023-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6494b1e02e40699d67a766e6_Summer_June.png)

Product & Features

### Discord Update: June 22, 2023 Changelog

[](/blog/server-subscriptions-updates-media-channels-tier-templates-and-more)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/648cef33984677d825ca2763_PortalArticleHeader_1800x720.png)

Product & Features

### Server Subscriptions Just Got Super Powered: Introducing Media Channels, Tier Templates and more!

[](/blog/discord-update-may-22-2023-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/646d3dfadaf245263be22231_Spring_May.png)

Product & Features

### Discord Update: May 22, 2023 Changelog

[](/blog/usernames)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/645c294e1f5bcda693b9df11_usernames%20blog%20header.png)

Product & Features

### Evolving Usernames on Discord

[](/blog/discord-update-april-14-2023-changelog)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/6441bd561f47091d8174e16c_Spring_April.png)

Product & Features

### Discord Update: April 14, 2023 Changelog

[](/blog/community-onboarding-welcome-your-new-members)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/643d9e196f9a672e57e79b3f_Community%20Onboarding_Blog%20Header_blog%20header.jpg)

Product & Features

### Welcome Your New Members Easily with Community Onboarding

[](/blog/discord-voice-messages)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/64399621c8daafe18d84b451_VoiceMessages_Blog_1800x720%402x.png)

Product & Features

### Introducing Discord Voice Messages

[](/blog/april-showers-bring-super-cool-nitro-powers)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/642ca8066bcbdd2a77f4a702_NAD_NitroBanner_Purple.png)

Product & Features

### April Showers Bring Super-Cool Nitro Powers

[](/blog/super-reactions-make-emoji-burst-to-life-discord-nitro)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/642c93aa534c2922f17a99e7_2023_BurstReactions_Static_BlogHDR_005.png)

Product & Features

### New to Discord Nitro: Super Reactions Make Your Emoji Burst to Life

[](/blog/ready-your-airhorns-discord-soundboard-is-coming)

![](https://cdn.prod.website-files.com/5f9072399b2640f14d6a2bf4/642c8db3a577675a498f6168_BackupBlogHeaders_Batch2Artboard%205.png)

Product & Features

### Ready Your Airhorns! 🎺 Discord Soundboard is Coming Your Way

![](data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjMiIGhlaWdodD0iMjIiIHZpZXdib3g9IjAgMCAyMyAyMiIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHBhdGggZmlsbC1ydWxlPSJldmVub2RkIiBjbGlwLXJ1bGU9ImV2ZW5vZGQiIGQ9Ik0xOS42NDAyIDEyLjY1ODdDMTkuNTAyMSAxMi41NTg3IDE5LjI2OTIgMTIuNTQ2MyAxOS4xMTI2IDEyLjYyNTFDMTYuNDcwMSAxNC4wMyAxMy4xNDE2IDEzLjUzMDcgMTEuMDE5NiAxMS40MDk2QzguODk1IDkuMjg2ODIgOC4zOTMwNiA1Ljk1OTIgOS44MDI0MiAzLjMwNzg4QzkuODg4MjkgMy4xMzUyNiA5Ljg2OTcgMi45MzQzMSA5Ljc1NDYyIDIuNzgyMDVDOS42NDM5MiAyLjYzNzc1IDkuNDA0MDIgMi41NTM2NiA5LjIyNTIgMi42MDVDNS41NzE3OSAzLjY1MDQ3IDMuMDIwNTEgNy4wMzU2NSAzLjAyMDUxIDEwLjgzNzhDMy4wMjA1MSAxNS41NjMyIDYuODYzMzYgMTkuNDA2OSAxMS41ODcxIDE5LjQwNjlDMTUuMzkwMSAxOS40MDY5IDE4Ljc3NjIgMTYuODUwNCAxOS44MjE2IDEzLjE4OTlDMTkuODcyMSAxMy4wMTEgMTkuNzg4OSAxMi43Njg1IDE5LjY0MDIgMTIuNjU4N1oiIGZpbGw9IkN1cnJlbnRjb2xvciIgLz4KPC9zdmc+)

![](data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjMiIGhlaWdodD0iMjIiIHZpZXdib3g9IjAgMCAyMyAyMiIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHBhdGggZmlsbC1ydWxlPSJldmVub2RkIiBjbGlwLXJ1bGU9ImV2ZW5vZGQiIGQ9Ik01Ljk4NDc4IDYuNjk4MTlDNi4xMTQwMiA2LjgyNzQ0IDYuMjg0ODcgNi44OTIwNiA2LjQ1Mzk1IDYuODkyMDZDNi42MjQ4IDYuODkyMDYgNi43OTM4OSA2LjgyNzQ0IDYuOTI0MDIgNi42OTgxOUM3LjE4MzQgNi40Mzc5MyA3LjE4MzQgNi4wMTc0NCA2LjkyNDAyIDUuNzU4MDZMNi4wNjQ0NCA0LjkwMDI2QzUuODA1MDcgNC42NDA4OCA1LjM4NDU3IDQuNjQxNzYgNS4xMjUyIDQuOTAwMjZDNC44NjU4MiA1LjE2MDUyIDQuODY1ODIgNS41ODAxMiA1LjEyNTIgNS44Mzk1TDUuOTg0NzggNi42OTgxOVoiIGZpbGw9IkN1cnJlbnRjb2xvciIgLz4KPHBhdGggZmlsbC1ydWxlPSJldmVub2RkIiBjbGlwLXJ1bGU9ImV2ZW5vZGQiIGQ9Ik0xMS4yMjg0IDQuOTA5OEMxMS41OTQ5IDQuOTA5OCAxMS44OTIzIDQuNjEyMzUgMTEuODkyMyA0LjI0NTg2VjMuMDMzMDhDMTEuODkyMyAyLjY2NjU4IDExLjU5NDkgMi4zNjkxNCAxMS4yMjg0IDIuMzY5MTRDMTAuODYxOSAyLjM2OTE0IDEwLjU2NDUgMi42NjY1OCAxMC41NjQ1IDMuMDMzMDhWNC4yNDU4NkMxMC41NjQ1IDQuNjEyMzUgMTAuODYxOSA0LjkwOTggMTEuMjI4NCA0LjkwOThaIiBmaWxsPSJDdXJyZW50Y29sb3IiIC8+CjxwYXRoIGZpbGwtcnVsZT0iZXZlbm9kZCIgY2xpcC1ydWxlPSJldmVub2RkIiBkPSJNNS4xNDAwOCAxMC45OTk5QzUuMTQwMDggMTAuNjMzNCA0Ljg0MjY0IDEwLjMzNTkgNC40NzYxNSAxMC4zMzU5SDMuMjYxNTlDMi44OTUxIDEwLjMzNTkgMi41OTc2NiAxMC42MzM0IDIuNTk3NjYgMTAuOTk5OUMyLjU5NzY2IDExLjM2NjQgMi44OTUxIDExLjY2MzggMy4yNjE1OSAxMS42NjM4SDQuNDc2MTVDNC44NDI2NCAxMS42NjM4IDUuMTQwMDggMTEuMzY2NCA1LjE0MDA4IDEwLjk5OTlaIiBmaWxsPSJDdXJyZW50Y29sb3IiIC8+CjxwYXRoIGZpbGwtcnVsZT0iZXZlbm9kZCIgY2xpcC1ydWxlPSJldmVub2RkIiBkPSJNMTYuMDA0NSA2Ljg5MjA2QzE2LjE3MzYgNi44OTIwNiAxNi4zNDQ1IDYuODI3NDQgMTYuNDczNyA2LjY5ODE5TDE3LjMzMzMgNS44Mzk1QzE3LjU5MjcgNS41ODAxMiAxNy41OTI3IDUuMTU5NjMgMTcuMzMzMyA0LjkwMDI2QzE3LjA3MzkgNC42NDE3NiAxNi42NTM0IDQuNjQwODggMTYuMzk0IDQuOTAwMjZMMTUuNTM1NCA1Ljc1ODA2QzE1LjI3NiA2LjAxNzQ0IDE1LjI3NiA2LjQzNzkzIDE1LjUzNTQgNi42OTczQzE1LjY2NDYgNi44Mjc0NCAxNS44MzQ2IDYuODkyMDYgMTYuMDA0NSA2Ljg5MjA2WiIgZmlsbD0iQ3VycmVudGNvbG9yIiAvPgo8cGF0aCBmaWxsLXJ1bGU9ImV2ZW5vZGQiIGNsaXAtcnVsZT0iZXZlbm9kZCIgZD0iTTE2LjQ3MTcgMTUuMzAxM0MxNi4yMTE0IDE1LjA0MjggMTUuNzkwOSAxNS4wNDI4IDE1LjUzMjQgMTUuMzAxM0MxNS4yNzMgMTUuNTYxNiAxNS4yNzMgMTUuOTgyIDE1LjUzMjQgMTYuMjQxNEwxNi4zOTIgMTcuMDk5MkMxNi41MjIxIDE3LjIyODUgMTYuNjkyMSAxNy4yOTMxIDE2Ljg2MTIgMTcuMjkzMUMxNy4wMzIgMTcuMjkzMSAxNy4yMDExIDE3LjIyODUgMTcuMzMxMiAxNy4wOTkyQzE3LjU5MDYgMTYuODM5IDE3LjU5MDYgMTYuNDE5NCAxNy4zMzEyIDE2LjE2TDE2LjQ3MTcgMTUuMzAxM1oiIGZpbGw9IkN1cnJlbnRjb2xvciIgLz4KPHBhdGggZmlsbC1ydWxlPSJldmVub2RkIiBjbGlwLXJ1bGU9ImV2ZW5vZGQiIGQ9Ik01Ljk4NDc4IDE1LjMwMTNMNS4xMjUyIDE2LjE2QzQuODY1ODIgMTYuNDE5NCA0Ljg2NTgyIDE2LjgzOSA1LjEyNTIgMTcuMDk5MkM1LjI1NTMzIDE3LjIyODUgNS40MjQ0MSAxNy4yOTMxIDUuNTk1MjcgMTcuMjkzMUM1Ljc2NDM0IDE3LjI5MzEgNS45MzQzMSAxNy4yMjg1IDYuMDY0NDQgMTcuMDk5Mkw2LjkyNDAyIDE2LjI0MTRDNy4xODM0IDE1Ljk4MiA3LjE4MzQgMTUuNTYxNiA2LjkyNDAyIDE1LjMwMTNDNi42NjU1MyAxNS4wNDI4IDYuMjQ1MDQgMTUuMDQyOCA1Ljk4NDc4IDE1LjMwMTNaIiBmaWxsPSJDdXJyZW50Y29sb3IiIC8+CjxwYXRoIGZpbGwtcnVsZT0iZXZlbm9kZCIgY2xpcC1ydWxlPSJldmVub2RkIiBkPSJNMTkuMTkyOSAxMC4zMzU5SDE3Ljk3ODRDMTcuNjExOSAxMC4zMzU5IDE3LjMxNDUgMTAuNjMzNCAxNy4zMTQ1IDEwLjk5OTlDMTcuMzE0NSAxMS4zNjY0IDE3LjYxMTkgMTEuNjYzOCAxNy45Nzg0IDExLjY2MzhIMTkuMTkyOUMxOS41NTk0IDExLjY2MzggMTkuODU2OSAxMS4zNjY0IDE5Ljg1NjkgMTAuOTk5OUMxOS44NTY5IDEwLjYzMzQgMTkuNTU5NCAxMC4zMzU5IDE5LjE5MjkgMTAuMzM1OVoiIGZpbGw9IkN1cnJlbnRjb2xvciIgLz4KPHBhdGggZmlsbC1ydWxlPSJldmVub2RkIiBjbGlwLXJ1bGU9ImV2ZW5vZGQiIGQ9Ik0xMS4yMjg0IDE3LjA4OThDMTAuODYxOSAxNy4wODk4IDEwLjU2NDUgMTcuMzg3MyAxMC41NjQ1IDE3Ljc1MzhWMTguOTY2NkMxMC41NjQ1IDE5LjMzMzEgMTAuODYxOSAxOS42MzA1IDExLjIyODQgMTkuNjMwNUMxMS41OTQ5IDE5LjYzMDUgMTEuODkyMyAxOS4zMzMxIDExLjg5MjMgMTguOTY2NlYxNy43NTM4QzExLjg5MjMgMTcuMzg3MyAxMS41OTQ5IDE3LjA4OTggMTEuMjI4NCAxNy4wODk4WiIgZmlsbD0iQ3VycmVudGNvbG9yIiAvPgo8cGF0aCBmaWxsLXJ1bGU9ImV2ZW5vZGQiIGNsaXAtcnVsZT0iZXZlbm9kZCIgZD0iTTExLjIyNTYgNi44Mzg4N0M4LjkzMzY2IDYuODM4ODcgNy4wNjkzNCA4LjcwNDk2IDcuMDY5MzQgMTAuOTk5NUM3LjA2OTM0IDEzLjI5NDEgOC45MzM2NiAxNS4xNjAyIDExLjIyNTYgMTUuMTYwMkMxMy41MTg0IDE1LjE2MDIgMTUuMzgyNyAxMy4yOTQxIDE1LjM4MjcgMTAuOTk5NUMxNS4zODI3IDguNzA0OTYgMTMuNTE4NCA2LjgzODg3IDExLjIyNTYgNi44Mzg4N1oiIGZpbGw9IkN1cnJlbnRjb2xvciIgLz4KPC9zdmc+)

.

[Why Discord is switching from Go to Rust](#)[](#2)[](#3)[](#4)[](#5)[](#6)[](#7)[](#8)[](#9)[](#10)

![](data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjQiIGhlaWdodD0iMjQiIHZpZXdib3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHBhdGggZD0iTTE4IDlMMTIgMTVMNiA5IiBzdHJva2U9ImN1cnJlbnRjb2xvciIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiIC8+Cjwvc3ZnPg==)

[](#1)

Why Discord is switching from Go to Rust

[](#2)

[](#3)

[](#4)

[](#5)

[](#6)

[](#7)

[](#8)

[](#9)

[](#10)

![](data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjQiIGhlaWdodD0iMjQiIHZpZXdib3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHBhdGggZD0iTTE0LjUgMThMOC41IDEyTDE0LjUgNiIgc3Ryb2tlPSJjdXJyZW50Y29sb3IiIHN0cm9rZS13aWR0aD0iMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIiAvPgo8L3N2Zz4=)

![](data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjUiIGhlaWdodD0iMjQiIHZpZXdib3g9IjAgMCAyNSAyNCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHBhdGggZmlsbC1ydWxlPSJldmVub2RkIiBjbGlwLXJ1bGU9ImV2ZW5vZGQiIGQ9Ik0xMS44Mzk4IDE2QzkuMDc4NDIgMTYgNi44Mzk4NCAxMy43NjE0IDYuODM5ODQgMTFDNi44Mzk4NCA4LjIzODU4IDkuMDc4NDIgNiAxMS44Mzk4IDZDMTQuNjAxMiA2IDE2LjgzOTggOC4yMzg1OCAxNi44Mzk4IDExQzE2LjgzOTggMTMuNzYxNCAxNC42MDEyIDE2IDExLjgzOTggMTZaTTQuODM5ODQgMTFDNC44Mzk4NCA3LjEzNDAxIDcuOTczODUgNCAxMS44Mzk4IDRDMTUuNzA1OCA0IDE4LjgzOTggNy4xMzQwMSAxOC44Mzk4IDExQzE4LjgzOTggMTIuNTcyMyAxOC4zMjE0IDE0LjAyMzYgMTcuNDQ2MiAxNS4xOTIyTDIwLjU0NjkgMTguMjkyOUMyMC45Mzc0IDE4LjY4MzQgMjAuOTM3NCAxOS4zMTY2IDIwLjU0NjkgMTkuNzA3MUMyMC4xNTY0IDIwLjA5NzYgMTkuNTIzMiAyMC4wOTc2IDE5LjEzMjcgMTkuNzA3MUwxNi4wMzIgMTYuNjA2NEMxNC44NjM0IDE3LjQ4MTYgMTMuNDEyMSAxOCAxMS44Mzk4IDE4QzcuOTczODUgMTggNC44Mzk4NCAxNC44NjYgNC44Mzk4NCAxMVoiIGZpbGw9ImN1cnJlbnRjb2xvciIgLz4KPC9zdmc+)

Search

[![Discord Home](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119f90b32c4c283f68ec_50421399b7d807a39b976375b8b2f21e_Symbol.svg)](/)

Language

English (US)

![](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119f90b32c4c283f68fd_13b796631a0178df3105d55d1d629706_Chevron%20Down.svg)

- Čeština

- Dansk

- Deutsch

- English

- English (UK)

- Español

- Español (América Latina)

- Français

- Hrvatski

- Italiano

- lietuvių kalba

- Magyar

- Nederlands

- Norsk

- Polski

- Português (Brasil)

- Română

- Suomi

- Svenska

- Tiếng Việt

- Türkçe

- Ελληνικά

- български

- Русский

- Українська

- हिंदी

- ไทย

- 한국어

- 中文

- 中文(繁體)

- 日本語

Social

[![Twitter](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119e90b32c4c283f6891_91ce5945e0716b8f27aba591ed3ce824_x.svg)](https://twitter.com/discord)[![Instagram](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119e90b32c4c283f68a1_456a1737b263ca0ec63b760ac332ed2a_instagram.svg)](https://www.instagram.com/discord/)[![Facebook](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119e90b32c4c283f68b5_a77cbd313cca7494393b7a8ccc20fa16_facebook.svg)](https://www.facebook.com/discord/)[![Youtube](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119e90b32c4c283f68c9_341e1594d600b55ff2302e0169b321ce_youtube.svg)](https://www.youtube.com/discord)[![Tiktok](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119e90b32c4c283f68d2_1b8105cd54e8b765ed7c14cd03b13ffc_tiktok.svg)](https://www.tiktok.com/@discord)

Menu

### Product

Product

![](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119f90b32c4c283f6915_0de9af0fe90fba53b80f020909344da6_Chevron%20Down.svg)

[Download](/download)[Nitro](/nitro)[Status](https://discordstatus.com/)[App Directory](/application-directory)[Gift Cards](/gift-cards)

### Company

Company

![](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119f90b32c4c283f6915_0de9af0fe90fba53b80f020909344da6_Chevron%20Down.svg)

[About](/company)[Jobs](/careers)[Brand](/branding)[Newsroom](/newsroom)

### Resources

Resources

![](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119f90b32c4c283f6915_0de9af0fe90fba53b80f020909344da6_Chevron%20Down.svg)

[Support](https://support.discord.com/hc)[Safety](/safety)[Blog](/blog)[Creators](/creators)[Community](/community)[Developers](/developers)[Quests](/ads/quests)[Official 3rd Party Merch](https://discordmerch.com/evergreenfooter)[Feedback](https://support.discord.com/hc/requests/new?brand_id=96508&ticket_form_id=34826052965399)

### Policies

Policies

![](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119f90b32c4c283f6915_0de9af0fe90fba53b80f020909344da6_Chevron%20Down.svg)

[Terms](/terms)[Privacy](/privacy)[Cookie Settings](#)[Guidelines](/guidelines)[Acknowledgements](/acknowledgements)[Licenses](/licenses)[Company Information](/company-information)

Social

[![Twitter](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119e90b32c4c283f6891_91ce5945e0716b8f27aba591ed3ce824_x.svg)](https://x.com/discord)[![Instagram](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119e90b32c4c283f68a1_456a1737b263ca0ec63b760ac332ed2a_instagram.svg)](https://www.instagram.com/discord/)[![Facebook](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119e90b32c4c283f68b5_a77cbd313cca7494393b7a8ccc20fa16_facebook.svg)](https://www.facebook.com/discord/)[![Youtube](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119e90b32c4c283f68c9_341e1594d600b55ff2302e0169b321ce_youtube.svg)](https://www.youtube.com/discord)[![Tiktok](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/66fd119e90b32c4c283f68d2_1b8105cd54e8b765ed7c14cd03b13ffc_tiktok.svg)](https://www.tiktok.com/@discord)

![Discord](https://cdn.prod.website-files.com/5f8dd67f8fdd6f51f0b50904/67ac9e0891a02325abf50c81_63bbb8d20f0336ebb2218972a83c5eec_Wordmark.svg)
