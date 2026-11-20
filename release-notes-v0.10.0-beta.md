# Nota Plugins 0.10.0-beta

This release focuses on the AI assistant and its integration with current Nota
hosts.

## Extension API contract

- Extension API versions now use `vMAJOR.MINOR`; the current host contract is
  `v2.3`.
- Minor versions remain backward compatible. Major versions may be incompatible.
- Incompatible manifests are rejected before installation or execution.
- Existing incompatible directories stay visible with a red error and produce
  one aggregate startup notification.
- Newer plugin APIs advise checking for a software update or contacting the
  developer; older major APIs advise contacting the developer.

## AI assistant 0.1.6

- Fixed real streaming by sending the required HTTP POST request. Endpoints such
  as DeepSeek returned HTTP 405 before, and the extension silently fell back to
  a complete response.
- Reasoning-first providers now stream their thinking state incrementally
  before the final answer.
- Added a persistent custom-preset editor with editable instructions and name.
- The preset editor is available without importing a file first; saving creates
  and activates the preset automatically.
- Added optional JSON, Markdown and plain-text preset import.
- Preset instructions are sent as explicit system context in every request.
- The built-in system prompt is concise English and treats the current document
  as authoritative, ignoring stale document excerpts from earlier turns.
- Assistant replies retain safe Markdown rendering for headings, emphasis,
  links, lists, tables and fenced code.

All packages target host API `v2.3`. Packages in this release may remain unsigned;
Nota reports that state explicitly during installation.
