import { readFileSync } from "node:fs";

let passed = 0;

function check(condition, message) {
  if (!condition) throw new Error(message);
  passed += 1;
}

const path = (id) => `plugins/vim/profiles/${id}.json`;
const classic = JSON.parse(readFileSync(path("classic-bsd-vi"), "utf8"));
const modern = JSON.parse(readFileSync(path("modern-vim"), "utf8"));
const manifest = readFileSync("plugins/vim/plugin.toml", "utf8");
const main = readFileSync("plugins/vim/main.lua", "utf8");

check(manifest.includes('"editor.input"'), "manifest requests the editor input capability");
check(main.includes('"editor_input_profile"'), "plugin exposes the adapter profile command");
check(main.includes('"editor-input-profile"'), "plugin emits profile changes");

check(classic.schema === 1, "classic profile schema");
check(classic.id === "classic-bsd-vi", "classic profile id");
check(classic.features.compatible === true, "classic profile is compatible");
check(classic.features.modes.visual === false, "vi has no visual mode");
check(classic.features.modes.visualBlock === false, "vi has no visual block");
check(classic.features.textObjects === false, "vi has no text objects");
check(classic.features.undoLevels === 1, "vi has one undo level");
check(classic.features.redo === false, "vi has no redo command");
check(classic.features.arrowKeys === false, "vi makes no arrow-key promise");
check(classic.features.macroRecording === false, "q recording is Vim-only");
check(classic.mappings.normal.h === "move.left", "classic h motion");
check(classic.mappings.normal.G === "move.documentLine", "classic G motion");
check(classic.mappings.normal.gg === undefined, "classic vi has no gg");
check(classic.mappings.normal.v === undefined, "classic vi has no v command");
check(classic.mappings.normal.u === "history.undo", "classic undo");
check(classic.mappings.normal.U === "history.restoreLine", "classic line undo");
check(classic.mappings.normal["/"] === "search.forward", "normal / searches forward");
check(classic.mappings.insert["/"] === undefined, "insert / remains literal input");
check(classic.mappings.insert["<Esc>"] === "mode.normal", "classic leaves insert mode");

check(modern.schema === 1, "modern profile schema");
check(modern.id === "modern-vim", "modern profile id");
check(modern.extends === "classic-bsd-vi", "modern inherits classic");
check(modern.features.compatible === false, "modern profile is not vi-compatible");
check(modern.features.modes.visual === true, "Vim visual mode");
check(modern.features.modes.visualLine === true, "Vim visual-line mode");
check(modern.features.modes.visualBlock === false, "visual-block is not implemented");
check(modern.features.textObjects === true, "Vim text objects");
check(modern.features.undoLevels === 1000, "Vim multi-level undo");
check(modern.features.redo === true, "Vim redo");
check(modern.features.macroRecording === true, "Vim macro recording");
check(modern.mappings.normal.gg === "move.documentStart", "Vim gg");
check(modern.mappings.normal.v === "visual.char", "Vim visual mode");
check(modern.mappings.normal["<C-r>"] === "history.redo", "Vim redo key");
check(modern.mappings.normal.q === "macro.recordToggle", "Vim macro recording");
check(modern.mappings.insert["<C-o>"] === "insert.oneNormalCommand", "Vim insert Ctrl-O");
check(modern.mappings.visual.d === "operator.delete", "Vim visual delete");

console.log(`ALL PASS（${passed} assertions）`);
