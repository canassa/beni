//! Symbolic continuation evidence through the actual compiler/cache boundary.
const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const testing = std.testing;

const source =
    \\import Debug
    \\import Fingerprint
    \\import Handle
    \\import Other
    \\import Task
    \\
    \\
    \\pub twice : (a → a), a → a
    \\twice f value =
    \\    first = f value
    \\    f first
    \\
    \\
    \\pub other : (a → a), a → a
    \\other f value = f value
    \\
    \\
    \\pub nested : (a → a), a → a
    \\nested f value =
    \\    apply : (b → b), b → b
    \\    apply read input = read input
    \\    apply f value
    \\
    \\
    \\pub reference : (Handle.Token a → Handle.Token a), Handle.Token a → Handle.Token a
    \\reference f cell = f cell
    \\
    \\
    \\pub grow : Int, a → a
    \\grow depth value =
    \\    if depth == 0 then
    \\        Task.yieldNow ⊤
    \\        value
    \\    else
    \\        values = grow (depth - 1) [ value ]
    \\        case values of
    \\            [ found, …_ ] → found
    \\            [] → value
    \\
    \\
    \\pub otherReference : (Other.Token a → Other.Token a), Other.Token a → Other.Token a
    \\otherReference f cell = f cell
    \\
    \\
    \\pub record : ({ row | item : a } → a), { row | item : a } → a
    \\record f value = f value
    \\
    \\
    \\pub constrained : (a → a), a → a where a.eq : a, a → Bool
    \\constrained f value =
    \\    first = f value
    \\    if first == value then first else value
    \\
    \\
    \\pub nullary : Handle.Token a → Handle.Token a
    \\nullary token = token.later
    \\
    \\
    \\pub crossed : (a → a), a → a
    \\crossed f value = Debug.log "crossed" (f value)
    \\
    \\
    \\pub identity : (a → a), a → String where a.compare : a, a → Order
    \\identity f value = Fingerprint.stamp f value
    \\
;

const handle_source =
    \\import Task
    \\
    \\
    \\pub foreign type Token a
    \\
    \\
    \\pub later : Token a → Token a
    \\later token =
    \\    Task.yieldNow ⊤
    \\    token
    \\
;

const fingerprint_source =
    \\import Js
    \\
    \\
    \\pub stamp : (a → a), a → String where a.compare : a, a → Order
    \\stamp f value = Js.fingerprint (f value) EQ
    \\
;

