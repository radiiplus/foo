# Building Release Binaries

Use one command from the repository root:

```sh
npm run binaries
```

The command detects the host instead of pretending that a binary built for one
operating system will run on another.

| Host | Result |
| --- | --- |
| Windows x64 with WSL | Builds Windows locally, then builds Linux x64 and Linux ARM64 inside WSL. |
| Windows without WSL | Builds Windows and prints the `wsl --install -d Ubuntu-22.04` setup command. |
| Linux x64 | Builds Linux x64 natively and cross-builds Linux ARM64 with managed Zig. |
| Linux ARM64 | Builds Linux ARM64 natively. |

Output is staged under `release/foo-vVERSION/` using names such as
`foo-vVERSION-windows-x64` and `foo-vVERSION-linux-x64`. The existing installer
command consumes those directories:

```sh
npm run build:installers
```

That command refreshes the Windows installer and ZIP, both Debian packages,
both Linux TAR archives, the npm package, and `SHA256SUMS.txt`.

## Prerequisites

Windows builds require Node.js, Nim 2.2.12, Clang, and `llvm-rc`. The resource
compiler is included with standard LLVM installations and embeds
`installers/assets/logo-installer.ico` in `foo.exe`.

Linux and WSL builds require Node.js, Nim 2.2.12, Clang, and the OpenSSL
development package. The Linux ARM64 cross-build uses FOO's pinned managed Zig
toolchain. Debian packaging additionally requires `fakeroot`, `dpkg-deb`, and
`readelf`. These programs must be installed inside WSL, not only on Windows.

## Signing Linux

Linux executables use an armored detached OpenPGP signature. Keep the private
key outside this repository and set `FOOSIGNER` to its full fingerprint:

```sh
npm run key
```

Copy `.env.sign.example` to the ignored `.env.sign` file first, then set
`FOOSIGNEMAIL` and any optional identity, expiry, backup, public-output, WSL, or
GPG overrides there. The key generator creates a passphrase-protected Ed25519 signing key through
GPG and writes only its fingerprint to the ignored `.env.sign`. It exports the
release-safe public key to `release/foo-vVERSION/key.asc`, where it
is included in the release checksums. It also writes a recoverable key pair to
`Documents/FOO/keys/FINGERPRINT/` on Windows. That folder contains `private.asc`
and `public.asc`; it is outside the repository and must be copied to encrypted
offline storage. On Linux, the default backup root is
`~/.local/share/foo/keys/`. The private export remains protected by the GPG
passphrase chosen during generation.

When run on Windows, the generator uses GPG in the `Ubuntu-22.04` WSL
distribution. It reuses a matching existing secret key instead of creating
duplicates. Choose another backup directory through the environment file:

```text
FOOSIGNBACKUP=D:/secure/foo
```

Set `FOOWSL` to select another WSL distribution. Use `--unprotected` only for a
disposable automated environment whose keyring is already strongly protected.
The GPG passphrase is requested securely and must never be stored in `.env.sign`.
Preview the resolved identity and paths without creating or exporting a key with
`npm run key:preview`.

With the key ready, build and sign both Linux targets:

```sh
npm run binaries:signed
```

On PowerShell, set it for the process before running the command:

```powershell
$env:FOOSIGNER = "KEYFINGERPRINT"
npm run binaries -- --sign
```

To use an existing key instead, create `.env.sign` from `.env.sign.example`, set
its full fingerprint, and run:

```sh
npm run binaries:signed
```

The environment file contains only the key fingerprint. Import the private key
into GPG inside WSL; never place private-key material or a passphrase in the
environment file.

To restore the key on another machine, copy `private.asc` there and import it:

```text
gpg --import private.asc
```

For npm versions that consume spaced option values, use `--release=PATH`.

The signature is written beside the executable as `bin/foo.asc`. GPG obtains
the passphrase from its agent; scripts never accept or store a passphrase.
Verify a staged binary with:

```sh
npm run sign -- --verify release/foo-vVERSION/foo-vVERSION-linux-x64/bin/foo
```

ELF executables do not have a desktop-shell icon resource equivalent to a
Windows PE icon. The Debian package therefore installs the FOO SVG into the
system icon theme and includes a `.desktop` launcher and AppStream icon
metadata. The Windows executable receives the icon directly as a PE resource.
