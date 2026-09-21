import ../../src/concurrency/backend
import ../../src/targets/presets

doAssert taskBackend("linux") == tbEpoll
doAssert taskBackend("macos") == tbKqueue
doAssert taskBackend("windows") == tbIocp
doAssert taskBackend("freestanding") == tbThreaded
doAssert taskBackendForTarget(resolve("linux-x64")) == tbEpoll
echo "concurrency backend parity: ok"
