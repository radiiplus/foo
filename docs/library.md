# Chapter 7: The Standard Library (Batteries Included)

One of the greatest strengths of FOO is its **Standard Library** (`std/`). In many languages, you have to hunt down third-party packages for basic tasks like reading JSON, hashing passwords, or making HTTP requests. 

FOO ships with over 40 highly-optimized, battle-tested modules ready to use out of the box. And because they are part of the core language, they all follow the same strict safety rules and English-like syntax you’ve already learned.

Let’s tour the most powerful tools in your FOO toolbox.

---

## 1. Text Manipulation (`text`)

Working with strings is a daily task for every programmer. FOO’s `text` module makes it clean and safe.

```foo
use text.

start() {
  constant sentence is "  Hello, FOO World!  ".
  
  -- Remove extra spaces from the ends
  constant clean is text.trim(sentence).
  
  -- Split the text into a list of words
  constant words is text.split(clean, " ").
  
  display words.
  give nothing.
}
```

---

## 2. Files and Paths (`fs`, `path`)

The `fs` module handles reading and writing files, while the `path` module helps you build file paths safely (without worrying about slashes `/` vs backslashes `\`).

```foo
use fs.
use path.

start() {
  -- Build a path safely: "data/config.json"
  constant config_path is path.join("data", "config.json").
  
  -- Read the file (returns a fallible result)
  constant content is try fs.read(config_path).
  
  -- Write it back
  try fs.write(config_path, content).
  
  give nothing.
}
```

---

## 3. Networking and Web (`net`, `http`)

FOO makes web requests incredibly simple. The `http` module handles all the complex TCP/IP and header parsing for you.

```foo
use http.

start() {
  -- Perform a simple GET request
  constant response is try http.get("https://example.com").
  
  display response.status.
  display response.body.
  
  give nothing.
}
```

---

## 4. Data Serialization (`json`)

Talking to APIs usually means working with JSON. FOO has a built-in JSON parser and encoder that is both fast and type-safe.

```foo
use json.

start() {
  constant raw_json is "{ \"name\": \"vibes\", \"level\": 99 }".
  
  -- Parse the JSON string into a FOO value
  constant data is try json.parse(raw_json).
  
  -- Access the data (assuming dynamic access or pattern matching)
  display data.
  
  give nothing.
}
```

---

## 5. Cryptography (`crypto`)

Security is serious business. FOO’s `crypto` module wraps industry-standard C libraries (like OpenSSL or libsodium) to give you secure hashing and encryption with zero configuration.

```foo
use crypto.

start() {
  constant secret is "my_password".
  
  -- Generate a secure SHA-256 hash
  constant hash is crypto.sha256(secret).
  
  display "Hash: " plus hash.
  give nothing.
}
```

---

## 6. The "Under the Hood" Superpower: Interoperability

You might be wondering: *"How does FOO implement all these features so quickly?"*

This is where FOO’s **Interoperability** shines. Most of the standard library modules (like `net`, `crypto`, and `fs`) are actually elegant FOO wrappers around highly optimized C code (the `service.c` layer we saw in the compiler source).

This means you get the safety and readability of FOO, with the raw, bare-metal performance of C. You never have to choose between the two.

---

## Summary: The Library Philosophy

The FOO Standard Library is designed to be **Predictable**. 
*   Every function returns `fallible` types, so you are forced to handle errors.
*   Every module uses the same naming conventions.
*   Every function is optimized for your specific hardware by the `opt` engine.

In the next chapter, we will look at **Packages**, where we will learn how to install libraries from the community and publish our own!