# FOO 0.8.1

FOO 0.8.1 makes console output simpler: `display` accepts integers, decimals,
booleans, and codec-supported structured values directly. Text remains verbatim.
The getting-started example now uses `display total.` and documents the exact
module layout.

CLI operations can use `--compact` for single-line progress. The detailed view
shows an approximate completion time only after enough consistent timing
samples are available. The registry UI wraps long source lines, and its
standard-library catalog includes the new `io.display` overload.

The release includes Windows and Linux x64/ARM64 packages, the npm archive,
the FOO source archive, checksums, and the existing foo.iv 2.7.0 editor extension.
