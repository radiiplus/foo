# Chapter 2: Getting Started (Your First FOO Project)

Welcome to your first day writing FOO! Today, we are going to set up your computer, create a brand new project, and write some actual code. 

In many ecosystems, getting started means fighting with package managers, version conflicts, and messy environment setups. FOO completely eliminates that headache. It is distributed as a standalone, native application. You just install it, and it works.

Let’s get building!

---

## 1. The Magic Setup

First, head over to the official FOO Releases page and download the installer for your operating system (Windows, macOS, or Linux). Linux PCs use `foo-amd64.deb`, while ARM64 Linux systems use `foo-arm64.deb`. Run the installer, and within seconds, the `foo` command will be available in your terminal.

For Ubuntu running through Termux/proot on an ARM64 Android device, open the Ubuntu session and confirm `uname -m` prints `aarch64`. Install the ARM package there with `sudo apt install ./foo-arm64.deb`. This package is built for Ubuntu's glibc environment (the standard runtime used by most Linux distributions) and will not run directly in Termux's Android environment.

Once it's installed, open your terminal (Command Prompt/PowerShell on Windows, or Terminal on Mac/Linux) and type this magic command:

```sh
foo doctor
```

**Why this is useful:** `foo doctor` runs a complete health check on your computer. The Debian installer provisions (downloads and configures) the pinned Zig backend (the exact supported Zig code generator) automatically, and `foo run` or `foo build` retries that managed installation on first use when setup happened offline. `foo doctor` reports what is ready and gives the exact repair command when something is missing. Clang is optional unless a project imports C headers.

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

The generated project is ready for application code, tests, and benchmarks:

```text
my-first-app/
├─ src/
│  └─ main.iv
├─ test/
│  └─ main.iv
├─ benchmark/
│  └─ main.iv
├─ project.json
└─ .gitignore
```

The `.iv` extension marks FOO source. Put the application in `src/`, correctness
checks in `test/`, and performance scenarios in `benchmark/`.

Open `project.json`. The important starting fields are deliberately explicit:

```json
{
  "source": "src",
  "entry": "src/main.iv",
  "entries": {}
}
```

`entry` is what plain `foo run` starts. You do not need to search the source
tree or rely on a guessed filename.

---

## 3. Writing Your First Sentences

Open `src/main.iv` in your favorite code editor. Let’s write a program that greets the user.

FOO uses a small sentence-like grammar. The parser does not guess arbitrary
English: parameters have declared types, calls use parentheses, and a period
ends each simple statement.

Type this out:

```foo
function greet(name text) {
  display "Hello, " plus name plus "!".
}

constant name is "vibes".
greet(name).
```

### Read the example
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
FOO checks the project, lowers it through the selected C or Zig backend, reuses
compatible cached work, builds a native executable, and runs it. A release build
may select target-specific runtime paths; development builds favor compilation
latency (build delay) and portable behavior. Use `foo run --explain` to see the selected path
and reason.

You should see:
```text
Hello, vibes!
```

### Adding another runnable program

Suppose the same project also has `src/worker.iv`. Give it a short command name
in `project.json`:

```json
{
  "source": "src",
  "entry": "src/main.iv",
  "entries": {
    "worker": "src/worker.iv"
  }
}
```

Now the commands are unambiguous:

```sh
foo run          # runs src/main.iv
foo run worker   # runs src/worker.iv
```

Each named entry is an ordinary FOO program. Use a short, memorable name; the
path stays in `project.json`, so nobody has to remember it.

---

## 5. Growing Your App: Adding a Second File

As your app grows, you’ll want to split your code into multiple files to keep things organized. FOO handles this beautifully using **Namespaces** (invisible walls that keep the code in one file from accidentally messing up the code in another file).

Create a new file named `math.iv` and add this:

<!-- snippet: project math src/math.iv -->
```foo
public function add(left integer, right integer) giving integer {
  give left plus right.
}
```
*Notice the word `public`? This is the only way to let other files see this function. If you leave `public` off, the function becomes private and completely invisible to the rest of your app. This prevents messy "spaghetti code" (where everything is tangled together and hard to track).*

Now, go back to `src/main.iv` and use it. This fragment depends on the
`math.iv` file created immediately above:

<!-- snippet: project math src/main.iv -->
```foo
use "math.iv" as math. -- This brings in our new file!

constant total is math.add(10, 20).
when total is 30 { display "Total calculated". }
```

---

## 6. The World's Most Helpful Error Messages

Everyone makes typos. When you make a mistake in FOO, the compiler doesn't just crash and give you a confusing wall of red text. It acts like a helpful teacher.

Try this deliberately invalid declaration:

<!-- snippet: error TypeMismatch -->
```foo
constant age of type integer is "twenty".
```

Run `foo check`. The compiler reports a `TypeMismatch` at `"twenty"`: the
annotation requires an integer, but the initializer is text. Replace it with an
integer such as `20`, then check again.

The official VS Code extension can do this check while you type. It starts
`foo lsp` automatically and places errors directly on the affected code. This
is different from `foo watch`: the language server powers editor diagnostics,
hover information, and go-to-definition, while `foo watch` continuously builds
the project in a terminal. If VS Code cannot find the compiler, set **FOO:
Server Path** to the `foo` executable.

---

## 7. Your Daily Cheat Sheet

Here are the commands you will use every single day as a FOO programmer:

*   **`foo check`**: Parses and type-checks the project without running it.
*   **`foo build`**: The Factory. It compiles your code into a final, standalone, highly-optimized application file that you can share with others.
*   **`foo run`**: The Quick Test. Builds the app and immediately runs it so you can see the results.
*   **`foo test`**: Runs the checks under `test/` and any test blocks in the project.
*   **`foo benchmark`**: Builds each program under `benchmark/` once, warms it up, and reports repeated timings.
*   **`foo watch`**: The Tireless Assistant. It sits in the background, and every single time you hit "Save" in your code editor, it automatically re-checks and re-builds your app instantly.
*   **`foo fmt`**: Rewrites source using the canonical FOO formatting rules.

---

You are now officially a FOO programmer! In the next chapter, we will dive deeper into the **Language** itself, exploring how FOO handles decisions, loops, and data.
