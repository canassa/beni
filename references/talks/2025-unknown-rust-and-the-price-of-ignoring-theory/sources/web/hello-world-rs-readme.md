---
title: mTvare6/hello-world.rs README
source: https://github.com/mTvare6/hello-world.rs
retrieved: 2026-11-02
---

# 🚀 hello-world.rs 🚀

🚀 Memory safe, blazing fast, minimal and configurable hello world project written in the rust(🚀) programming language 🚀

🚀 While this depends on more c code than rust(🚀) code to compile, because rust(🚀) is magically **memory safe**, now all c code is memory safe too 🚀

🚀 This project is very minimal, it only requires **1247** crates 🚀

### Building

To compile this project you need only one library 🚀:


You probably have most of them already, if it says something along the words, you know what to search for now

Then you can just `make` and the compiled executable should be located in `./target/release/hello-world` run it or install it with `make install`.

Due to the lightweightness of rust(🚀), unlike node_modules being fairly large for few dependencies, rust(🚀) manages compile caches efficiently and stores them to storage to save compile times! Just **37G** target folder on couple of compilation(dev+release), the compile time is only around **2 hours and 30 minutes** on my mac air on release mode

![🚀](/ast/unclean.png)

A clean build makes it take around *4.7G*

![🚀](/ast/clean.png)

The CPU usage is pretty minimal too (release mode)

![🚀](/ast/cpu.png)

It is slower than echo but memory safety comes at a cost! We need to be memory chad and blazing pure and lightning based

![🚀](/ast/lib_benchmark.png)

Benchmark by [cypercine](https://github.com/mTvare6/cypercine)

### Installation

#### Arch Linux

``` sh
$ makepkg -si
$ pacman -U <package>.pkg.tar.xz
```

#### Docker

``` sh
$ docker build -t hello-world .
$ docker run -it --rm --name hwrs hello-world
```

#### Nix

``` sh
$ nix-env -i -f default.nix
```

#### Shade

``` sh
$ wget "https://raw.githubusercontent.com/mTvare6/hello-world.rs/master/hello-world.rs-buildscript" -O <prefix>/user/main/hello-world.rs
$ shade install hello-world.rs
```

### Why rust(🚀) while its only 1 line and depends on 600 c bind crates?

Here are my takes on that matter

> **C** in "c language" stands for **C**ringe and **C**VE and **C**ervical **C**apricious **C**atastrophic **C**hthonic **C**lumsy **C**lueless **C**omplex and **C**ryptic 🤮

> **R** in "rust(🚀) systems programming language" stands for **R**ewrite, **R**obust, **R**eliable, **R**ambunctious, **R**eprehensibl\[ly great\] and **S**ecure🚀

> [Since hello-world.rs is written in blazingly pure, configurable, lightweight and memory pure rust(🚀) - the CVEs are secure, memory chad and blazing pure](https://github.com/mTvare6/hello-world.rs/issues/) 🚀

Here are the comments from few of my fellow Rustaceans 🚀

> People ask the question "what's rust(🚀) good for?" pretty frequently, and little terminal apps like this are precisely the reason. \[...\]. It enables a kind of workflow that simply didn't exist before: I could have a fully safe, "correct", LLVM-optimized binary installed on my desktop in an afternoon.🚀

> Modern rust(🚀) appears pretty similar to modern JavaScript. You declare your variables with let🚀

> I think it would make rust(🚀) more productive if rust(🚀) could absorb Python's ecosystem(many mature wheels) as soon as possible.🚀

> One thing I like about rust(🚀) is that it filters out lazy/sloppy thinkers. Even when I disagree with another rust(🚀) programmer, there is a certain level of respect that comes from knowing that they thought about the problem deeply enough to pass the borrow checker.🚀

> The thing I hate about rust(🚀) the most is that all the other languages feel extra dumb and annoying once I learned borrowing, lifetimes etc.🚀

> "I feel like the discovery of rust(🚀) is transporting me back to my younger self \[...\]" "When I started learning rust(🚀) in earnest in 2018, I thought this was a fluke. It is just the butterflies you get when you think you fall in love, I told myself."🚀

> rust(🚀)’s product is not a programming language or a compiler. rust(🚀)’s product is the experience of being a rust(🚀) developer🚀

> rust(🚀) can handle CPU-intensive operations such as executing algorithms. 🚀

> Because it’s typically typed, rust(🚀) catches errors at compile time. \[...\] Also, it compiles code down to machine learning, allowing for extra efficiency.🚀

> Many people try to compare rust(🚀) to Go, but this is flawed. Go is an ancient board game that emphasizes strategy. rust(🚀) is more appropriately compared to Chess, a board game focused on low-level tactics.🚀

> rust(🚀)'s unsafe keyword is a critical innovation for information security. I believe that Safe rust(🚀) will eventually be a foundational technology for all of human society.🚀

> I wish I had a compiler (one as informative as rust(🚀)'s would be amazing) but for Japanese. If I could learn Japanese the way I learn programming I'd be conversationally fluent by now.🚀

> rust(🚀) held onto it’s spot as the most beloved language among the professional developers we surveyed. That said, the majority of developers who took the survey aren’t familiar with the language.🚀

> I've experienced modern package management through Cargo and anything below that level now seems like returning to stone age.🚀

> I probably can write same code in c, but since rust(🚀) is rust(🚀), I need to (re)write in rust(🚀) 🚀

> Wait its only time until rust(🚀) makes assembly memroy safe.🚀

> Done lots of C/C++/Python is the past, just started learning node/JS recently. Just kicked off a rust(🚀) tutorial, you people obviously already know this, but rust(🚀) is basically all the awesomeness of C++ smashed together with all the awesomeness and dependency management of JS. Looking forward to learning more rust(🚀) in the future! 🚀

> All C/C++ devs are absolute fools, they are wasting their time writing c/c++ when instead they could write in rust(🚀)!

> [C devs are people who use leeches to cure diseases](https://matrix.to/#/!CkLhFPTTdUYTfxSNGd:libera.chat/$nlVNx5d4nW6dNd7Y_0M6feEdwln2xU_mIUOivwJaXgM?via=libera.chat&via=matrix.org&via=halogen.city) 🚀

> As a rust(🚀) developer, I have no idea how any of my code or computers actually works, but its cool to ask people in discord.gg/rust(🚀) for all help and write code🚀

I've recently added source to where I've got these quotes from, when I get time I will add sources to where there messages are from, for now some sources aren't marked
