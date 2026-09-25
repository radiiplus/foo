import ../../src/pkg/semver

doAssert satisfies("1.9.0", "^1.2.3")
doAssert not satisfies("2.0.0", "^1.2.3")
doAssert satisfies("0.2.9", "^0.2.3")
doAssert not satisfies("0.3.0", "^0.2.3")
doAssert satisfies("1.2.9", "~1.2.3")
doAssert not satisfies("1.3.0", "~1.2.3")
doAssert select(@["1.2.3", "1.9.0", "2.0.0"], @["^1.0.0", "~1.9.0"]) == "1.9.0"
doAssert select(@["1.2.3"], @["^2.0.0"]).len == 0
echo "semantic version constraints: ok"
