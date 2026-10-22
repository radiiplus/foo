# Documentation Policy

## Purpose

This policy defines how repository documentation is structured, written,
validated, maintained, and retired. It applies to repository-maintained
Markdown, including the user book, specifications, benchmarks, contribution
guides, and agent instructions. The goals are technical accuracy, clear
navigation, minimal duplication, and current guidance that matches the current
FOO project.

## Source of truth

Each subject MUST have one authoritative location:

- `docs/` explains how to understand and use FOO.
- `specs/` defines formal language, compiler, runtime, toolchain, and
  compatibility contracts.
- `benchmark/` contains benchmark inputs, controls, and measurement policy;
  run data remains in ignored `.artifacts/`.
- `CHANGELOG.md` records pending notable changes.
- `README.md` provides the project overview and entry points.
- `AGENTS.md` and `CONTRIBUTING.md` direct contributors to applicable policies.

Other documents MUST link to the authoritative source instead of copying its
full contents. When documents disagree, identify the intended contract, verify
implementation behavior, and correct the conflict. A specification describes
intended behavior; it does not prove that the current compiler implements it.

## Structure

Before creating a document, determine whether its content belongs in an
existing document. A new file MUST have a distinct, durable purpose that cannot
be served clearly by a section in an existing file. Merge documents explaining
the same subject at the same level; retain separate files for different
audiences or independent contracts. Do not create files solely to mirror source
directories, compiler modules, or individual commits.

## User documentation

User documentation MUST prioritize practical understanding. Begin with the
purpose and expected outcome. Explain unfamiliar concepts, use working examples
and realistic workflows, state relevant prerequisites, and explain common
errors where useful. Link to specifications for exact rules and edge cases.
Avoid compiler internals unless they help users accomplish a task. Do not
reproduce complete grammar, data layouts, ABI definitions, or implementation
audits in the user book.

## Specifications

Specifications MUST define precise, testable contracts. Where applicable they
cover scope, terminology, behavior, invariants, syntax, types, constraints,
evaluation, ownership, lifetime, errors, compatibility, edge cases, failure
behavior, conformance tests, and related specifications. Distinguish normative
requirements from informative explanation. `MUST` and `MUST NOT` are binding;
`SHOULD` and `SHOULD NOT` allow justified exceptions; `MAY` permits an option.
Do not weaken or omit a rule to shorten a document. Include implementation
details only when they define a required contract; put incidental details in
implementation notes or source comments.

## Benchmark documentation

Benchmark documentation MUST be concise and evidence-driven. Every published
performance claim MUST identify its workload, baseline, environment, method,
and result. Include sample counts, variability, uncertainty, or raw data when
they affect interpretation or reproduction. Separate measurements from
hypotheses and conclusions. Qualify narrow findings; do not claim broad gains
from one workload. Keep run data and reproduction instructions in ignored
artifacts; remove unsupported claims from active documentation.

## Accuracy and evidence

Documentation MUST reflect verified behavior. Before claiming support for a
feature, platform, backend, API, or optimization, check implementation and
tests. Label claims as implemented and verified, implemented but incompletely
verified, proposed, or unsupported when useful. Do not present
plans, assumptions, or specification intent as established implementation.
Commands and examples SHOULD be run against the relevant version. State gaps
that materially limit a claim.

## Writing and formatting

- Use descriptive headings, direct language, and one principal idea per
  paragraph.
- Define specialized terms before using them.
- Use fenced code blocks with language identifiers where applicable.
- Use tables for structured comparisons, lists for independent items, and
  ordered lists for sequences.
- Link to canonical documents instead of duplicating them.
- Avoid filler, repeated introductions, decorative formatting, and unnecessary
  summaries.
- Keep filenames stable and terminology consistent.
- Give new user-guide Markdown files a single-word stem. Prefer an existing
  single-word guide when merging related pages.

Documents SHOULD be as short as possible without losing completeness,
precision, or usability.

## Retirement

Removed or superseded functionality MUST NOT remain in the active reading path
as current guidance. Before retiring a document, identify unique information
and inbound links, move still-valid requirements to their canonical destination,
update indexes and cross-references, and verify that active guidance no longer
depends on the retired file. Do not keep an archive of obsolete documentation.

## Maintenance

A documentation change MUST update affected links and indexes. An
implementation change requires review of the relevant specification, user
guide, tests, benchmark claims, and changelog. Avoid unrelated documentation
churn. Review changes for accuracy, consistency, duplication, stale claims,
and broken links.

For repository-wide restructuring, first make a file-by-file migration plan.
Record each file's action, reason, destination, unique content to preserve, and
link updates. Establish authority and resolve conflicts before rewriting.
Carry out reviewed stages, validate each stage, and report retained, merged,
and removed files. Do not delete a current contract just to reach a file-count
target.

## Completion criteria

A documentation change is complete when content is in the right authoritative
location; no unnecessary duplication was introduced; technical claims have
implementation, test, or cited evidence; examples and commands were validated
where applicable; links and navigation work; obsolete guidance is removed;
and this policy is followed. Contributors and coding agents
MUST follow this policy when changing documentation.