// Captured from Debug beni dump --stage=continuations, not hand-written types.
const expected_dump =
    \\continuations Probe schema=1 partial=true present=true
    \\declaration-heads Probe rows=11
    \\  head twice none
    \\  head other none
    \\  head nested none
    \\  head reference none
    \\  head grow none
    \\  head otherReference none
    \\  head record none
    \\  head constrained none
    \\  head nullary none
    \\  head crossed none
    \\  head identity none
    \\  owner twice bundle=0
    \\    site 11 call type=0 own=poly body=no
    \\    site 14 call type=0 own=poly body=no
    \\  owner other bundle=1
    \\    site 26 call type=6 own=poly body=no
    \\  owner nested bundle=2
    \\    site 35 let_def type=19 own=poly body=no
    \\    site 46 call type=17 own=poly body=no
    \\    site 50 call type=12 own=poly body=no
    \\  owner reference bundle=3
    \\    site 70 call type=28 own=poly body=no
    \\  owner grow bundle=4
    \\    site 84 call type=35 own=yes body=no
    \\    site 99 call type=36 own=yes body=no
    \\  owner otherReference bundle=5
    \\    site 132 call type=45 own=poly body=no
    \\  owner record bundle=6
    \\    site 147 call type=47 own=poly body=no
    \\  owner constrained bundle=7
    \\    site 163 call type=58 own=poly body=no
    \\    site 166 method_call type=63 own=poly body=no
    \\  owner nullary bundle=8
    \\    site 186 method_call type=72 own=yes body=no
    \\  owner crossed bundle=9
    \\    site 199 call type=74 own=poly body=no
    \\  owner identity bundle=10
    \\    site 213 ext_value type=89 own=no body=poly
    \\    site 216 call type=88 own=poly body=no
    \\module Probe
    \\scheme 0 body=5 quantified=1 effects=19
    \\  q 0 kind=0 equatable=false name=a constraints=0
    \\scheme 1 body=11 quantified=1 effects=62
    \\  q 0 kind=0 equatable=false name=a constraints=0
    \\scheme 2 body=20 quantified=2 effects=116
    \\  q 0 kind=0 equatable=false name=a constraints=0
    \\  q 1 kind=0 equatable=false name=b constraints=0
    \\scheme 3 body=29 quantified=1 effects=170
    \\  q 0 kind=0 equatable=false name=a constraints=0
    \\scheme 4 body=37 quantified=1 effects=214
    \\  q 0 kind=0 equatable=false name=a constraints=0
    \\scheme 5 body=46 quantified=1 effects=250
    \\  q 0 kind=0 equatable=false name=a constraints=0
    \\scheme 6 body=57 quantified=2 effects=309
    \\  q 0 kind=0 equatable=false name=a constraints=0
    \\  q 1 kind=0 equatable=false name=row constraints=0
    \\scheme 7 body=64 quantified=1 effects=360
    \\  q 0 kind=0 equatable=false name=a constraints=1
    \\    where eq term=66
    \\scheme 8 body=73 quantified=1 effects=409
    \\  q 0 kind=0 equatable=false name=a constraints=0
    \\scheme 9 body=79 quantified=1 effects=439
    \\  q 0 kind=0 equatable=false name=a constraints=0 crosses
    \\scheme 10 body=90 quantified=1 effects=497
    \\  q 0 kind=0 equatable=false name=a constraints=1
    \\    where compare term=92
    \\typeref 0 platform Handle.Token
    \\typeref 1 core Basics.Int
    \\typeref 2 core List.List
    \\typeref 3 platform Other.Token
    \\typeref 4 core Basics.Bool
    \\typeref 5 core String.String
    \\typeref 6 core Basics.Order
    \\term 0 var 0 0
    \\term 1 func 0 0
    \\term 2 func 2 0
    \\term 3 func 5 0
    \\term 4 func 7 0
    \\term 5 tuple 10 0
    \\term 6 var 0 0
    \\term 7 func 44 6
    \\term 8 func 46 6
    \\term 9 func 49 6
    \\term 10 func 51 6
    \\term 11 tuple 54 0
    \\term 12 var 0 0
    \\term 13 func 87 12
    \\term 14 func 89 12
    \\term 15 func 92 12
    \\term 16 func 94 12
    \\term 17 var 1 0
    \\term 18 func 97 17
    \\term 19 func 99 17
    \\term 20 tuple 102 0
    \\term 21 var 0 0
    \\term 22 app 0 146
    \\term 23 func 148 22
    \\term 24 func 150 22
    \\term 25 app 0 153
    \\term 26 func 155 25
    \\term 27 func 157 25
    \\term 28 app 0 160
    \\term 29 tuple 162 0
    \\term 30 app 1 195
    \\term 31 var 0 0
    \\term 32 func 196 31
    \\term 33 app 1 199
    \\term 34 func 200 31
    \\term 35 unit 0 0
    \\term 36 app 2 203
    \\term 37 tuple 205 0
    \\term 38 var 0 0
    \\term 39 app 3 226
    \\term 40 func 228 39
    \\term 41 func 230 39
    \\term 42 app 3 233
    \\term 43 func 235 42
    \\term 44 func 237 42
    \\term 45 app 3 240
    \\term 46 tuple 242 0
    \\term 47 var 0 0
    \\term 48 var 1 0
    \\term 49 record 275 48
    \\  field item term=47
    \\term 50 func 278 47
    \\term 51 record 280 48
    \\  field item term=47
    \\term 52 func 283 47
    \\term 53 record 286 48
    \\  field item term=47
    \\term 54 func 289 47
    \\term 55 record 291 48
    \\  field item term=47
    \\term 56 func 294 47
    \\term 57 tuple 297 0
    \\term 58 var 0 0
    \\term 59 func 334 58
    \\term 60 func 336 58
    \\term 61 func 339 58
    \\term 62 func 341 58
    \\term 63 app 4 344
    \\term 64 tuple 345 0
    \\term 65 app 4 350
    \\term 66 func 351 65
    \\term 67 var 0 0
    \\term 68 app 0 391
    \\term 69 func 393 68
    \\term 70 app 0 395
    \\term 71 func 397 70
    \\term 72 app 0 399
    \\term 73 tuple 401 0
    \\term 74 var 0 0
    \\term 75 func 421 74
    \\term 76 func 423 74
    \\term 77 func 426 74
    \\term 78 func 428 74
    \\term 79 tuple 431 0
    \\term 80 var 0 0
    \\term 81 func 464 80
    \\term 82 app 5 466
    \\term 83 func 467 82
    \\term 84 func 470 80
    \\term 85 app 5 472
    \\term 86 func 473 85
    \\term 87 func 476 80
    \\term 88 app 5 478
    \\term 89 func 479 88
    \\term 90 tuple 482 0
    \\term 91 app 6 487
    \\term 92 func 488 91
    \\extra 0 1
    \\extra 1 0
    \\extra 2 2
    \\extra 3 1
    \\extra 4 0
    \\extra 5 1
    \\extra 6 0
    \\extra 7 2
    \\extra 8 3
    \\extra 9 0
    \\extra 10 4
    \\extra 11 2
    \\extra 12 4
    \\extra 13 0
    \\extra 14 0
    \\extra 15 0
    \\extra 16 0
    \\extra 17 0
    \\extra 18 0
    \\extra 19 2
    \\extra 20 0
    \\extra 21 1
    \\extra 22 1
    \\extra 23 512
    \\extra 24 0
    \\extra 25 4
    \\extra 26 0
    \\extra 27 0
    \\extra 28 1
    \\extra 29 805306368
    \\extra 30 1
    \\extra 31 0
    \\extra 32 2
    \\extra 33 805306368
    \\extra 34 0
    \\extra 35 0
    \\extra 36 0
    \\extra 37 1
    \\extra 38 805306369
    \\extra 39 1
    \\extra 40 0
    \\extra 41 2
    \\extra 42 805306369
    \\extra 43 0
    \\extra 44 1
    \\extra 45 6
    \\extra 46 2
    \\extra 47 7
    \\extra 48 6
    \\extra 49 1
    \\extra 50 6
    \\extra 51 2
    \\extra 52 9
    \\extra 53 6
    \\extra 54 3
    \\extra 55 8
    \\extra 56 10
    \\extra 57 6
    \\extra 58 0
    \\extra 59 1
    \\extra 60 0
    \\extra 61 0
    \\extra 62 2
    \\extra 63 0
    \\extra 64 1
    \\extra 65 1
    \\extra 66 512
    \\extra 67 0
    \\extra 68 4
    \\extra 69 0
    \\extra 70 0
    \\extra 71 1
    \\extra 72 805306368
    \\extra 73 1
    \\extra 74 0
    \\extra 75 2
    \\extra 76 805306368
    \\extra 77 0
    \\extra 78 0
    \\extra 79 0
    \\extra 80 1
    \\extra 81 805306369
    \\extra 82 1
    \\extra 83 0
    \\extra 84 2
    \\extra 85 805306369
    \\extra 86 0
    \\extra 87 1
    \\extra 88 12
    \\extra 89 2
    \\extra 90 13
    \\extra 91 12
    \\extra 92 1
    \\extra 93 12
    \\extra 94 2
    \\extra 95 15
    \\extra 96 12
    \\extra 97 1
    \\extra 98 17
    \\extra 99 2
    \\extra 100 18
    \\extra 101 17
    \\extra 102 5
    \\extra 103 14
    \\extra 104 16
    \\extra 105 19
    \\extra 106 17
    \\extra 107 12
    \\extra 108 0
    \\extra 109 2
    \\extra 110 0
    \\extra 111 0
    \\extra 112 0
    \\extra 113 3
    \\extra 114 0
    \\extra 115 0
    \\extra 116 2
    \\extra 117 0
    \\extra 118 1
    \\extra 119 1
    \\extra 120 512
    \\extra 121 0
    \\extra 122 5
    \\extra 123 0
    \\extra 124 0
    \\extra 125 1
    \\extra 126 805306368
    \\extra 127 1
    \\extra 128 0
    \\extra 129 2
    \\extra 130 805306368
    \\extra 131 0
    \\extra 132 0
    \\extra 133 0
    \\extra 134 1
    \\extra 135 805306369
    \\extra 136 1
    \\extra 137 0
    \\extra 138 2
    \\extra 139 805306369
    \\extra 140 0
    \\extra 141 1
    \\extra 142 0
    \\extra 143 2
    \\extra 144 805306370
    \\extra 145 0
    \\extra 146 1
    \\extra 147 21
    \\extra 148 1
    \\extra 149 22
    \\extra 150 2
    \\extra 151 23
    \\extra 152 22
    \\extra 153 1
    \\extra 154 21
    \\extra 155 1
    \\extra 156 25
    \\extra 157 2
    \\extra 158 26
    \\extra 159 25
    \\extra 160 1
    \\extra 161 21
    \\extra 162 3
    \\extra 163 24
    \\extra 164 27
    \\extra 165 28
    \\extra 166 0
    \\extra 167 4
    \\extra 168 0
    \\extra 169 0
    \\extra 170 2
    \\extra 171 0
    \\extra 172 1
    \\extra 173 1
    \\extra 174 512
    \\extra 175 0
    \\extra 176 4
    \\extra 177 0
    \\extra 178 0
    \\extra 179 1
    \\extra 180 805306368
    \\extra 181 1
    \\extra 182 0
    \\extra 183 2
    \\extra 184 805306368
    \\extra 185 0
    \\extra 186 0
    \\extra 187 0
    \\extra 188 1
    \\extra 189 805306369
    \\extra 190 1
    \\extra 191 0
    \\extra 192 2
    \\extra 193 805306369
    \\extra 194 0
    \\extra 195 0
    \\extra 196 2
    \\extra 197 30
    \\extra 198 31
    \\extra 199 0
    \\extra 200 2
    \\extra 201 33
    \\extra 202 31
    \\extra 203 1
    \\extra 204 31
    \\extra 205 4
    \\extra 206 32
    \\extra 207 34
    \\extra 208 35
    \\extra 209 36
    \\extra 210 0
    \\extra 211 7
    \\extra 212 0
    \\extra 213 0
    \\extra 214 1
    \\extra 215 2
    \\extra 216 0
    \\extra 217 2
    \\extra 218 0
    \\extra 219 0
    \\extra 220 1
    \\extra 221 805306368
    \\extra 222 0
    \\extra 223 0
    \\extra 224 1
    \\extra 225 805306369
    \\extra 226 1
    \\extra 227 38
    \\extra 228 1
    \\extra 229 39
    \\extra 230 2
    \\extra 231 40
    \\extra 232 39
    \\extra 233 1
    \\extra 234 38
    \\extra 235 1
    \\extra 236 42
    \\extra 237 2
    \\extra 238 43
    \\extra 239 42
    \\extra 240 1
    \\extra 241 38
    \\extra 242 3
    \\extra 243 41
    \\extra 244 44
    \\extra 245 45
    \\extra 246 0
    \\extra 247 12
    \\extra 248 0
    \\extra 249 0
    \\extra 250 2
    \\extra 251 0
    \\extra 252 1
    \\extra 253 1
    \\extra 254 512
    \\extra 255 0
    \\extra 256 4
    \\extra 257 0
    \\extra 258 0
    \\extra 259 1
    \\extra 260 805306368
    \\extra 261 1
    \\extra 262 0
    \\extra 263 2
    \\extra 264 805306368
    \\extra 265 0
    \\extra 266 0
    \\extra 267 0
    \\extra 268 1
    \\extra 269 805306369
    \\extra 270 1
    \\extra 271 0
    \\extra 272 2
    \\extra 273 805306369
    \\extra 274 0
    \\extra 275 2
    \\extra 276 17
    \\extra 277 47
    \\extra 278 1
    \\extra 279 49
    \\extra 280 2
    \\extra 281 18
    \\extra 282 47
    \\extra 283 2
    \\extra 284 50
    \\extra 285 51
    \\extra 286 2
    \\extra 287 19
    \\extra 288 47
    \\extra 289 1
    \\extra 290 53
    \\extra 291 2
    \\extra 292 20
    \\extra 293 47
    \\extra 294 2
    \\extra 295 54
    \\extra 296 55
    \\extra 297 3
    \\extra 298 52
    \\extra 299 56
    \\extra 300 47
    \\extra 301 0
    \\extra 302 15
    \\extra 303 0
    \\extra 304 0
    \\extra 305 0
    \\extra 306 16
    \\extra 307 0
    \\extra 308 0
    \\extra 309 2
    \\extra 310 0
    \\extra 311 1
    \\extra 312 1
    \\extra 313 512
    \\extra 314 0
    \\extra 315 4
    \\extra 316 0
    \\extra 317 0
    \\extra 318 1
    \\extra 319 805306368
    \\extra 320 1
    \\extra 321 0
    \\extra 322 2
    \\extra 323 805306368
    \\extra 324 0
    \\extra 325 0
    \\extra 326 0
    \\extra 327 1
    \\extra 328 805306369
    \\extra 329 1
    \\extra 330 0
    \\extra 331 2
    \\extra 332 805306369
    \\extra 333 0
    \\extra 334 1
    \\extra 335 58
    \\extra 336 2
    \\extra 337 59
    \\extra 338 58
    \\extra 339 1
    \\extra 340 58
    \\extra 341 2
    \\extra 342 61
    \\extra 343 58
    \\extra 344 0
    \\extra 345 4
    \\extra 346 60
    \\extra 347 62
    \\extra 348 58
    \\extra 349 63
    \\extra 350 0
    \\extra 351 2
    \\extra 352 58
    \\extra 353 58
    \\extra 354 28
    \\extra 355 66
    \\extra 356 0
    \\extra 357 25
    \\extra 358 354
    \\extra 359 1
    \\extra 360 3
    \\extra 361 0
    \\extra 362 2
    \\extra 363 1
    \\extra 364 2
    \\extra 365 512
    \\extra 366 0
    \\extra 367 512
    \\extra 368 0
    \\extra 369 5
    \\extra 370 0
    \\extra 371 0
    \\extra 372 1
    \\extra 373 805306368
    \\extra 374 1
    \\extra 375 0
    \\extra 376 2
    \\extra 377 805306368
    \\extra 378 0
    \\extra 379 0
    \\extra 380 0
    \\extra 381 1
    \\extra 382 805306369
    \\extra 383 1
    \\extra 384 0
    \\extra 385 2
    \\extra 386 805306369
    \\extra 387 0
    \\extra 388 2
    \\extra 389 1
    \\extra 390 0
    \\extra 391 1
    \\extra 392 67
    \\extra 393 1
    \\extra 394 68
    \\extra 395 1
    \\extra 396 67
    \\extra 397 1
    \\extra 398 70
    \\extra 399 1
    \\extra 400 67
    \\extra 401 3
    \\extra 402 69
    \\extra 403 71
    \\extra 404 72
    \\extra 405 0
    \\extra 406 29
    \\extra 407 0
    \\extra 408 0
    \\extra 409 1
    \\extra 410 2
    \\extra 411 0
    \\extra 412 2
    \\extra 413 0
    \\extra 414 0
    \\extra 415 1
    \\extra 416 805306368
    \\extra 417 0
    \\extra 418 0
    \\extra 419 1
    \\extra 420 805306369
    \\extra 421 1
    \\extra 422 74
    \\extra 423 2
    \\extra 424 75
    \\extra 425 74
    \\extra 426 1
    \\extra 427 74
    \\extra 428 2
    \\extra 429 77
    \\extra 430 74
    \\extra 431 3
    \\extra 432 76
    \\extra 433 78
    \\extra 434 74
    \\extra 435 1024
    \\extra 436 30
    \\extra 437 0
    \\extra 438 0
    \\extra 439 2
    \\extra 440 1
    \\extra 441 1
    \\extra 442 1
    \\extra 443 512
    \\extra 444 0
    \\extra 445 4
    \\extra 446 0
    \\extra 447 0
    \\extra 448 1
    \\extra 449 805306368
    \\extra 450 1
    \\extra 451 0
    \\extra 452 2
    \\extra 453 805306368
    \\extra 454 0
    \\extra 455 0
    \\extra 456 0
    \\extra 457 1
    \\extra 458 805306369
    \\extra 459 1
    \\extra 460 0
    \\extra 461 2
    \\extra 462 805306369
    \\extra 463 0
    \\extra 464 1
    \\extra 465 80
    \\extra 466 0
    \\extra 467 2
    \\extra 468 81
    \\extra 469 80
    \\extra 470 1
    \\extra 471 80
    \\extra 472 0
    \\extra 473 2
    \\extra 474 84
    \\extra 475 80
    \\extra 476 1
    \\extra 477 80
    \\extra 478 0
    \\extra 479 2
    \\extra 480 87
    \\extra 481 80
    \\extra 482 4
    \\extra 483 83
    \\extra 484 86
    \\extra 485 89
    \\extra 486 88
    \\extra 487 0
    \\extra 488 2
    \\extra 489 80
    \\extra 490 80
    \\extra 491 34
    \\extra 492 92
    \\extra 493 512
    \\extra 494 31
    \\extra 495 491
    \\extra 496 1
    \\extra 497 3
    \\extra 498 0
    \\extra 499 2
    \\extra 500 1
    \\extra 501 2
    \\extra 502 512
    \\extra 503 0
    \\extra 504 256
    \\extra 505 0
    \\extra 506 6
    \\extra 507 0
    \\extra 508 0
    \\extra 509 1
    \\extra 510 805306368
    \\extra 511 1
    \\extra 512 0
    \\extra 513 2
    \\extra 514 805306368
    \\extra 515 0
    \\extra 516 0
    \\extra 517 0
    \\extra 518 1
    \\extra 519 805306369
    \\extra 520 1
    \\extra 521 0
    \\extra 522 2
    \\extra 523 805306369
    \\extra 524 0
    \\extra 525 1
    \\extra 526 0
    \\extra 527 2
    \\extra 528 805306370
    \\extra 529 0
    \\extra 530 2
    \\extra 531 1
    \\extra 532 0
    \\
