-- What the `nvim.editor` lane means, defined once. altfont.lua (the font lane)
-- and theme.lua (the colorscheme lane) both ask it, so the two lanes cannot
-- disagree about which windows are "the editor" -- a file drawn in the editor
-- font but the UI's colors would be exactly the drift this file prevents.
--
-- "A file you write", which is the whole spec. buftype is what does the work:
-- oil is 'acwrite', terminals are 'terminal', telescope and every other
-- scratch UI are 'nofile', help is 'help', quickfix is 'quickfix'.
-- Only a real file-backed buffer is ''.
--
-- The scheme test is the belt to that braces. A plugin that presents a virtual
-- filesystem through a normal buftype -- oil-ssh, fugitive's blobs -- still
-- names its buffers with a URL scheme, and those are not files you write
-- either.
return function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= '' then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    return false
  end
  if name:match '^%a[%w+.-]*://' then
    return false
  end
  return true
end
