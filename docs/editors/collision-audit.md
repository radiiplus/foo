# Tratio `.rt` collision audit

Audit date: 2026-09-13 UTC. Naming is frozen in [naming.md](naming.md).
The captured [evidence.json](evidence.json) contains exact queries, responses,
Git tree inventories, sample paths, blob hashes, snippets, and measurements.

## Search coverage and limits

Four GitHub REST code searches were actually attempted:

| Query | HTTP status | Search total |
| --- | --- | --- |
| `extension:rt` | 401 | unavailable |
| `extension:rt "rt-if"` | 401 | unavailable |
| `extension:rt "module"` | 401 | unavailable |
| `extension:rt "<window"` | 401 | unavailable |

Each response said `Requires authentication`. There was no usable GitHub
credential in this environment. These are failed searches, not zero-result
searches. GitHub documents the authentication requirement in its
[code search API](https://docs.github.com/en/rest/search/search#search-code).

Public web search identified candidate repositories; their public Git Trees
API inventories provide the counts below. Consequently this audit quantifies
a bounded sample of GitHub usage, not GitHub-wide prevalence or market share.
The observed lower bound is **162 `.rt` paths across five repositories**, of
which **120 paths belong to other formats**. Counts are repository paths,
not deduplicated projects or globally unique file contents.

| Repository / family | All `.rt` paths | Selected | Classified |
| --- | ---: | ---: | ---: |
| [wix-incubator/react-templates](https://github.com/wix-incubator/react-templates) / React Templates | 86 | 40 | 40 |
| [magalhaesm/42-cursus-miniRT](https://github.com/magalhaesm/42-cursus-miniRT) / miniRT scenes | 20 | 20 | 20 |
| [Aprilistic/miniRT](https://github.com/Aprilistic/miniRT) / miniRT scenes | 8 | 8 | 8 |
| [radiiplus/tratio](https://github.com/radiiplus/tratio) / Tratio | 42 | 20 | 20 |
| [contact-discovery/rt_phone_numbers](https://github.com/contact-discovery/rt_phone_numbers) / rainbow tables | 6 | 6 | 0 |
| Total | 162 | 94 | 88 |

All five successful tree responses were non-truncated. Tree SHAs and every
counted path's blob SHA and size are recorded in the evidence, including paths
not selected for classification. The six rainbow files are each 16,000,000
bytes; they exceed the audit's 1 MiB download limit and are excluded from
heuristic scores. Their role as tables is documented by the
[project's generator and lookup instructions](https://github.com/contact-discovery/rt_phone_numbers#usage).

RealText is a further documented collision:
[ImageMagick's MIME registry](https://github.com/ImageMagick/ImageMagick/blob/main/config/mime.xml)
assigns `*.rt` to RealText. The attempted recursive inventory of
`SubtitleEdit/subtitleedit` timed out. It contributes no count or classified
sample here; RealText precision remains unmeasured.

## Representative content

These small excerpts come from immutable Git tree snapshots. The per-file
evidence gives the complete source URL and verifies its Git blob hash.

| Family | Representative excerpt | Source |
| --- | --- | --- |
| Tratio | `module path {` | [std/path.rt](https://raw.githubusercontent.com/radiiplus/tratio/00052d25f282733cf710f01e711cc2bbfd27b202/std/path.rt) |
| React Templates | `<div rt-scope="a in a in a">` | [invalid-scope.rt](https://raw.githubusercontent.com/wix-incubator/react-templates/becfc2b789c412c9189c35dc900ab6185713cdae/test/data/invalid/invalid-scope.rt) |
| miniRT | `A   0.1   255,255,255` | [images/img00.rt](https://raw.githubusercontent.com/magalhaesm/42-cursus-miniRT/4acd36124ea01c64932ae6cde438f4c56b5dbbd6/images/img00.rt) |
| Rainbow tables | Binary payload; no textual excerpt or classification | [table directory](https://github.com/contact-discovery/rt_phone_numbers/tree/bbcf83a93d30eb821b0ee41900fff7b5969f55f0/bin/out) |

React Templates contains HTML tags and `rt-` directives, including deliberately
invalid template fixtures. miniRT uses short scene identifiers such as `A`,
`C`, `L`, and `sp`, followed by numbers and comma-separated coordinates or
colors. Neither uses Tratio's module and declaration structure. RealText's
markup is a required future negative fixture, including captions that quote code.

The original batch's Arc Lisp comparison concerns `.arc`. This audit uses
Tratio's real `.rt` extension. Lisp forms such as `(def ...)`, `(mac ...)`,
and `fn[` are not positive Tratio signals; standalone Lisp forms cannot meet
the combined candidate's initial module requirement. No real Lisp sample was
measured in this `.rt` corpus, so no Lisp-specific precision is claimed.

## Candidate heuristic specification

Scope: classify a possible `.rt` file as Tratio or abstain. These candidates
are detection rules, not parsers or syntax validators. Do not use a bare
`match`, `test`, `function`, or `module` substring as sufficient evidence.

Preprocessing used for every measurement: inspect at most the first 65,536
bytes, decode strict UTF-8, reject NUL or undecodable prefixes, remove an
initial BOM, and normalize line endings. A UTF-8 character split by the prefix
boundary currently causes abstention. The download limit is an audit sampling
constraint, not a proposed maximum size for Tratio source files.

The following are the exact JavaScript regex bodies from [audit.mjs](audit.mjs).
Candidate A uses flag `m`; B and C use no flags.

### A: module declaration

```regex
^[ \t]*module[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t\r\n]*\{
```

Recognizes a module at the start of any line. Broadest structural candidate;
could match a code example embedded in a template or subtitle.

### B: language phrases

```regex
\b(?:give(?:[ \t]+[^.\r\n]*)?[ \t]*\.|(?:constant|mutable)[ \t]+[A-Za-z_][A-Za-z0-9_]*[^.\r\n]*\bis\b|function[ \t]+[A-Za-z_][A-Za-z0-9_]*[^{}\r\n]*\bof[ \t]+type\b|use[ \t]+c[ \t]+"[^"\r\n]+")
```

Recognizes return statements, declarations, typed functions, or C imports.
It can match prose, comments, or quoted code because it has no outer structure
requirement. Retained as a comparison, not the preferred production rule.

### C: initial module plus a declaration or statement

```regex
^(?:[ \t\r\n]|---[\s\S]*?---|--[^\r\n]*(?:\r?\n|$))*module[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t\r\n]*\{(?=[\s\S]*\b(?:give(?:[ \t]+[^.\r\n]*)?[ \t]*\.|function[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*(?:\[[^\]\r\n]+\][ \t]*)?\(|type[ \t]+[A-Za-z_][A-Za-z0-9_]*[^.\r\n]*\bis\b|(?:constant|mutable)[ \t]+[A-Za-z_][A-Za-z0-9_]*[^.\r\n]*\bis\b|use[ \t]+(?:c[ \t]+)?"[^"\r\n]+"|start[ \t]*\([ \t]*\)))
```

Preferred draft: require a module after leading whitespace or Tratio comments,
then at least one characteristic declaration, return, import, or entry point.
HTML or scene content before an embedded code example prevents a match.
Comments and strings inside the module are not lexically excluded, so this
is still a heuristic. An empty module, a fragment without a module, an
identifier outside the ASCII pattern, or a declaration beyond the scanned
prefix can yield a false negative. Ambiguous input should abstain, with editor
selection or project metadata providing the fallback.

## Measured results

Sampling is deterministic: sort paths by SHA-256 of their path and take at
most 40 per repository. Tratio positives are restricted to its public `std/`
directory (20 files), excluding diagnostic and IR fixtures from the other 22
paths. The negative sample contains 40 React Templates and 28 miniRT files.
Labels come from the repositories' documented purposes and selected paths.
This is a convenience corpus, not a random sample of GitHub or an independent
holdout. Local unpublished Tratio changes are not counted as GitHub usage.

| Candidate | Tratio hits / misses | Other-format hits / misses | Precision | Recall |
| --- | ---: | ---: | ---: | ---: |
| A: module | 20 / 0 | 0 / 68 | 100% | 100% |
| B: phrases | 20 / 0 | 0 / 68 | 100% | 100% |
| C: combined | 20 / 0 | 0 / 68 | 100% | 100% |

Here, an other-format hit is a false positive; a miss is a correct abstention.
Precision is TP / (TP + FP), and recall is TP / (TP + FN).
There are 88 distinct SHA-256 content hashes, so deduplication leaves the
results unchanged. These scores establish zero observed false positives in
this corpus, not a universal guarantee. In particular, binary rainbow tables,
RealText, Lisp, and unrelated undiscovered `.rt` formats have no measured score.

Candidate C is preferred for its structural restriction; this corpus does
not demonstrate a numerical advantage over A or B. Before the Linguist gate,
expand positives to applications, generics, comments, and minimal modules;
expand negatives to RealText, binary prefixes, and embedded Tratio quotations.
Keep new validation fixtures separate from those used to tune the rule.

Linguist's [heuristic definitions](https://github.com/github-linguist/linguist/blob/main/lib/linguist/heuristics.yml)
specify regex compatibility and rule ordering. These JavaScript results are
not Linguist-engine validation. When porting C, preserve absolute-start
semantics with `\A` where required rather than assuming `^` behaves identically
in Ruby. Run Linguist's compatibility checker and its fixture suite before
shipping an extension rule. TextMate's line-oriented tokenizer must not use
this whole-file regex as a grammar rule.

## Reproduction and gate

From the repository root, using a Node version with built-in `fetch`:

```sh
node docs/editors/audit.mjs --verify
node docs/editors/audit.mjs
node docs/editors/audit.mjs --refresh
```

`--verify` checks recorded file hashes, regex results, and confusion counts
against pinned source files without rewriting evidence. It uses the ignored
`.tratio/editor-audit/` response cache, downloading immutable sources when
absent. A normal audit reuses cached tree inventories and writes new evidence;
`--refresh` fetches current HEAD trees. Update the prose counts when refreshing.
Neither cached reruns nor verification constitute a fresh global survey.
The script uses `GITHUB_TOKEN` or `GH_TOKEN`, if already supplied, only for
GitHub API code searches; tokens are not written into evidence. Search totals
remain subject to GitHub's indexing limits even with authentication.

- [x] `.rt`, `tratio`, and `source.tratio` frozen in writing.
- [x] Bounded GitHub usage quantified with pinned inventories and excerpts.
- [x] Three candidates measured; preferred draft has 0/68 observed false positives.
- [ ] GitHub-wide code-search counts and broader collision coverage completed.
- [ ] Future Linguist gate: expanded corpus and actual engine compatibility tests.

Batch 0.1 therefore has a reviewable naming decision and measured initial
audit, but its unrestricted search requirement remains open. Authentication
and the missing RealText sample are explicitly recorded gaps, not inferred
successes.
