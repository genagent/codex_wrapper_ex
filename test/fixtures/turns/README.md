# Turn fixtures

Both NDJSON fixtures are **synthetic**, not captured from a provider run.
The five usage field names follow the codex-cli 0.165.0 binary's JSON event
fields recorded in issue #150. Event envelopes follow the synthetic
`fake_codex_structured` fixture based on @openai/codex-sdk 0.164.0.

- `0.165.0-completed.ndjson`: ordinary text completion with all five usage
  fields, including an explicit zero. `future_tokens` is an invented unknown
  field used to verify that raw events retain fields outside the projection.
- `0.165.0-invalid-usage.ndjson`: deliberately invalid usage values to verify
  that the typed projection rejects negatives, strings, floats, booleans,
  and null without altering raw event data.
