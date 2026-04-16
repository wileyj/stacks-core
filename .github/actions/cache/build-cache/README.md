# Build Nextest Archive Cache action

Builds the [nextest](https://nexte.st) archive cache for stacks-core tests

The action installs the Rust toolchain from the consuming repository's `rust-toolchain.toml` or `rust-toolchain` when present, otherwise it falls back to the setup action's default toolchain resolution (which is `stable`).

## Documentation

## Usage

```yaml
name: Action
on: push
jobs:
  build:
    name: Job
    runs-on: ubuntu-latest
    steps:
      - name: Test Archives
        id: test-archives
        uses: stacks-network/actions/stacks-core/cache/build-cache@main
```
