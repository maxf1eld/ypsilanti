# Contributing to ypsilanti

Thanks for your interest in ypsilanti.

## Requirements

- [Zig](https://ziglang.org/download/) 0.14 or newer.

## Development

```
zig build                    # debug build to zig-out/bin/ypsilanti
zig build run -- serve ./example   # run without installing
./test.sh                    # build (ReleaseFast) and run the test suite
```

## Before opening a pull request

- Run `./test.sh` and make sure it passes. CI runs the same script.
- Add or update tests in `test.sh` when you change behavior.
- Keep changes focused and the diff minimal; match the surrounding style.

## Reporting bugs

Open an issue with a minimal site (`content/`, `layouts/`, config) that
reproduces the problem, the command you ran, and what you expected.

## Security

ypsilanti escapes template variables, sanitizes URL schemes, and validates
internal links at build time. If you find a way around these, please report it
privately by email rather than opening a public issue.
