#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "Compiling side-eye..."
swiftc -parse-as-library -O -o side-eye main.swift

echo "Done: ./side-eye ($(du -h side-eye | cut -f1 | xargs))"
