import std/[json, strutils]
import ../../src/config/image
import ../../src/pkg/hash

let schema = digest("foo.config.test/v1")
let data = %*{
  "name": "sample",
  "enabled": true,
  "maximum": 9223372036854775807'i64,
  "members": [1, "two", false],
  "nested": {"z": "last", "a": "first"}
}
let encoded = image.compile(data, schema)
doAssert encoded.startsWith("FCOI")
doAssert encoded.len > 73
let alternate = %*{
  "nested": {"a": "first", "z": "last"},
  "members": [1, "two", false],
  "maximum": 9223372036854775807'i64,
  "enabled": true,
  "name": "sample"
}
doAssert image.compile(alternate, schema) == encoded
try:
  discard image.compile(data, "bad-schema")
  doAssert false, "accepted invalid schema digest"
except ValueError as error:
  doAssert "expected a SHA-256 digest" in error.msg
echo "Configuration image emission: ok"
