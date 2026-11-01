# Knowledge Graph

`nota.graph` builds an interactive graph from wiki links and relative Markdown
links in the current workspace. It is a read-only extension: the manifest asks
for `document.read`, `fs.read`, `ui.notify`, `ui.panel` and `ui.menu`.

## Use

1. Open a folder, or open a saved Markdown file. The graph uses the workspace
   root, falling back to the active document's folder.
2. Choose **Extensions → Open knowledge graph**.
3. The graph opens in the right-hand extension dock. Use the expand button in
   the dock header when you want the same panel in the editor-wide area.

The canvas supports wheel zoom, background dragging, node dragging, search,
adjacency highlighting and click-to-open. **Fit** restores the initial view.
From the full view, **Sidebar** moves the panel back to the dock.

## Link handling

- `[[Note name]]`, `[[Note name|label]]` and relative Markdown links are indexed.
- Links are resolved against the source file first, then by workspace-relative
  path and basename.
- Images, web URLs, fenced code and inline code are ignored.
- Unresolved links remain visible as hollow missing-note nodes.
- Duplicate basenames resolve deterministically after sorting paths.

## Limits

- Up to 800 Markdown files, 12 directory levels and 1 MiB per file.
- Up to 1,200 link targets are inspected while building edges.
- Hidden directories and common generated directories such as `.git`,
  `node_modules`, `target`, `dist` and `build` are skipped.
- The host accepts up to 800 nodes and 800 edges from a `network` block.

## Files

- `main.lua` — workspace walk, commands, menu and panel registration.
- `graph.lua` — pure link parsing, target resolution and graph construction.
- `lang/zh-CN.toml` — Chinese interface strings.

Run `bash tools/check.sh` from the repository root to execute the 13 graph
assertions together with the other extension checks.
