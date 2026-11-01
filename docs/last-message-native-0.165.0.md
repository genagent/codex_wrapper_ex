# Last-message native probe

Verified by the operator on macOS, 2026-11-01, with codex-cli 0.165.0.
Run outside any git repository:

```sh
codex exec --ephemeral --ignore-user-config --skip-git-repo-check \
  --model codex-wrapper-nonexistent-model -o <dir>/last.txt 'Reply with one word.'
```

The CLI started a session, warned that model metadata was not found, and
printed twice that the model is not supported when using Codex with a
ChatGPT account. It exited 1 without creating the `-o` file. With the
wrapper's pre-created owned file, the file remains empty and the returned
`{:process_failed, text, result}` carries `""` as its text.
