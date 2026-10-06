local ot = require('overleaf.ot')
local config = require('overleaf.config')

local M = {}

--- Create a Neovim buffer for an Overleaf document
---@param doc table Document instance
---@param lines string[] document lines
---@return number bufnr
function M.create(doc, lines)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, require('overleaf.sync').buf_name(doc.path))

  -- Buffer options first
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].swapfile = false

  -- Set content
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false

  -- Clear undo history so 'u' doesn't wipe the buffer after initial load.
  -- Uses API calls instead of 'exe "normal a \<BS>\<Esc>"' to avoid
  -- literal garbage insertion when special keys aren't interpreted (Issue #5).
  local old_undolevels = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { ' ' })
  vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 1, { '' })
  vim.bo[bufnr].undolevels = old_undolevels
  vim.bo[bufnr].modified = false

  doc.bufnr = bufnr

  -- :w clears modified flag and triggers compile (changes are already synced via OT)
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = bufnr,
    callback = function()
      vim.bo[bufnr].modified = false
      require('overleaf').compile()
    end,
  })

  -- Attach change detection
  M.attach(bufnr, doc)

  -- Verify buffer matches doc.content after undo-clear
  -- (guards against Issue #5: exe 'normal a \<BS>\<Esc>' inserting garbage)
  doc:check_content()

  -- Open buffer in current window FIRST (so FileType autocmds fire on current buffer)
  vim.api.nvim_set_current_buf(bufnr)

  -- Editor window options
  local winnr = vim.api.nvim_get_current_win()
  vim.wo[winnr].wrap = true
  vim.wo[winnr].linebreak = true
  vim.wo[winnr].number = true

  -- Set filetype AFTER buffer is current (triggers FileType autocmds for treesitter, copilot, etc.)
  local ext = doc.path:match('%.([^%.]+)$')
  local ft_map = {
    tex = 'tex',
    sty = 'tex',
    cls = 'tex',
    bib = 'bib',
    bbl = 'tex',
    txt = 'text',
    md = 'markdown',
  }
  if ft_map[ext] then vim.bo[bufnr].filetype = ft_map[ext] end

  -- Start syntax highlighting and LSP
  config.log('debug', 'Buffer create: ext=%s ft=%s', tostring(ext), tostring(ft_map[ext]))
  if ft_map[ext] then
    -- treesitter language name differs from filetype (tex -> latex)
    local ts_lang_map = { tex = 'latex', bib = 'bibtex' }
    local lang = ts_lang_map[ft_map[ext]] or ft_map[ext]
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end

      local ok = pcall(vim.treesitter.start, bufnr, lang)
      if not ok then pcall(vim.cmd, 'syntax enable') end

      -- Attach LSP servers to overleaf buffer (lspconfig skips overleaf:// URIs)
      config.log('info', 'Attaching LSP for ft=%s bufnr=%d', ft_map[ext], bufnr)
      M._attach_lsp(bufnr, ft_map[ext])

      -- Run chktex linter for tex files
      if ft_map[ext] == 'tex' then
        M._run_chktex(bufnr)
        -- Re-lint on text changes (debounced)
        vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
          buffer = bufnr,
          callback = function() M._schedule_lint(bufnr) end,
        })
      end
    end)
  end

  return bufnr
end

--- Manually attach LSP servers to an Overleaf buffer
function M._attach_lsp(bufnr, ft)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- LSP language IDs differ from Neovim filetypes
  local lang_id_map = { tex = 'latex', bib = 'bibtex' }

  local servers = {}
  if ft == 'tex' or ft == 'bib' then
    table.insert(servers, {
      name = 'harper_ls',
      cmd = { 'harper-ls', '--stdio' },
      settings = {
        ['harper-ls'] = {
          linters = { spell_check = true, sentence_capitalization = false },
        },
      },
    })
    table.insert(servers, {
      name = 'ltex',
      cmd = { 'ltex-ls' },
      settings = { ltex = { language = 'en-US' } },
    })
    if ft == 'tex' then table.insert(servers, { name = 'texlab', cmd = { 'texlab' } }) end
  end

  -- Mason installs to ~/.local/share/nvim/mason/bin/
  local mason_bin = vim.fn.stdpath('data') .. '/mason/bin/'

  for _, srv in ipairs(servers) do
    local cmd = srv.cmd[1]
    -- Check system PATH and mason bin
    if vim.fn.executable(cmd) ~= 1 then
      local mason_cmd = mason_bin .. cmd
      if vim.fn.executable(mason_cmd) == 1 then srv.cmd[1] = mason_cmd end
    end
    -- Skip if command not found anywhere
    if vim.fn.executable(srv.cmd[1]) ~= 1 then
      config.log('debug', 'LSP %s not found, skipping', srv.name)
    else
      pcall(vim.lsp.start, {
        name = srv.name,
        cmd = srv.cmd,
        root_dir = vim.fn.getcwd(),
        settings = srv.settings,
        get_language_id = function(_, filetype) return lang_id_map[filetype] or filetype end,
      }, { bufnr = bufnr })
    end
  end
