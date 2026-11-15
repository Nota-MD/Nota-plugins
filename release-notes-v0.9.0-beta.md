# Nota Plugins 0.9.0-beta

This release expands the official collection and updates the AI and writing
statistics extensions.

## New extensions

- **Backlinks** lists incoming, outgoing and unresolved links for the current
  document.
- **CJK Spacing** normalizes configurable spacing between Chinese/Japanese text
  and Latin text while preserving protected inline content and undo.

## AI assistant 0.1.2

- “Stream output” now accepts OpenAI Chat Completions, Responses, Anthropic-style
  deltas and Ollama NDJSON.
- Endpoints that ignore or reject streaming automatically fall back to a normal
  response.
- Legacy response shapes and error frames are handled without silently losing
  the answer.

## Writing Stats 0.7.0

- Share cards expose host-rendered settings for title, subtitle, metric label,
  footer text and date visibility.
- Round, daily and long-term cards use the same configurable identity and copy.

All packages target host API 2. Some packages remain unsigned; Nota reports that
state explicitly during installation.
