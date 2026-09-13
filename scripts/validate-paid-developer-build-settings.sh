#!/bin/bash

# hacky script because calling the rust project from xcode is a pain

if [ -z "$(which cargo)" ]; then
    echo "Cargo is not installed. Please install Rust and Cargo."
    exit 1
fi


cd "$(dirname "$0")" && cargo run --quiet --bin validate-paid-developer-build-settings