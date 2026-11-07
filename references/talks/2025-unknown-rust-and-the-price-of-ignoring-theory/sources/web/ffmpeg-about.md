---
title: About FFmpeg
source: https://ffmpeg.org/about.html
retrieved: 2026-11-02
---

- [![FFmpeg](img/ffmpeg3d_white_20.png) FFmpeg](.)
- [About](about.html)
- [News](index.html#news)
- [Download](download.html)
- [Documentation](documentation.html)
- [Community](community.html)
  - [Code of Conduct](community.html#Code-of-Conduct)
  - [Mailing Lists](contact.html#MailingLists)
  - [IRC](contact.html#IRCChannels)
  - [Forums](contact.html#Forums)
  - [Bug Reports](bugreports.html)
  - [Wiki](https://trac.ffmpeg.org)
  - [Conferences](https://trac.ffmpeg.org/wiki/Conferences)
- [Developers](developer.html)
  - [Source Code](download.html#get-sources)
  - [Contribute](developer.html#Introduction)
  - [FATE](http://fate.ffmpeg.org)
  - [Code Coverage](http://coverage.ffmpeg.org)
  - [Funding through SPI](spi.html)
- [More](#)
  - [Donate](donations.html)
  - [Hire Developers](consulting.html)
  - [Contact](contact.html)
  - [Security](security.html)
  - [Legal](legal.html)

# [](#) About FFmpeg

FFmpeg is the leading multimedia framework, able to **decode**, **encode**, **transcode**, **mux**, **demux**, **stream**, **filter** and **play** pretty much anything that humans and machines have created. It supports the most obscure ancient formats up to the cutting edge. No matter if they were designed by some standards committee, the community or a corporation. It is also highly portable: FFmpeg compiles, runs, and passes our testing infrastructure [FATE](http://fate.ffmpeg.org) across Linux, Mac OS X, Microsoft Windows, the BSDs, Solaris, etc. under a wide variety of build environments, machine architectures, and configurations.

It contains libavcodec, libavutil, libavformat, libavfilter, libavdevice, libswscale and libswresample which can be used by applications. As well as ffmpeg, ffplay and ffprobe which can be used by end users for **transcoding** and **playing**.

The FFmpeg project tries to provide the best technically possible solution for developers of applications and end users alike. To achieve this we combine the best free software options available. We slightly favor our own code to keep the dependencies on other libs low and to maximize code sharing between parts of FFmpeg. Wherever the question of "best" cannot be answered we support both options so the end user can choose.

Everyone is welcome in FFmpeg and all contributions are welcome too. We are happy to receive patches, pull requests, bug reports, donations or any other type of contribution.

Security is a high priority and code review is always done with security in mind. Though due to the very large amounts of code touching untrusted data security issues are unavoidable and thus we provide as quick as possible updates to our last stable releases when new security issues are found.

###      FFmpeg Tools

  
  

[](ffmpeg.html)

### **ffmpeg**

A **command line tool** to convert multimedia files between formats

[](ffplay.html)

### **ffplay**

A simple media player based on SDL and the FFmpeg libraries

[](ffprobe.html)

### **ffprobe**

A simple multimedia stream analyzer

###      FFmpeg Libraries for developers

  
  

- **[libavutil](libavutil.html)** is a library containing functions for simplifying programming, including random number generators, data structures, mathematics routines, core multimedia utilities, and much more.
- **[libavcodec](libavcodec.html)** is a library containing decoders and encoders for audio/video codecs.
- **[libavformat](libavformat.html)** is a library containing demuxers and muxers for multimedia container formats.
- **[libavdevice](libavdevice.html)** is a library containing input and output devices for grabbing from and rendering to many common multimedia input/output software frameworks, including Video4Linux, Video4Linux2, VfW, and ALSA.
- **[libavfilter](libavfilter.html)** is a library containing media filters.
- **[libswscale](libswscale.html)** is a library performing highly optimized image scaling and color space/pixel format conversion operations.
- **[libswresample](libswresample.html)** is a library performing highly optimized audio resampling, rematrixing and sample format conversion operations.

Hosting provided by [telepoint.bg](https://telepoint.bg)