;

const heads_source =
    \\import Node
    \\import Phantom
    \\
    \\
    \\type alias ProgramAlias =
    \\    Node.Program
    \\
    \\
    \\hidden = Node.done
    \\
    \\
    \\pub aliased : ProgramAlias
    \\aliased = hidden
    \\
    \\
    \\pub returning : ⊤ → Node.Program
    \\returning ⊤ = hidden
    \\
    \\
    \\pub wrapped = { program = hidden }
    \\
    \\
    \\phantom = Phantom.Box
    \\
;

const expected_heads =
    \\continuations Values schema=1 partial=true present=true
    \\declaration-heads Values rows=6
    \\  head ProgramAlias none
    \\  head hidden platform:Node.Program
    \\  head aliased platform:Node.Program
    \\  head returning none
    \\  head wrapped none
    \\  head phantom platform:Phantom.Box
    \\module Values
    \\
;

fn project(w: *World) !void {
    try w.write("platform/beni.json", "{\"platform\":true,\"platforms\":[\"node\"],\"reexports\":[\"Node\"]}");
    try w.write("platform/Handle.beni", handle_source);
    try w.write("platform/Fingerprint.beni", fingerprint_source);
    try w.write("platform/Other.beni", "pub foreign type Token a\n");
    try w.write("platform/Phantom.beni", "pub type Box a\n    = Box\n");
    try w.write("src/Probe.beni", source);
}

