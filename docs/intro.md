# Chapter 1: Welcome to FOO (The Best of Both Worlds)

For decades, programmers have been forced to make a tough choice: Do you want a language that is easy to read and write (like Python), or do you want a language that is blazing fast and gives you total control over the hardware (like C, C++, or Rust)? 

Usually, you can't have both. If you choose the easy language, your program might run slow. If you choose the fast language, your code often looks like a wall of confusing math symbols, brackets, and semicolons.

**FOO was built to end that compromise.** 

FOO is a sentence-like systems language (a language for low-level,
high-performance programs). It reads close to English and compiles through C
or Zig to native code (instructions built to run directly on the chosen
machine). Its optimizer (the compiler stage that removes needless work)
removes proven unnecessary work and selects compatible runtime paths (internal
implementations used while the program runs) without changing the source
contract (the behavior the language promises).

---

## 1. Reads Like English, Runs Like a Sports Car

FOO's parser (the part of the compiler that reads source) accepts a small,
defined sentence grammar. It does not guess the meaning of arbitrary English.

Here is a complete, working FOO program:

```foo
function greet(name text) giving text {
  give "Hello, " plus name plus "!".
}

display greet("vibes").
```

Notice what is missing: there are no semicolons, no entry-point wrapper, and no
parentheses around every condition. Top-level statements run in source order;
functions use words such as `give` and `plus` when a value must be returned or
combined.

FOO does not interpret this program line by line. It checks and lowers (turns
into a simpler compiler form) the source, then a C or Zig backend (code
generator) produces a native executable (a program built to run directly on
the chosen operating system and processor).

---

## 2. The Ultimate Shapeshifter (Multiple Build Backends)

When you tell FOO to build your app, it doesn't just do it one way. FOO acts as a master translator, capable of generating code for two of the most powerful systems languages in the world: **C** and **Zig**.

*   **The C Backend:** FOO can translate your code into standard, highly-optimized C11. This means your FOO program can run on virtually any device on Earth, from massive cloud servers to tiny embedded microcontrollers.
*   **The Zig Backend:** FOO can also translate your code into Zig, taking advantage of modern memory safety features and lightning-fast compilation times.

### Smart Optimization (`opt`)
FOO's optimizer uses the declared target and CPU profile. On a compatible
x86-64 release target, medium byte transfers can use AVX2 (processor
instructions that handle several bytes at once). AArch64 (the common 64-bit
ARM processor architecture) and Zig have
their own overlap-safe block paths, while other sizes and targets keep portable
fallbacks. Generic specialization (creating code for an exact type),
collection allocation strategy (how memory is reserved), task event services,
and cache identity (the inputs that decide whether saved build work is still
valid) use the same target-aware contract. Read
[Optimization Under the Hood](tuning.md) for the exact thresholds and limits.

---

## 3. Superpowers Hidden in Plain Sight

The language also exposes compile-time work, checked memory contracts, and
native interoperability without changing its ordinary statement grammar.

### 🪄 Compile-Time Magic (`eval`)
Sometimes, you have heavy tasks—like reading a configuration file, doing complex math, or formatting a giant block of text—that never actually change while the user is running the app. 
With an `eval` block, supported computation happens while the program is built
and its result is stored in the output. This can remove runtime computation,
but the stored result still contributes to executable or loaded memory size.

### 🛡️ Bulletproof Memory (Sealing)
Memory bugs include reading data before initialization and using storage after
its owner has closed. FOO's sealing analysis tracks supported ownership and
ordering contracts and rejects violations it can prove. Native code and an
incorrect foreign contract remain the programmer's responsibility.

### 🤝 Play Nice With Others (Interoperability)
FOO can generate typed declarations from supported C headers with `foo bind`.
Those declarations check the FOO side of each call; the native library and its
declared ABI, layout, ownership, and lifetime contracts must still be correct.

---

## 4. How This Book is Structured

This documentation is designed to take you from a complete beginner to a systems-level expert, step-by-step. 
*   We will start with the **Language** (how to write basic sentences and logic).
*   We will move to **Data and Memory** (how FOO keeps your apps safe from crashing).
*   We will explore **Systems and Concurrency** (how to talk to the internet and do multiple things at once).
*   Finally, we will look at the **Compiler and Advanced** features (how to bend the hardware to your will).

You don't need to memorize everything today. Start with `display "Hello, world!".`, and let's get started!
