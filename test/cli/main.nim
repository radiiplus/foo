import ../../src/cli/main

doAssert main(@[]) == 2
doAssert main(@["version"]) == 0
doAssert main(@["unknown"]) == 2
echo "cli main parity: ok"
