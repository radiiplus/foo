# Chapter 8: Packages (Sharing Code with the World)

No programmer is an island. Eventually, you will want to use code that someone else wrote, or share your own brilliant library with the world. 

FOO has a powerful, built-in **Package Manager**. You don't need to install separate tools like npm, pip, or cargo. The `foo` command handles everything for you, from downloading dependencies to publishing your own creations.

Let’s look at how the FOO package ecosystem works.

---

## 1. The Project Manifest (`project.json`)

Every FOO project is defined by a `project.json` file in the root directory. Think of this as the "ID card" for your project. It tells the compiler who you are, what version you are, and what other code you need to run.

```json
{
  "name": "my_awesome_app",
  "version": "1.0.0",
  "language": "1",
  "dependencies": {
    "http_client": "registry+http_client@1.2.0",
    "math_utils": "git+https://github.com/user/math_utils.git"
  }
}
```

---

## 2. Adding Dependencies

You can add new libraries to your project using the `foo add` command. FOO supports three types of dependency sources:

### A. The Official Registry (`registry+`)
This is the safest and fastest way. Packages are downloaded from the official FOO registry, cryptographically signed, and verified.
```sh
foo add http_client registry+http_client@1.2.0
```

### B. Git Repositories (`git+`)
If a library is hosted on GitHub or GitLab, you can pull it directly from the repository.
```sh
foo add math_utils git+https://github.com/user/math_utils.git
```

### C. Local Folders (`path+`)
If you are working on two projects at the same time, you can link them together locally.
```sh
foo add my_library path+../my_library
```

---

## 3. The Lockfile (`foo.lock`)

When you run `foo install`, FOO downloads your dependencies and creates a **Lockfile** (`foo.lock`).

**Why this is awesome:**
The lockfile records the *exact* cryptographic hash of every single file in your dependencies. This guarantees that if you send your project to a friend, they will get the *exact same code* you used. No more "but it works on my machine!" surprises.

```sh
foo install
```

---

## 4. Publishing Your Code

When you are ready to share your library with the world, FOO makes it easy.

### Step 1: Sign Your Package
FOO uses cryptographic keys to ensure that packages haven't been tampered with. You generate a private key, and FOO uses it to sign your release.

### Step 2: Publish
Run the publish command. FOO will bundle your `.iv` files, sign them, and upload them to the registry.

```sh
foo publish --key my_private_key.pem
```

---

## 5. Vendoring (Offline Mode)

Sometimes you need to build your project on a computer with no internet connection (like a secure server or a spaceship). FOO supports **Vendoring**.

This command downloads all your dependencies and stores them directly inside your project folder, so you can build anywhere.

```sh
foo vendor
```

---

## Summary: The Package Philosophy

FOO’s package system is designed to be **Secure** and **Reproducible**.
*   **Signed Packages:** You know exactly who wrote the code.
*   **Locked Versions:** You know exactly what code is running.
*   **Native Integration:** It’s all built into the `foo` command.

In the next chapter, we will look at the **Compiler**, where we will peek under the hood to see how FOO turns your English sentences into lightning-fast machine code!