end

--- Is the byte at 1-based index i a UTF-8 continuation byte?
local function is_cont(s, i)
  local b = s:byte(i)
  return b ~= nil and b >= 0x80 and b < 0xC0
end

--- Compute the ops turning `old` into `new` as one delete + one insert,
--- from the longest common prefix and suffix (aligned to UTF-8 characters).
---@param old string
---@param new string
---@return table[] ops (0-based character offsets)
function M.diff_ops(old, new)
  if old == new then return {} end
  local lo, ln = #old, #new
  local max = math.min(lo, ln)

  local p = 0
  while p < max and old:byte(p + 1) == new:byte(p + 1) do
    p = p + 1
  end
  while p > 0 and (is_cont(old, p + 1) or is_cont(new, p + 1)) do
    p = p - 1
  end

  local sfx = 0
  while sfx < max - p and old:byte(lo - sfx) == new:byte(ln - sfx) do
    sfx = sfx + 1
  end
  while sfx > 0 and (is_cont(old, lo - sfx + 1) or is_cont(new, ln - sfx + 1)) do
    sfx = sfx - 1
  end

  local char_p = ot.byte_to_char(old, p)
  local deleted = old:sub(p + 1, lo - sfx)
  local inserted = new:sub(p + 1, ln - sfx)
  local ops = {}
  if #deleted > 0 then table.insert(ops, { p = char_p, d = deleted }) end
  if #inserted > 0 then table.insert(ops, { p = char_p, i = inserted }) end
  return ops
end

--- Diff the buffer against doc.content and submit whatever changed.
--- Diffing whole text (instead of rebuilding each on_bytes event) cannot drift:
--- some commands (J, :s, undo, paste, set_lines) report byte events that don't
--- map 1:1 onto the final text, which caused "Content divergence" rejoins.
---@param buf number
---@param doc table Document instance
function M.sync_from_buffer(buf, doc)
  if doc.applying_remote or not doc.joined then return end
  -- A remote op is queued for this buffer: diffing now would treat it as a
  -- local deletion. apply_remote syncs local changes once it is done.
  if (doc.remote_pending or 0) > 0 then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local new = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  local ops = M.diff_ops(doc.content, new)
  if #ops == 0 then return end
  doc.content = new
  doc:submit_op(ops)
  require('overleaf.sync').schedule_write(doc)
end

--- Attach on_bytes listener to buffer for change detection
---@param bufnr number
---@param doc table Document instance
function M.attach(bufnr, doc)
  vim.api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(_, buf)
      -- Guard: ignore changes triggered by applying remote ops
      if doc.applying_remote then return end
      -- Guard: ignore if document not joined
      if not doc.joined then return end
      M.sync_from_buffer(buf, doc)
      -- Some commands (J, :s) fire on_bytes before the buffer holds the final
      -- text, so diff once more after the command has finished.
      if not doc._sync_scheduled then
        doc._sync_scheduled = true
        vim.schedule(function()
          doc._sync_scheduled = false
          M.sync_from_buffer(buf, doc)
        end)
      end
    end,
  })
end

