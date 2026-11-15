# CJK Spacing

Adds spaces between Chinese or Japanese characters and Latin letters or digits.
Code fences, inline code, formulas, Markdown link targets, wiki links, HTML,
bare URLs, tags, reference definitions, and YAML front matter are preserved.

Use **Extensions -> Add spaces between CJK and Latin**. The extension settings
choose independent space counts from CJK to Latin and Latin to CJK, from 0 to
4. Existing spaces are normalized to the configured count; setting a direction
to 0 removes those spaces.

Japanese kana and digits/percent signs can be included or excluded
independently through the same settings page.

The whole operation is applied as one editor transaction, so Ctrl+Z restores
the previous document text in one step.

