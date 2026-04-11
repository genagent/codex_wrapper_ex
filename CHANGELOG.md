# Changelog

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
