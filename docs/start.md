# Chapter 2: Getting Started (Your First FOO Project)

Welcome to your first day writing FOO! Today, we are going to set up your computer, create a brand new project, and write some actual code. 

In many ecosystems, getting started means fighting with package managers, version conflicts, and messy environment setups. FOO completely eliminates that headache. It is distributed as a standalone, native application. You just install it, and it works.

Let’s get building!

---

## 1. The Magic Setup

First, head over to the official FOO Releases page and download the installer for your operating system (Windows, macOS, or Linux). Linux PCs use `foo-amd64.deb`, while ARM64 Linux systems use `foo-arm64.deb`. Run the installer, and within seconds, the `foo` command will be available in your terminal.

For Ubuntu running through Termux/proot on an ARM64 Android device, open the Ubuntu session and confirm `uname -m` prints `aarch64`. Install the ARM package there with `sudo apt install ./foo-arm64.deb`. This package is built for Ubuntu's glibc environment and will not run directly in Termux's Android environment.

Once it's installed, open your terminal (Command Prompt/PowerShell on Windows, or Terminal on Mac/Linux) and type this magic command:

```sh
foo doctor
```

**Why this is useful:** `foo doctor` runs a complete health check on your computer. The Debian installer provisions the pinned Zig backend automatically, and `foo run` or `foo build` retries that managed installation on first use when setup happened offline. `foo doctor` reports what is ready and gives the exact repair command when something is missing. Clang is optional unless a project imports C headers.

### Uninstalling FOO

On Windows, uninstall FOO from **Settings > Apps > Installed apps** or use the
**Uninstall FOO** shortcut in the FOO Start Menu group. On Ubuntu and Debian,
run `sudo apt remove foo`. The uninstallers remove the compiler and its
installer-managed backend without deleting projects or `~/.foo` user data.

---

## 2. Creating Your First Project

Let’s create a dedicated folder for our new app. FOO has a built-in **Scaffolding** tool (a command that instantly generates a clean, perfectly organized folder structure for you).

```sh
foo new my-first-app
cd my-first-app
```

If you look inside `my-first-app`, you’ll see a `project.json` file and `src/main.iv`. The `.iv` extension stands for FOO source code, and application source lives under `src/` by default.

---

## 3. Writing Your First Sentences

Open `src/main.iv` in your favorite code editor. Let’s write a program that greets the user.

Because FOO’s **Parser** (the brilliant part of the compiler that reads your code) is designed to understand natural, flowing sentences, you don't need to clutter your screen with messy semicolons or excessive parentheses. 

Type this out:

```foo
function greet(name text) {
  display "Hello, " plus name plus "!".
}

constant myName is "vibes".
greet(myName).
```

### Let’s break down the brilliance here:
*   **`name text`**: FOO is strictly **Typed** (meaning it keeps strict track of what kind of data is stored in a variable, preventing math errors on text), without repeating `of type` in parameter lists.
*   **`plus`**: Instead of forcing you to use the `+` symbol for everything, FOO lets you use the English word `plus` to glue text together.
*   **Implicit completion**: A function that gives nothing can simply end; use `give` when returning a value.
*   **The Period (`.`)**: Notice how every action ends with a period? FOO reads your code like a book. A period tells the parser, *"This specific thought is complete."*

---

## 4. Running Your App

Now for the best part. In your terminal, simply type:

```sh
foo run
```

**What happens underneath:** 
When you hit Enter, FOO doesn't just slowly interpret your code line-by-line. FOO’s **Multiple Build Backends** kick into gear. It translates your beautiful English sentences into hyper-fast Native C or Zig code. It looks at your specific CPU and applies **Optimization** (tweaking the math to run as fast as physically possible on your exact hardware), compiles it into a standalone executable, and runs it instantly.

You should see:
```text
Hello, vibes!
```

---

## 5. Growing Your App: Adding a Second File

As your app grows, you’ll want to split your code into multiple files to keep things organized. FOO handles this beautifully using **Namespaces** (invisible walls that keep the code in one file from accidentally messing up the code in another file).

Create a new file named `math.iv` and add this:

```foo
public function add(left integer, right integer) giving integer {
  give left plus right.
}
```
*Notice the word `public`? This is the only way to let other files see this function. If you leave `public` off, the function becomes private and completely invisible to the rest of your app. This prevents messy "spaghetti code" (where everything is tangled together and hard to track).*

Now, go back to `src/main.iv` and use it:

```foo
use "math.iv" as math. -- This brings in our new file!

constant total is math.add(10, 20).
when total is 30 { display "Total calculated". }
```

---

## 6. The World's Most Helpful Error Messages

Everyone makes typos. When you make a mistake in FOO, the compiler doesn't just crash and give you a confusing wall of red text. It acts like a helpful teacher.

Try changing your code to this mistake:
```foo
constant age is "twenty". -- Oops! We used text instead of a number.
```

Run `foo check`. FOO will point exactly to the mistake and tell you how to fix it:

```text
main.iv:2:18

  constant age is "twenty".
                  ^^^^^^^
  This value is text, but age needs an integer.
  Try: constant age is 20.
```
Fix the first error it points out, save the file, and run it again!

---

## 7. Your Daily Cheat Sheet

Here are the commands you will use every single day as a FOO programmer:

*   **`foo check`**: The Safety Inspector. It reads all your code and mathematically proves it is safe, but doesn't actually run it. Perfect for catching typos quickly.
*   **`foo build`**: The Factory. It compiles your code into a final, standalone, highly-optimized application file that you can share with others.
*   **`foo run`**: The Quick Test. Builds the app and immediately runs it so you can see the results.
*   **`foo watch`**: The Tireless Assistant. It sits in the background, and every single time you hit "Save" in your code editor, it automatically re-checks and re-builds your app instantly.
*   **`foo fmt`**: The Beautifier. It automatically reformats your code to ensure perfect spacing and indentation, so your code always looks professional.

---

You are now officially a FOO programmer! In the next chapter, we will dive deeper into the **Language** itself, exploring how FOO handles decisions, loops, and data.