const dump_args = [_][]const u8{ "check", "--continuations", "--platform=platform", "--root=src", "--cache-dir=cache", "src/Probe.beni" };

fn expectDump(result: world.Result) !void {
    if (result.exit_code != 0) std.debug.print("{s}\n", .{result.stderr});
    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expectEqualStrings(expected_dump, result.stdout);
}

fn checked(w: *World, trace: []const u8, extra: []const []const u8) !u64 {
    const a = w.arena.allocator();
    var args: std.ArrayList([]const u8) = .empty;
    var overridden = false;
    for (extra) |arg| if (std.mem.startsWith(u8, arg, "--cache-dir=")) {
        overridden = true;
    };
    for (dump_args) |arg| {
        if (overridden and std.mem.startsWith(u8, arg, "--cache-dir=")) continue;
        try args.append(a, arg);
    }
    try args.appendSlice(a, extra);
    try args.append(a, try std.fmt.allocPrint(a, "--self-profile={s}", .{trace}));
    try expectDump(try w.run(args.items));
    return moduleChecks(w, trace);
}

fn moduleChecks(w: *World, trace: []const u8) !u64 {
    const Event = struct { args: struct { modules_checked: ?u64 = null } = .{} };
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []Event }, testing.allocator, try w.read(trace), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.traceEvents) |event| if (event.args.modules_checked) |count| return count;
    return error.MissingCheckCounter;
}

