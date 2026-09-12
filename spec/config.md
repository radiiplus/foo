# Configuration Schema (MVL-1)

## `config.json`
Defines the project. No scripting. Declarative only.
```json
{
  "name": "string",
  "version": "string",
  "language": "1",
  "build": {
    "type": "exe" | "lib",
    "target": ["string"],
    "optimize": "dev" | "release",
    "link": {
      "libs": ["string"],
      "frameworks": ["string"]
    },
    "c": {
      "sources": ["string"],
      "include": ["string"]
    },
    "asm": ["string"],
    "config": { "key": "value" },
    "codegen": [
      { "command": "string", "inputs": ["string"], "outputs": ["string"] }
    ],
    "resources": ["string"],
    "bin": ["string"],
    "test": {
      "include": ["string"],
      "exclude": ["string"]
    }
  },
  "dependencies": {
    "name": "version_string"
  }
}
```

## `lock.json`
Guarantees reproducible builds. Generated and managed by the toolchain.
```json
{
  "version": "1",
  "packages": [
    {
      "name": "string",
      "version": "string",
      "source": "url_or_path",
      "hash": "string"
    }
  ]
}
```