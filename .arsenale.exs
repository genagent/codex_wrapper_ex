%{
  preamble: """
  You are working on codex_wrapper_ex, an Elixir wrapper for the Codex CLI.
  Mirror the architecture of claude_wrapper (hex.pm/packages/claude_wrapper).
  Reference: /Users/joshrotenberg/Code/active/claude_wrapper_ex for API patterns.
  Reference: /Users/joshrotenberg/Code/active/codex-wrapper for the Rust codex-wrapper.
  """,
  preamble_files: ["README.md"],
  validation_commands: ["mix test", "mix compile --warnings-as-errors"],
  maestro: Arsenale.Maestro.Claude,
  max_turns: 30,
  gate_label: "arsenale"
}