test "symbolic continuation evidence retains scoped parameters and survives cold warm roundtrip and relocation" {
    // PREPARE: scopes distinguish owner a, local b, nominal handles and row/where constraints.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try project(&w);

    // EXECUTE / VERIFY OUTPUT: exact public dump, with no retained type stores.
    try testing.expect((try checked(&w, "cold.json", &.{"--jobs=1"})) > 0);
    try testing.expectEqual(@as(u64, 0), try checked(&w, "warm.json", &.{"--jobs=8"}));
    try testing.expect((try checked(&w, "roundtrip.json", &.{ "--cache-dir=roundtrip", "--roundtrip-dispatch", "--roundtrip-interfaces", "--jobs=8" })) > 0);
    try testing.expectEqual(@as(u64, 0), try checked(&w, "roundtrip-warm.json", &.{ "--cache-dir=roundtrip", "--roundtrip-dispatch", "--jobs=1" }));

    // VERIFY SIDE EFFECTS: moving the same cache into a new project preserves the evidence.
    var moved = try World.init(testing.allocator, testing.io);
    defer moved.deinit();
    try project(&moved);
    for (try w.listFiles("cache")) |name| {
        const relative = try std.fmt.allocPrint(w.arena.allocator(), "cache/{s}", .{name});
        try moved.write(relative, try w.read(relative));
    }
    try testing.expectEqual(@as(u64, 0), try checked(&moved, "moved.json", &.{"--jobs=8"}));
    try testing.expect(!w.exists("out"));
}

fn cacheEntry(w: *World) ![]const u8 {
    return entryFor(w, "Probe");
}
fn entryFor(w: *World, name: []const u8) ![]const u8 {
    const file = try std.fmt.allocPrint(w.arena.allocator(), "src/{s}.beni", .{name});
    const keys = try w.run(&.{ "check", "--platform=platform", "--root=src", "--cache-keys", file });
    const prefix = try std.fmt.allocPrint(w.arena.allocator(), "app:{s} ", .{name});
    try testing.expectEqual(@as(u8, 0), keys.exit_code);
    try testing.expectEqualStrings("", keys.stderr);
    var lines = std.mem.splitScalar(u8, keys.stdout, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const digits = line[prefix.len..];
        try testing.expectEqual(@as(usize, 32), digits.len);
        return std.fmt.allocPrint(w.arena.allocator(), "cache/v1/{s}/{s}.bec", .{ digits[0..2], digits[2..] });
    }
    return error.MissingModuleKey;
}

fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn setWord(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

test "malformed or stale continuation cache evidence is rebuilt before use" {
    // PREPARE: the dump is the oracle; the cache is an external input to corrupt.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try project(&w);
    _ = try checked(&w, "cold.json", &.{});
    const entry = try cacheEntry(&w);
    const good = try w.read(entry);
    try testing.expectEqualStrings("BENICAC\x00", good[0..8]);
    const sidecar = word(good, 40);
    try testing.expectEqualStrings("BENIDSP\x00", good[sidecar..][0..8]);
    try testing.expectEqual(@as(u32, 16), word(good, sidecar + 8));
    const columns = word(good, sidecar + 12);
    // Format16 appends continuation evidence, then independent declaration heads.
    const plan = sidecar + word(good, sidecar + 16 + (columns - 2) * 8);
    try testing.expectEqualStrings("BENICNT\x00", good[plan..][0..8]);
    try testing.expectEqual(@as(u32, 1), word(good, plan + 8));
    const scopes = word(good, plan + 12);
    try testing.expect(scopes > 0);
    const first_site = plan + 24 + scopes * 16;
    try testing.expectEqual(@as(u64, 0), try checked(&w, "warm.json", &.{}));

    // EXECUTE / VERIFY OUTPUT: each malformed form safely misses; none becomes empty usable evidence.
    for (0..5) |mutation| {
        const bad = try w.arena.allocator().dupe(u8, good);
        switch (mutation) {
            0 => setWord(bad, plan + 8, 0), // unknown schema
            1 => setWord(bad, first_site + 4, std.math.maxInt(u32)), // invalid type root
            2 => setWord(bad, plan + 24 + (scopes - 1) * 16, std.math.maxInt(u32)), // valid bytes, invalid BIR owner
            3 => bad[first_site + 8] = 1, // well-formed but disagrees with authoritative poly effect
            4 => {},
            else => unreachable,
        }
        try w.write(entry, if (mutation == 4) bad[0 .. plan + 12] else bad);
        const trace = try std.fmt.allocPrint(w.arena.allocator(), "repair-{d}.json", .{mutation});
        try testing.expectEqual(@as(u64, 1), try checked(&w, trace, &.{}));
        // VERIFY SIDE EFFECTS: canonical bytes restored, next warm run does not recheck.
        try testing.expectEqualStrings(good, try w.read(entry));
        try testing.expectEqual(@as(u64, 0), try checked(&w, "repaired-warm.json", &.{}));
    }
    try testing.expect(!w.exists("out"));
}

test "declaration heads include private inferred polymorphic and alias values without confusing contained types" {
    // PREPARE: no continuation sites are required to publish value heads.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try project(&w);
    try w.write("src/Values.beni", heads_source);
    const args = [_][]const u8{ "check", "--continuations", "--platform=platform", "--root=src", "--cache-dir=cache", "src/Values.beni" };
    // EXECUTE / VERIFY OUTPUT: capture actual nominal identities, never nested occurrences.
    for (0..2) |_| {
        const result = try w.run(&args);
        try testing.expectEqual(@as(u8, 0), result.exit_code);
        try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
        try testing.expectEqualStrings("", result.stderr);
        try testing.expectEqualStrings(expected_heads, result.stdout);
    }
    // VERIFY SIDE EFFECTS: inspection does not emit a program.
    try testing.expect(!w.exists("out"));
}

const expected_absent =
    \\continuations Probe schema=1 partial=true present=false
    \\declaration-heads Probe rows=0
    \\
;

const expected_type_message =
    \\Something is off with the body of this definition:
    \\
    \\The body is:
    \\
    \\    String
    \\
    \\But the type annotation says it should be:
    \\
    \\    Int
    \\
    \\Hint: to read a number out of text, use `String.toInt` or `String.toFloat`.
    \\
;

test "a source error cannot reuse old continuation evidence and restoring clean source reuses its cache" {
    // PREPARE: the same module first has valid symbolic evidence.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try project(&w);
    _ = try checked(&w, "valid.json", &.{});
    try w.write("src/Probe.beni", "pub broken : Int\nbroken = \"wrong\"\n");
    const diagnostic = @import("diagnostic");
    const expected = [_]diagnostic.Diagnostic{.{
        .code = .type_mismatch,
        .severity = .@"error",
        .span = .{ .file = "src/Probe.beni", .start = .{ .line = 2, .col = 10 }, .end = .{ .line = 2, .col = 17 } },
        .title = "TYPE MISMATCH",
        .message = expected_type_message,
    }};
    // EXECUTE / VERIFY OUTPUT: no old or fake empty clean plan accompanies the error.
    for (0..2) |_| {
        const result = try w.run(&(dump_args ++ [_][]const u8{"--self-profile=error.json"}));
        try testing.expectEqual(@as(u8, 1), result.exit_code);
        try testing.expectEqualStrings(expected_absent, result.stdout);
        try testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &expected), result.diagnostics);
        const count = try moduleChecks(&w, "error.json");
        try testing.expectEqual(@as(u64, 1), count);
    }
    try w.write("src/Probe.beni", source);
    try testing.expectEqual(@as(u64, 0), try checked(&w, "restored.json", &.{}));
    // VERIFY SIDE EFFECTS: an inspection/type failure writes no program.
    try testing.expect(!w.exists("out"));
}

test "cached declaration heads reject wrong row counts invalid references and nonvalue heads" {
    // PREPARE: aliases and private nominal values have real resolved heads.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try project(&w);
    try w.write("src/Values.beni", heads_source);
    const args = [_][]const u8{ "check", "--continuations", "--platform=platform", "--root=src", "--cache-dir=cache", "src/Values.beni", "--self-profile=heads.json" };
    const initial = try w.run(&args);
    try testing.expectEqual(@as(u8, 0), initial.exit_code);
    try testing.expectEqualStrings("", initial.stderr);
    try testing.expectEqualStrings(expected_heads, initial.stdout);
    const entry = try entryFor(&w, "Values");
    const good = try w.read(entry);
    const sidecar = word(good, 40);
    const columns = word(good, sidecar + 12);
    const header = sidecar + 16 + (columns - 1) * 8;
    const heads = sidecar + word(good, header);
    try testing.expectEqual(@as(u32, 6), word(good, header + 4));
    try testing.expectEqual(std.math.maxInt(u32), word(good, heads)); // alias declaration, not a value
    try testing.expect(word(good, heads + 4) != std.math.maxInt(u32)); // private Program value
    // EXECUTE / VERIFY OUTPUT: corruption cannot fabricate a candidate or install stale ids.
    for (0..3) |mutation| {
        const bad = try w.arena.allocator().dupe(u8, good);
        switch (mutation) {
            0 => setWord(bad, header + 4, 5),
            1 => setWord(bad, heads + 4, std.math.maxInt(u32) - 1),
            2 => setWord(bad, heads, word(good, heads + 4)),
            else => unreachable,
        }
        try w.write(entry, bad);
        const repaired = try w.run(&args);
        try testing.expectEqual(@as(u8, 0), repaired.exit_code);
        try testing.expectEqualStrings("", repaired.stderr);
        try testing.expectEqualStrings(expected_heads, repaired.stdout);
        try testing.expectEqual(@as(u64, 1), try moduleChecks(&w, "heads.json"));
        // VERIFY SIDE EFFECTS: the ordinary checker restores canonical bytes.
        try testing.expectEqualStrings(good, try w.read(entry));
    }
    try testing.expect(!w.exists("out"));
}

