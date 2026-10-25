# Codex CLI compatibility

Verified on macOS arm64, 2026-10-24. Native CLI versions 0.149.0 and 0.164.0
were installed from exact npm versions in isolated task directories. Both native
contract runs passed. These two points are pinned in PR CI. Tracks #131.

The checker now selects CODEX_CONTRACT_BIN explicitly and can require an exact
CODEX_CONTRACT_VERSION. Closed-enum sentinels exercise actual config loading
instead of accepting --help, which bypasses it. exec fork gets a synthetic
required session id; invalid enum config stops before any session is read.
Free-form config probes are refused. Resume/review schema flags are included.

Five executable regression tests cover removed flags, a blind config probe,
unsafe free-form refusal, required fork parsing and positive config recognition.
All required format/compile/Credo/test/Dialyzer/docs checks passed.
Unit suite: Result: 512 passed, 4 excluded.

The first unchanged-source baseline had one 60-second echo/Port timeout. The exact
test passed in isolation and 100 bounded, eight-way echo calls passed. Later full
checks passed. This is not a demonstrated fix; #134 retains the failure and the
readiness/exit investigation. Production process behavior was not changed here.

These checks prove emitted flag/config compatibility, not every value or model
behavior. Existing controlled fixtures cover schema/results, sessions, streaming
and cleanup; no new authenticated native smoke is claimed.
