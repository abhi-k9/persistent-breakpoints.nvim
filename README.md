# Persistent breakpoints: maintenance fork

Persists nvim-dap breakpoints per canonical working directory. Requires Neovim
0.12+ and nvim-dap. This fork preserves ordinary, conditional, hit-count and
logpoint fields with validated, atomic storage and conflict detection.

```lua
require("persistent-breakpoints").setup({
  save_dir = vim.fn.stdpath("data") .. "/nvim_checkpoints",
})
```

The public API remains `persistent-breakpoints.api`: `toggle_breakpoint`,
`set_conditional_breakpoint`, `set_log_point`, `clear_all_breakpoints`,
`breakpoints_changed_in_current_buffer`, `store_breakpoints`,
`load_breakpoints`, and `reload_breakpoints`. Operations return save success
where relevant. `snapshot()` returns a recovery map and owned store filename.
`on_load_breakpoint` is supported. Loading follows BufReadPost, BufWinEnter,
SessionLoadPost and DirChanged automatically; legacy `load_breakpoints_event`
and `always_reload` options are no longer needed. `perf_record`/`print_perf_data`
and internal utils/inmemory/config modules are retired.

See [reliability, migration and recovery](doc/reliability.md) before upgrading.
Original legacy stores are retained, never overwritten. Conflicts require review;
unsaved memory should be exported before closing. No background polling or tool
installation occurs.

Tests use temporary directories and installed dependencies:

```sh
PLENARY_PATH=/path/to/plenary.nvim DAP_PATH=/path/to/nvim-dap \
  nvim --headless --noplugin -u NONE -l tests/run.lua
```

The lifecycle suite uses real DAP signs and controlled adapter boundaries.
Native Windows/macOS filesystem and live debuggee validation remain manual.
Upstream's MIT license remains in LICENSE.