test "private continuation types exceed the public interface depth bound and survive cached roundtrip" {
    // PREPARE: an unused private suspending function has a deep inferred type;
    // the public entry remains shallow, so no public interface limit applies.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    const a = w.arena.allocator();
    for ([_]usize{ 513, 2048 }) |depth| {
        const left = try a.alloc(u8, depth);
        @memset(left, '[');
        const right = try a.alloc(u8, depth);
        @memset(right, ']');
        try w.write("Main.beni", try std.fmt.allocPrint(a, "import Node\nimport Task\n\ndeferred ⊤ =\n    Task.yieldNow ⊤\n    {s}1{s}\n\nmain : Node.Program\nmain = Node.done\n", .{ left, right }));
        const cache = try std.fmt.allocPrint(a, "--cache-dir=deep-{d}", .{depth});
        const args = [_][]const u8{ "check", "--platform=node", cache, "--roundtrip-dispatch", "--roundtrip-interfaces", "--self-profile=deep.json", "Main.beni" };
        // EXECUTE / VERIFY OUTPUT: both cold extraction and decoded warm evidence
        // accept the original source, without diagnostics or fallback wild types.
        for (0..2) |pass| {
            const result = try w.run(&args);
            if (result.exit_code != 0) std.debug.print("{s}\n", .{result.stderr});
            try testing.expectEqual(@as(u8, 0), result.exit_code);
            try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
            try testing.expectEqualStrings("", result.stdout);
            try testing.expectEqualStrings("", result.stderr);
            const count = try moduleChecks(&w, "deep.json");
            if (pass == 0) try testing.expect(count > 0) else try testing.expectEqual(@as(u64, 0), count);
        }
    }
    // VERIFY SIDE EFFECTS: metadata checking does not emit program files.
    try testing.expect(!w.exists("out"));
}

test "private nominal cache evidence rejects wrong arity and alias kind before installation" {
    // PREPARE: an actual inferred symbolic use names an alias and its foreign
    // nominal body, both arity one. Neither kind exists in the private record.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try project(&w);
    try w.write("src/AliasProbe.beni", "import Handle\n\ntype alias Alias a = Handle.Token a\n\npub apply : (Alias a → Alias a), Alias a → Alias a\napply f value = f value\n");
    const args = [_][]const u8{ "check", "--platform=platform", "--root=src", "--cache-dir=cache", "--self-profile=nominal.json", "src/AliasProbe.beni" };
    const initial = try w.run(&args);
    if (initial.exit_code != 0) std.debug.print("{s}\n", .{initial.stderr});
    try testing.expectEqual(@as(u8, 0), initial.exit_code);
    try testing.expectEqualStrings("", initial.stdout);
    try testing.expectEqualStrings("", initial.stderr);
    const entry = try entryFor(&w, "AliasProbe");
    const good = try w.read(entry);
    const sidecar = word(good, 40);
    const columns = word(good, sidecar + 12);
    const plan = sidecar + word(good, sidecar + 16 + (columns - 2) * 8);
    const record = plan + 24 + word(good, plan + 12) * 16 + word(good, plan + 16) * 16;
    try testing.expectEqualStrings("BENIIFC\x00", good[record..][0..8]);
    try testing.expectEqual(@as(u32, 18), word(good, record + 8));
    // Public Interface v18 stores term tags/lhs/rhs/extra in columns4..7.
    const tags = record + word(good, record + 16 + 4 * 8);
    const count = word(good, record + 16 + 4 * 8 + 4);
    const lhs = record + word(good, record + 16 + 5 * 8);
    const rhs = record + word(good, record + 16 + 6 * 8);
    const extra = record + word(good, record + 16 + 7 * 8);
    const extra_count = word(good, record + 16 + 7 * 8 + 4);
    var alias_ref: ?u32 = null;
    for (0..count) |i| if (good[tags + i] == 7) { // alias
        alias_ref = word(good, lhs + i * 4);
        break;
    };
    const alias = alias_ref orelse return error.MissingAlias;
    var app: ?usize = null;
    for (0..count) |i| if (good[tags + i] == 2 and word(good, lhs + i * 4) != alias and word(good, extra + word(good, rhs + i * 4) * 4) == 1) {
        app = i;
        break;
    };
    const application = app orelse return error.MissingNominal;
    var empty: ?u32 = null;
    for (0..extra_count) |i| if (word(good, extra + i * 4) == 0) {
        empty = @intCast(i);
        break;
    };
    const no_args = empty orelse return error.MissingEmptyRange;
    // EXECUTE / VERIFY OUTPUT: generic shape remains valid, but real declaration
    // arity/kind must force source rechecking rather than install false evidence.
    for (0..2) |mutation| {
        const bad = try w.arena.allocator().dupe(u8, good);
        if (mutation == 0) setWord(bad, rhs + application * 4, no_args) else setWord(bad, lhs + application * 4, alias);
        try w.write(entry, bad);
        const repaired = try w.run(&args);
        try testing.expectEqual(@as(u8, 0), repaired.exit_code);
        try testing.expectEqualStrings("", repaired.stdout);
        try testing.expectEqualStrings("", repaired.stderr);
        try testing.expectEqual(@as(usize, 0), repaired.diagnostics.len);
        try testing.expectEqual(@as(u64, 1), try moduleChecks(&w, "nominal.json"));
        // VERIFY SIDE EFFECTS: the corrected canonical cache is warm afterward.
        try testing.expectEqualStrings(good, try w.read(entry));
        const warm = try w.run(&args);
        try testing.expectEqual(@as(u8, 0), warm.exit_code);
        try testing.expectEqual(@as(u64, 0), try moduleChecks(&w, "nominal.json"));
    }
    try testing.expect(!w.exists("out"));
}

