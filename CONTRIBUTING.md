# Contributing

Thanks for helping improve UsageRing.

## How to get started

```bash
git clone https://github.com/<OWNER>/<REPO>.git
cd <REPO>
make test
```

## Development setup

- macOS 14 or later
- Xcode / Swift 5.9+

## Making changes

- Keep behavior changes small and include test coverage in `Tests/` when practical.
- Keep public APIs and command-line behavior intentional and documented in the README.
- Use descriptive commit messages and short PR descriptions.

## Pull requests

1. Fork and create a feature branch.
2. Add/update tests for changed behavior.
3. Run `make test` locally.
4. Open a PR with:
   - what changed,
   - why it changed,
   - and any manual verification notes.

## Coding style

- Follow existing Swift style and naming conventions.
- Prefer explicit error handling and avoid force-unwraps unless guarded by strong invariants.
- Avoid silent failures; surface meaningful alerts/messages in UI flow.
