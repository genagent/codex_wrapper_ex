# Changelog

## [0.4.0](https://github.com/genagent/codex_wrapper_ex/compare/v0.3.0...v0.4.0) (2026-07-29)


### ⚠ BREAKING CHANGES

* the `%Exec{}` `:search` field is now a mode atom (`:cached`, `:indexed`, `:live`, `:disabled`) or nil, where it was a boolean defaulting to false. The emitted argument changes from `--search` to `-c web_search="<mode>"`. `Exec.search/1` is unchanged for callers and now means `web_search="live"`.
* Exec.approval_policy/2 no longer accepts :on_failure, which the Codex CLI dropped along with the --ask-for-approval flag. Valid policies are :untrusted, :on_request and :never. The emitted argument changes from `--ask-for-approval <policy>` to `-c approval_policy="<policy>"`.
* CodexWrapper.Commands.Fork is removed. `codex fork` is an interactive TUI command that cannot be driven non-interactively, so the module never worked against codex-cli 0.14x. Use CodexWrapper.ExecResume to continue a session in place; there is no non-interactive way to branch one.

### Features

* add --profile to the Exec builder ([#73](https://github.com/genagent/codex_wrapper_ex/issues/73)) ([20610f2](https://github.com/genagent/codex_wrapper_ex/commit/20610f2fa2993ce9f17d5f10f27a490bf2baf78c))
* add :telemetry events for exec/stream/review/session lifecycle ([#47](https://github.com/genagent/codex_wrapper_ex/issues/47)) ([514ddb5](https://github.com/genagent/codex_wrapper_ex/commit/514ddb5989138c154ff346a6904d417bdced3be2)), closes [#46](https://github.com/genagent/codex_wrapper_ex/issues/46)
* add Commands.Archive for codex archive, unarchive, and delete ([#78](https://github.com/genagent/codex_wrapper_ex/issues/78)) ([7d562f8](https://github.com/genagent/codex_wrapper_ex/commit/7d562f81b4b6ee1f610838cc05ebb42bfe17f15a))
* add Commands.Doctor for codex doctor ([#76](https://github.com/genagent/codex_wrapper_ex/issues/76)) ([9a8324e](https://github.com/genagent/codex_wrapper_ex/commit/9a8324e87b234e1db0dc979f6ae0b3181e27bf99))
* add config-isolation and trust flags to the exec builders ([#79](https://github.com/genagent/codex_wrapper_ex/issues/79)) ([e52202c](https://github.com/genagent/codex_wrapper_ex/commit/e52202c3dfd0448cefecd53c97f7ea0d0474f469)), closes [#65](https://github.com/genagent/codex_wrapper_ex/issues/65)
* add forcola runner for leak-free one-shot codex execution ([#50](https://github.com/genagent/codex_wrapper_ex/issues/50)) ([732f2de](https://github.com/genagent/codex_wrapper_ex/commit/732f2defbdc44cb73c29fad0cfdb92d90abad0ff))
* add mcp login/logout and OAuth options to Commands.Mcp ([#77](https://github.com/genagent/codex_wrapper_ex/issues/77)) ([8220799](https://github.com/genagent/codex_wrapper_ex/commit/82207992354256acc14ec46fa1e0c1797dd7ca95)), closes [#61](https://github.com/genagent/codex_wrapper_ex/issues/61)
* add output_schema to the Review builder ([#74](https://github.com/genagent/codex_wrapper_ex/issues/74)) ([f29f032](https://github.com/genagent/codex_wrapper_ex/commit/f29f032ebe9be079e7f2459c0fc6e770887c67ad)), closes [#59](https://github.com/genagent/codex_wrapper_ex/issues/59)
* route one-shot execution through a Runner with optional forcola ([#49](https://github.com/genagent/codex_wrapper_ex/issues/49)) ([9a2fdd2](https://github.com/genagent/codex_wrapper_ex/commit/9a2fdd2c723573b4287646b10ac2df3b97e52c2f)), closes [#48](https://github.com/genagent/codex_wrapper_ex/issues/48)
* stream NDJSON through the Runner, with a forcola-backed path ([#82](https://github.com/genagent/codex_wrapper_ex/issues/82)) ([0ca61de](https://github.com/genagent/codex_wrapper_ex/commit/0ca61de29d8ac853cace7b10ce0ce5c3642ff86a))
* support codex login --with-access-token ([#75](https://github.com/genagent/codex_wrapper_ex/issues/75)) ([b9709f2](https://github.com/genagent/codex_wrapper_ex/commit/b9709f2f672ad105968838ca47f4b77001db1c66)), closes [#60](https://github.com/genagent/codex_wrapper_ex/issues/60)


### Bug Fixes

* emit approval_policy as a -c config key, not --ask-for-approval ([#69](https://github.com/genagent/codex_wrapper_ex/issues/69)) ([e8f5bf5](https://github.com/genagent/codex_wrapper_ex/commit/e8f5bf5682a198426d6de2dabcbf5f2f4535bfbd))
* emit sandbox_mode config override on ExecResume and Review ([#81](https://github.com/genagent/codex_wrapper_ex/issues/81)) ([83c8ba4](https://github.com/genagent/codex_wrapper_ex/commit/83c8ba4e9ad15988253782f9b47b9f7c659fa68c)), closes [#80](https://github.com/genagent/codex_wrapper_ex/issues/80)
* emit web search as a -c config key, not --search ([#70](https://github.com/genagent/codex_wrapper_ex/issues/70)) ([439a87d](https://github.com/genagent/codex_wrapper_ex/commit/439a87d18af24a4cecf7f0e53c75d86ac83af564))
* remove Commands.Fork, codex fork is TUI-only ([#68](https://github.com/genagent/codex_wrapper_ex/issues/68)) ([7d0e1ef](https://github.com/genagent/codex_wrapper_ex/commit/7d0e1ef3fa1caceaa643b0e4b264edab40f61ead))
* rewrite Commands.Sandbox for the flat codex sandbox CLI ([#67](https://github.com/genagent/codex_wrapper_ex/issues/67)) ([cdda80c](https://github.com/genagent/codex_wrapper_ex/commit/cdda80cbecdba49c5c74f9b71868dd5402f2552a)), closes [#56](https://github.com/genagent/codex_wrapper_ex/issues/56)
* translate full_auto to --sandbox workspace-write ([#71](https://github.com/genagent/codex_wrapper_ex/issues/71)) ([a26bdec](https://github.com/genagent/codex_wrapper_ex/commit/a26bdec5d1cd7cd1407e439546e734fffab22252)), closes [#55](https://github.com/genagent/codex_wrapper_ex/issues/55)

## [0.3.0](https://github.com/genagent/codex_wrapper_ex/compare/v0.2.3...v0.3.0) (2026-04-11)


### Features

* add Config, Command behaviour, and binary discovery ([bbda01e](https://github.com/genagent/codex_wrapper_ex/commit/bbda01ed8abac909219d1bfcdf800d84abf47697))
* add Config, Command behaviour, and binary discovery closes [#1](https://github.com/genagent/codex_wrapper_ex/issues/1) ([9b56452](https://github.com/genagent/codex_wrapper_ex/commit/9b564521b59c7a233846d3739df7d28cf7e47bc6))
* add Exec command, Result struct, and convenience API ([4468180](https://github.com/genagent/codex_wrapper_ex/commit/4468180d86ca3ff08c4e4b830da38370d435bede))
* add Exec command, Result struct, and convenience API closes [#2](https://github.com/genagent/codex_wrapper_ex/issues/2) ([4a9bc5b](https://github.com/genagent/codex_wrapper_ex/commit/4a9bc5b4794c96ae86cf9adedbad7c3f83c6a391))
* add JsonLineEvent, execute_json/2, and stream/2 ([f42eff8](https://github.com/genagent/codex_wrapper_ex/commit/f42eff88f084158c0780156cd5eb56db447224d0))
* add JsonLineEvent, execute_json/2, and stream/2 closes [#3](https://github.com/genagent/codex_wrapper_ex/issues/3) ([f92cd07](https://github.com/genagent/codex_wrapper_ex/commit/f92cd07a663463fb4db378b29c280d4db34af78b))
* Auth, Version, MCP, and Features commands ([4ed2259](https://github.com/genagent/codex_wrapper_ex/commit/4ed2259f7de0add99584777acf3a248bd41e5609))
* **commands:** add Sandbox, Fork, and Apply commands closes [#13](https://github.com/genagent/codex_wrapper_ex/issues/13) ([#21](https://github.com/genagent/codex_wrapper_ex/issues/21)) ([c6b9948](https://github.com/genagent/codex_wrapper_ex/commit/c6b99484a674af771484cb71d5fa3c14bb386320))
* **completion:** add shell completion script generation closes [#18](https://github.com/genagent/codex_wrapper_ex/issues/18) ([#20](https://github.com/genagent/codex_wrapper_ex/issues/20)) ([2029753](https://github.com/genagent/codex_wrapper_ex/commit/2029753e2eefb950c0bcb741995fbe2b4c2630db))
* **mcp_server:** add McpServer command for codex mcp-server closes [#14](https://github.com/genagent/codex_wrapper_ex/issues/14) ([#22](https://github.com/genagent/codex_wrapper_ex/issues/22)) ([bb798c1](https://github.com/genagent/codex_wrapper_ex/commit/bb798c1d88e9789ed0f1713cfb526e30bf88604a))
* **package:** hex.pm publish prep closes [#17](https://github.com/genagent/codex_wrapper_ex/issues/17) ([#24](https://github.com/genagent/codex_wrapper_ex/issues/24)) ([80ff06e](https://github.com/genagent/codex_wrapper_ex/commit/80ff06e9fe9c503318e9cd947624700f0e30eb06))
* **review:** add Review command with builder and convenience API ([f20e883](https://github.com/genagent/codex_wrapper_ex/commit/f20e88362bbc055f5326e05af0ec2d2157f0b8b1))
* **review:** add Review command with builder and convenience API closes [#4](https://github.com/genagent/codex_wrapper_ex/issues/4) ([18a25d3](https://github.com/genagent/codex_wrapper_ex/commit/18a25d324250ab4ad515bf27c1b291fd5ddd74ea))
* Session and SessionServer for multi-turn ([17e254a](https://github.com/genagent/codex_wrapper_ex/commit/17e254aea4962e236b1e5433d62fb18bdd51f43f))
* **session:** add Session and SessionServer for multi-turn sessions ([99ec08a](https://github.com/genagent/codex_wrapper_ex/commit/99ec08a00d493d01c0166980f1410f93cfa23007)), closes [#5](https://github.com/genagent/codex_wrapper_ex/issues/5)


### Bug Fixes

* close stdin on streaming Port paths ([#38](https://github.com/genagent/codex_wrapper_ex/issues/38)) ([add5f29](https://github.com/genagent/codex_wrapper_ex/commit/add5f2995e873d9da00dc2b72d9771fd558c24e7)), closes [#37](https://github.com/genagent/codex_wrapper_ex/issues/37)
* extract thread_id from Codex events for Session.send multi-turn ([#41](https://github.com/genagent/codex_wrapper_ex/issues/41)) ([d43466d](https://github.com/genagent/codex_wrapper_ex/commit/d43466da1ce81c3c650f9f873aaea7b2e9b42e58)), closes [#40](https://github.com/genagent/codex_wrapper_ex/issues/40)
* update source URL to genagent org ([#42](https://github.com/genagent/codex_wrapper_ex/issues/42)) ([b6526b3](https://github.com/genagent/codex_wrapper_ex/commit/b6526b346ea24b25538dfacaadaad77aa357687c))
* use Port with closed stdin to prevent Codex CLI hang ([#34](https://github.com/genagent/codex_wrapper_ex/issues/34)) ([328ea18](https://github.com/genagent/codex_wrapper_ex/commit/328ea18d495407fb011756b46c5a35dc3e0ebba4)), closes [#33](https://github.com/genagent/codex_wrapper_ex/issues/33)
* **version:** mock binary in version test for CI compatibility closes [#27](https://github.com/genagent/codex_wrapper_ex/issues/27) ([#31](https://github.com/genagent/codex_wrapper_ex/issues/31)) ([41c6572](https://github.com/genagent/codex_wrapper_ex/commit/41c65721ca8510917c389bbc68bb4df58a766e24))

## [0.2.3](https://github.com/genagent/codex_wrapper_ex/compare/v0.2.2...v0.2.3) (2026-04-11)


### Bug Fixes

* update source URL to genagent org ([#42](https://github.com/genagent/codex_wrapper_ex/issues/42)) ([b6526b3](https://github.com/genagent/codex_wrapper_ex/commit/b6526b346ea24b25538dfacaadaad77aa357687c))

## [0.2.2](https://github.com/joshrotenberg/codex_wrapper_ex/compare/v0.2.1...v0.2.2) (2026-04-10)


### Bug Fixes

* close stdin on streaming Port paths ([#38](https://github.com/joshrotenberg/codex_wrapper_ex/issues/38)) ([add5f29](https://github.com/joshrotenberg/codex_wrapper_ex/commit/add5f2995e873d9da00dc2b72d9771fd558c24e7)), closes [#37](https://github.com/joshrotenberg/codex_wrapper_ex/issues/37)
* extract thread_id from Codex events for Session.send multi-turn ([#41](https://github.com/joshrotenberg/codex_wrapper_ex/issues/41)) ([d43466d](https://github.com/joshrotenberg/codex_wrapper_ex/commit/d43466da1ce81c3c650f9f873aaea7b2e9b42e58)), closes [#40](https://github.com/joshrotenberg/codex_wrapper_ex/issues/40)

## [0.2.1](https://github.com/joshrotenberg/codex_wrapper_ex/compare/v0.2.0...v0.2.1) (2026-03-31)


### Bug Fixes

* use Port with closed stdin to prevent Codex CLI hang ([#34](https://github.com/joshrotenberg/codex_wrapper_ex/issues/34)) ([328ea18](https://github.com/joshrotenberg/codex_wrapper_ex/commit/328ea18d495407fb011756b46c5a35dc3e0ebba4)), closes [#33](https://github.com/joshrotenberg/codex_wrapper_ex/issues/33)

## [0.2.0](https://github.com/joshrotenberg/codex_wrapper_ex/compare/v0.1.0...v0.2.0) (2026-03-31)


### Features

* add Config, Command behaviour, and binary discovery ([bbda01e](https://github.com/joshrotenberg/codex_wrapper_ex/commit/bbda01ed8abac909219d1bfcdf800d84abf47697))
* add Config, Command behaviour, and binary discovery closes [#1](https://github.com/joshrotenberg/codex_wrapper_ex/issues/1) ([9b56452](https://github.com/joshrotenberg/codex_wrapper_ex/commit/9b564521b59c7a233846d3739df7d28cf7e47bc6))
* add Exec command, Result struct, and convenience API ([4468180](https://github.com/joshrotenberg/codex_wrapper_ex/commit/4468180d86ca3ff08c4e4b830da38370d435bede))
* add Exec command, Result struct, and convenience API closes [#2](https://github.com/joshrotenberg/codex_wrapper_ex/issues/2) ([4a9bc5b](https://github.com/joshrotenberg/codex_wrapper_ex/commit/4a9bc5b4794c96ae86cf9adedbad7c3f83c6a391))
* add JsonLineEvent, execute_json/2, and stream/2 ([f42eff8](https://github.com/joshrotenberg/codex_wrapper_ex/commit/f42eff88f084158c0780156cd5eb56db447224d0))
* add JsonLineEvent, execute_json/2, and stream/2 closes [#3](https://github.com/joshrotenberg/codex_wrapper_ex/issues/3) ([f92cd07](https://github.com/joshrotenberg/codex_wrapper_ex/commit/f92cd07a663463fb4db378b29c280d4db34af78b))
* Auth, Version, MCP, and Features commands ([4ed2259](https://github.com/joshrotenberg/codex_wrapper_ex/commit/4ed2259f7de0add99584777acf3a248bd41e5609))
* **commands:** add Sandbox, Fork, and Apply commands closes [#13](https://github.com/joshrotenberg/codex_wrapper_ex/issues/13) ([#21](https://github.com/joshrotenberg/codex_wrapper_ex/issues/21)) ([c6b9948](https://github.com/joshrotenberg/codex_wrapper_ex/commit/c6b99484a674af771484cb71d5fa3c14bb386320))
* **completion:** add shell completion script generation closes [#18](https://github.com/joshrotenberg/codex_wrapper_ex/issues/18) ([#20](https://github.com/joshrotenberg/codex_wrapper_ex/issues/20)) ([2029753](https://github.com/joshrotenberg/codex_wrapper_ex/commit/2029753e2eefb950c0bcb741995fbe2b4c2630db))
* **mcp_server:** add McpServer command for codex mcp-server closes [#14](https://github.com/joshrotenberg/codex_wrapper_ex/issues/14) ([#22](https://github.com/joshrotenberg/codex_wrapper_ex/issues/22)) ([bb798c1](https://github.com/joshrotenberg/codex_wrapper_ex/commit/bb798c1d88e9789ed0f1713cfb526e30bf88604a))
* **package:** hex.pm publish prep closes [#17](https://github.com/joshrotenberg/codex_wrapper_ex/issues/17) ([#24](https://github.com/joshrotenberg/codex_wrapper_ex/issues/24)) ([80ff06e](https://github.com/joshrotenberg/codex_wrapper_ex/commit/80ff06e9fe9c503318e9cd947624700f0e30eb06))
* **review:** add Review command with builder and convenience API ([f20e883](https://github.com/joshrotenberg/codex_wrapper_ex/commit/f20e88362bbc055f5326e05af0ec2d2157f0b8b1))
* **review:** add Review command with builder and convenience API closes [#4](https://github.com/joshrotenberg/codex_wrapper_ex/issues/4) ([18a25d3](https://github.com/joshrotenberg/codex_wrapper_ex/commit/18a25d324250ab4ad515bf27c1b291fd5ddd74ea))
* Session and SessionServer for multi-turn ([17e254a](https://github.com/joshrotenberg/codex_wrapper_ex/commit/17e254aea4962e236b1e5433d62fb18bdd51f43f))
* **session:** add Session and SessionServer for multi-turn sessions ([99ec08a](https://github.com/joshrotenberg/codex_wrapper_ex/commit/99ec08a00d493d01c0166980f1410f93cfa23007)), closes [#5](https://github.com/joshrotenberg/codex_wrapper_ex/issues/5)


### Bug Fixes

* **version:** mock binary in version test for CI compatibility closes [#27](https://github.com/joshrotenberg/codex_wrapper_ex/issues/27) ([#31](https://github.com/joshrotenberg/codex_wrapper_ex/issues/31)) ([41c6572](https://github.com/joshrotenberg/codex_wrapper_ex/commit/41c65721ca8510917c389bbc68bb4df58a766e24))