const annotated_values_source =
    \\import Task
    \\
    \\pub type Holder a
    \\    = Holder (a → a)
    \\
    \\type alias Phantom a = ⊤ → ⊤
    \\
    \\pub held : Holder a
    \\held = Holder λvalue →
    \\    Task.yieldNow ⊤
    \\    value
    \\
    \\pub phantom : Phantom a
    \\phantom = λ_ → Task.yieldNow ⊤
    \\
;

// Captured from the actual Debug continuation inspector.
const annotated_values_dump =
    \\continuations AnnotatedValues schema=1 partial=true present=true
    \\declaration-heads AnnotatedValues rows=4
    \\  head Holder none
    \\  head Phantom none
    \\  head held app:AnnotatedValues.Holder
    \\  head phantom none
    \\  owner held bundle=0
    \\    site 13 call type=3 own=yes body=no
    \\    site 17 lambda type=4 own=yes body=no
    \\  owner phantom bundle=1
    \\    site 25 call type=9 own=yes body=no
    \\    site 26 lambda type=11 own=yes body=no
    \\module AnnotatedValues
    \\scheme 0 body=5 quantified=1 effects=15
    \\  q 0 kind=0 equatable=false name=a constraints=0
    \\scheme 1 body=12 quantified=1 effects=46
    \\  q 0 kind=0 equatable=false name=a constraints=0
    \\typeref 0 app AnnotatedValues.Holder
    \\typeref 1 app AnnotatedValues.Phantom body=15
    \\term 0 var 0 0
    \\term 1 app 0 0
    \\term 2 app 0 2
    \\term 3 unit 0 0
    \\term 4 func 4 0
    \\term 5 tuple 6 0
    \\term 6 var 0 0
    \\term 7 alias 1 31
    \\term 8 alias 1 33
    \\term 9 unit 0 0
    \\term 10 unit 0 0
    \\term 11 func 35 9
    \\term 12 tuple 37 0
    \\term 13 unit 0 0
    \\term 14 unit 0 0
    \\term 15 func 64 14
    \\extra 0 1
    \\extra 1 0
    \\extra 2 1
    \\extra 3 0
    \\extra 4 1
    \\extra 5 0
    \\extra 6 4
    \\extra 7 1
    \\extra 8 2
    \\extra 9 3
    \\extra 10 4
    \\extra 11 0
    \\extra 12 0
    \\extra 13 0
    \\extra 14 0
    \\extra 15 1
    \\extra 16 2
    \\extra 17 0
    \\extra 18 3
    \\extra 19 0
    \\extra 20 0
    \\extra 21 1
    \\extra 22 805306368
    \\extra 23 0
    \\extra 24 0
    \\extra 25 1
    \\extra 26 805306369
    \\extra 27 0
    \\extra 28 0
    \\extra 29 1
    \\extra 30 805306371
    \\extra 31 1
    \\extra 32 6
    \\extra 33 1
    \\extra 34 6
    \\extra 35 1
    \\extra 36 10
    \\extra 37 4
    \\extra 38 7
    \\extra 39 8
    \\extra 40 9
    \\extra 41 11
    \\extra 42 0
    \\extra 43 3
    \\extra 44 0
    \\extra 45 0
    \\extra 46 1
    \\extra 47 2
    \\extra 48 0
    \\extra 49 3
    \\extra 50 0
    \\extra 51 0
    \\extra 52 2
    \\extra 53 805306368
    \\extra 54 1610612736
    \\extra 55 0
    \\extra 56 0
    \\extra 57 2
    \\extra 58 805306369
    \\extra 59 1610612736
    \\extra 60 0
    \\extra 61 0
    \\extra 62 1
    \\extra 63 805306371
    \\extra 64 1
    \\extra 65 13
    \\
;

test "annotated non-function and phantom values retain actual binders through cached roundtrip" {
    // PREPARE: callable payloads retain a and a phantom alias keeps its unused
    // formal a, even though its expansion has no variable at all.
    var w = try World.init(testing.allocator, testing.io);
    defer w.deinit();
    try project(&w);
    try w.write("src/AnnotatedValues.beni", annotated_values_source);
    // EXECUTE / VERIFY OUTPUT: exact symbolic types, sharing and effects survive
    // cold extraction, warm loading and forced interface/dispatch roundtrip.
    for (0..4) |pass| {
        const extra: []const []const u8 = if (pass >= 2)
            &.{ "--cache-dir=annotated-roundtrip", "--roundtrip-dispatch", "--roundtrip-interfaces" }
        else
            &.{"--cache-dir=cache"};
        const args = try std.mem.concat(w.arena.allocator(), []const u8, &.{
            &.{ "check", "--continuations", "--platform=platform", "--root=src", "--self-profile=annotated.json", "src/AnnotatedValues.beni" }, extra,
        });
        const result = try w.run(args);
        try testing.expectEqual(@as(u8, 0), result.exit_code);
        try testing.expectEqualStrings("", result.stderr);
        try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
        try testing.expectEqualStrings(annotated_values_dump, result.stdout);
        const count = try moduleChecks(&w, "annotated.json");
        if (pass % 2 == 0) try testing.expect(count > 0) else try testing.expectEqual(@as(u64, 0), count);
    }
    // VERIFY SIDE EFFECTS: inspecting annotated values emits no program.
    try testing.expect(!w.exists("out"));
}
