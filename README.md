# zMonkeyLang

This is an interpreter and a compiler/VM for the Monkey programming language as described in [Writing an Interpreter in Go](https://interpreterbook.com/) and the compiler [Writing a Compiler in Go](https://compilerbook.com/). The book has the implementation in Go, but to scratch my own itch I decided to write it in [Zig](https://ziglang.org).

> [!NOTE]
> The interpreter is minimally maintained. Most of the interesting things are in the compiler version of the language.

Note that I am fairly new to [Zig](https://ziglang.org), so this may not be the most idiomatic implementation.

This is purely for educational purposes and is not intended to be used in any production environment.

## Differences from the book

### Garbage collection

The book relies on Go's garbage collection to manage memory. One of Zig's strengths is its explicit memory management, and thus has no garbage collector. I attempted to implement a mark-and-sweep garbage collector for the interpreter version of the language.

The VM currently does no memory management during run time. Memory is allocated from arenas that are only freed when the REPL exits, so memory use grows for the whole session.

### Loops

The original specifications did not have support for loops. Added support for loops, inspired by [Odin's for statement](https://odin-lang.org/docs/overview/#for-statement). Looping through arrays, hashes and strings is also supported. See the tour below for examples.

### Range type

Implementing loops also allowed for a range type, almost for free:

```
>> 0..5
0..5
>> let xs = []; for i in -3..3 { xs = push(xs, i); } xs
[-3, -2, -1, 0, 1, 2]
```

### Floats

The book only has integers. Our version adds 64-bit floats. Mixing an int and a float gives a float, while dividing two ints still truncates.

```
>> 7 / 2
3
>> 7.0 / 2
3.5
>> 1.5 + 2
3.5
>> 3 < 3.5
true
```

### Closures

Closures are limited in the original compiler version of the language. Most notably, writing to a closed-over value was not allowed. This version implements [Upvalue](https://salivity.github.io/lua/article/how-lua-closures-share-and-mutate-upvalues) [based](https://salivity.github.io/lua/article/what-are-upvalues-in-lua-functions) closures inspired by Lua.

It allows for things like:

#### Private state

"Class" like functions where the methods in the returned hash share state. Code outside can change it only through those methods.

```
>> let makeAccount = fn(balance) { {"deposit": fn(amount) { balance = balance + amount; balance }, "withdraw": fn(amount) { if (amount > balance) { return "insufficient funds"; } balance = balance - amount; balance }, "balance": fn() { balance }} };
>> let account = makeAccount(100);
>> account["deposit"](50)
150
>> account["withdraw"](30)
120
>> account["withdraw"](500)
insufficient funds
>> account["balance"]()
120
```

#### Iterators

`iterate` returns a function that hands out one item per call. When the items run out, indexing past the end returns `null`.

```
>> let iterate = fn(arr) { let i = 0; fn() { let item = arr[i]; i = i + 1; item } };
>> let next = iterate(["red", "green", "blue"]);
>> next()
red
>> next()
green
>> next()
blue
>> next()
null
```

#### Run once

`once` wraps a function so its work runs only on the first call. Later calls return the saved result.

```
>> let once = fn(f) { let done = false; let result = null; fn() { if (!done) { result = f(); done = true; } result } };
>> let loadConfig = once(fn() { puts("loading config..."); {"debug": true} });
>> loadConfig()["debug"]
loading config...
true
>> loadConfig()["debug"]
true
```

#### Collecting results from a helper

The inner `sort` function adds each item to one of the outer function's arrays.

```
>> let partition = fn(arr, pred) { let yes = []; let no = []; let sort = fn(x) { if (pred(x)) { yes = push(yes, x); } else { no = push(no, x); } }; for x in arr { sort(x); } [yes, no] };
>> partition(1..10, fn(x) { x > 5 })
[[6, 7, 8, 9], [1, 2, 3, 4, 5]]
```

## A quick tour

Start the REPL with `zig build run`. The REPL reads one line at a time, so each statement in this tour fits on one line. Each section stands alone, so you can run any of them in a fresh REPL.

### Values

```
>> let name = "Monkey";
>> "Hello, " + name + "!"
Hello, Monkey!
>> 3.14159 * 2 * 2
12.56636
```

### Functions and recursion

```
>> let fib = fn(n) { if (n < 2) { return n; } fib(n - 1) + fib(n - 2) };
>> fib(20)
6765
```

### Closures that keep state

```
>> let makeCounter = fn() { let count = 0; fn() { count = count + 1; count } };
>> let tick = makeCounter();
>> tick(); tick(); tick()
3
```

### Higher-order functions and ranges

`0..6` is a range from 0 up to, but not including, 6.

```
>> let map = fn(arr, f) { let out = []; for x in arr { out = push(out, f(x)); } out };
>> let reduce = fn(arr, acc, f) { for x in arr { acc = f(acc, x); } acc };
>> let squares = map(0..6, fn(x) { x * x });
>> squares
[0, 1, 4, 9, 16, 25]
>> reduce(squares, 0, fn(a, b) { a + b })
55
```

### Hashes

```
>> let born = {"monkey": 2016, "zig": 2016, "go": 2009};
>> born
{zig: 2016, monkey: 2016, go: 2009}
>> born["go"]
2009
>> let total = 0; for lang, year in born { total = total + year; } total
6041
```

### Strings

A `for` loop over a string gives you one character at a time.

```
>> let chars = []; for c in "zig⚡🐒" { chars = push(chars, c); } chars
[z, i, g, ⚡, 🐒]
>> len(chars)
5
>> let reversed = ""; for c in "monkey" { reversed = c + reversed; } reversed
yeknom
>> let n = 0; for c in "banana" { if (c == "a") { n = n + 1; } } n
3
```

`len` counts characters in the string.

```
>> len("zig⚡🐒")
5
```

### Loops

```
>> let evens = []; for let i = 0; i < 10; i = i + 2 { evens = push(evens, i); } evens
[0, 2, 4, 6, 8]
>> let firstPowerOver = fn(limit) { let n = 1; for { if (n > limit) { return n; } n = n * 2; } };
>> firstPowerOver(1000)
1024
```

`for x in ...` loops over arrays, ranges, strings, and hashes (`for key, value in ...`). With two names, arrays, ranges, and strings give you the position first: `for i, c in "hé"` binds `i` to `0` and then `1`.

### Builtins

```
>> let squares = [0, 1, 4, 9, 16, 25];
>> len(squares)
6
>> first(squares)
0
>> last(squares)
25
>> rest(squares)
[1, 4, 9, 16, 25]
>> if (len(squares) > 5) { "big" } else { "small" }
big
```