--- Apply remote OT operations to a Neovim buffer
---@param doc table Document instance
---@param ops table[] list of {p, i?, d?}
function M.apply_remote(doc, ops)
  if not doc.bufnr or not vim.api.nvim_buf_is_valid(doc.bufnr) then return end

  doc.remote_pending = (doc.remote_pending or 0) + 1
  vim.schedule(function()
    doc.remote_pending = doc.remote_pending - 1
    if not vim.api.nvim_buf_is_valid(doc.bufnr) then return end
    doc.applying_remote = true

    local had_error = false

    for _, op in ipairs(ops) do
      local ok, err = pcall(function()
        if op.d then
          local all_lines = vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false)
          local buf_content = table.concat(all_lines, '\n')
          -- Convert character offset to byte offset for Neovim
          local byte_p = ot.char_to_byte(buf_content, op.p)
          local start_row, start_col = ot.byte_offset_to_pos(buf_content, byte_p)
          local end_row, end_col = ot.byte_offset_to_pos(buf_content, byte_p + #op.d)
          vim.api.nvim_buf_set_text(doc.bufnr, start_row, start_col, end_row, end_col, { '' })
        end
        if op.i then
          local all_lines = vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false)
          local buf_content = table.concat(all_lines, '\n')
          -- Convert character offset to byte offset for Neovim
          local byte_p = ot.char_to_byte(buf_content, op.p)
          local row, col = ot.byte_offset_to_pos(buf_content, byte_p)
          local insert_lines = vim.split(op.i, '\n', { plain = true })
          vim.api.nvim_buf_set_text(doc.bufnr, row, col, row, col, insert_lines)
        end
      end)
      if not ok then
        config.log('error', 'Failed to apply remote op: %s', err)
        had_error = true
        break
      end
    end

    -- Fallback: if any op failed, replace buffer entirely from doc.content
    if had_error and doc.content then
      config.log('info', 'Falling back to full buffer replace')
      local new_lines = vim.split(doc.content, '\n', { plain = true })
      pcall(vim.api.nvim_buf_set_lines, doc.bufnr, 0, -1, false, new_lines)
    end

    vim.bo[doc.bufnr].modified = false
    doc.applying_remote = false
    -- Submit any local edits made while this remote op was queued
    if doc.remote_pending == 0 then M.sync_from_buffer(doc.bufnr, doc) end
  end)
end

--- Run chktex linter on buffer content and report via vim.diagnostic
local _lint_ns = vim.api.nvim_create_namespace('overleaf_chktex')
local _lint_timer = nil

function M._run_chktex(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if vim.fn.executable('chktex') ~= 1 then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, '\n')

  local stdout_chunks = {}

  local job_id = vim.fn.jobstart({ 'chktex', '-q', '-f', '%l:%c:%d:%k:%m\n', '--inputfiles=0' }, {
    stdin = 'pipe',
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then stdout_chunks = data end
    end,
    on_exit = function(_, _exit_code)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end

        local diagnostics = {}
        for _, line in ipairs(stdout_chunks) do
          local lnum, col, len, kind, msg = line:match('^(%d+):(%d+):(%d+):(%w+):(.+)$')
          if lnum then
            local severity = vim.diagnostic.severity.WARN
            if kind == 'Error' then
              severity = vim.diagnostic.severity.ERROR
            elseif kind == 'Message' then
              severity = vim.diagnostic.severity.INFO
            end
            table.insert(diagnostics, {
              lnum = tonumber(lnum) - 1,
              col = tonumber(col) - 1,
              end_col = tonumber(col) - 1 + tonumber(len),
              severity = severity,
              message = msg,
              source = 'chktex',
            })
          end
        end

        vim.diagnostic.set(_lint_ns, bufnr, diagnostics)
      end)
    end,
  })

  if job_id > 0 then
    vim.fn.chansend(job_id, content)
    vim.fn.chanclose(job_id, 'stdin')
  end
end

--- Schedule chktex lint with debounce
function M._schedule_lint(bufnr)
  if _lint_timer then _lint_timer:stop() end
  _lint_timer = vim.defer_fn(function() M._run_chktex(bufnr) end, 1000) -- 1 second debounce
end

--- Cleanup buffer resources
---@param doc table Document instance
function M.cleanup(doc)
  if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then vim.api.nvim_buf_delete(doc.bufnr, { force = true }) end
  doc.bufnr = nil
end

return M
