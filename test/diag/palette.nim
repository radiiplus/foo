import ../../src/diag/palette

doAssert shade("info", 1) == "\e[34m"
doAssert shade("error", 24) == "\e[38;2;255;56;100m"
echo "palette parity: ok"
