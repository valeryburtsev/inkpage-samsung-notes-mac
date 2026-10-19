#!/bin/bash
# Build or test with compact output: only errors, warnings from our sources, and the summary.
#   ./build.sh           build everything
#   ./build.sh test      run the tests
#   ./build.sh test Name run tests matching a filter
cd "$(dirname "$0")"
clean() { sed -E 's/\x1b\[[0-9;]*m//g' | grep -vE "swift-frontend|^\[|Failed frontend|SwiftCompile normal|^ *\|" | cut -c1-300; }
if [ "${1:-build}" = "test" ]; then
  swift test ${2:+--filter "$2"} 2>&1 | clean | grep -E "error:|warning: .*(Sources|Tests)/|Executed [0-9]+ tests|failed|XCTAssert|Build complete|Build failed" | sed -E 's#^.*/app/##' | tail -${LINES_MAX:-40}
else
  swift build 2>&1 | clean | grep -E "error:|warning: .*Sources/|Build complete|Build failed" | sed -E 's#^.*/app/##' | sort -u | tail -${LINES_MAX:-40}
fi
