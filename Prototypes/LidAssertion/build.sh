#!/bin/sh
# Builds the lid-assertion spike beside this file. CLT only, like everything else here.
set -eu
cd "$(dirname "$0")"
swiftc -O -o lid-assertion main.swift
echo "built: $(pwd)/lid-assertion"
