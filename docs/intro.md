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

Most languages force you to learn a secret code. FOO’s parser (the part of the compiler that reads your code) is designed to understand natural, flowing sentences. 

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

As you get deeper into FOO, you’ll discover features that feel like magic. They are designed to keep your code safe and lightning-fast without making you write extra boilerplate.

### 🪄 Compile-Time Magic (`eval`)
Sometimes, you have heavy tasks—like reading a configuration file, doing complex math, or formatting a giant block of text—that never actually change while the user is running the app. 
With FOO’s `eval` blocks, you can tell the compiler to do that heavy lifting *while the program is being built*. The results are baked directly into the final app, meaning your app starts up instantly and uses zero extra memory for those tasks.

### 🛡️ Bulletproof Memory (Sealing)
Memory bugs (where a program accidentally reads data before it's written, or cleans it up too early) are the hardest bugs to find in systems programming. FOO uses a brilliant process called **Sealing**. As your code is compiled, FOO builds an invisible mathematical "dependency trail" through your memory operations. It mathematically guarantees that every piece of data is read and written in the exact, perfect chronological order, completely eliminating entire categories of invisible bugs before your app even runs.

### 🤝 Play Nice With Others (Interoperability)
The programming world runs on C libraries. If you need to use an existing C library for graphics, networking, or cryptography, you don't have to rewrite it in FOO. FOO can read C header files and automatically generate safe, English-like FOO wrappers. You get to use the massive, decades-old ecosystem of C, but you get to write your actual app in beautiful, readable FOO.

---

## 4. How This Book is Structured

This documentation is designed to take you from a complete beginner to a systems-level expert, step-by-step. 
*   We will start with the **Language** (how to write basic sentences and logic).
*   We will move to **Data and Memory** (how FOO keeps your apps safe from crashing).
*   We will explore **Systems and Concurrency** (how to talk to the internet and do multiple things at once).
*   Finally, we will look at the **Compiler and Advanced** features (how to bend the hardware to your will).

You don't need to memorize everything today. Start with `display "Hello, world!".`, and let's get started!
