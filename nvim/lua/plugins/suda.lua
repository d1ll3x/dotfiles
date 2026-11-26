return {
  {
    "lambdalisue/vim-suda",
    event = "BufReadPre",
    config = function()
      -- Automatically switch buffer name for unreadable/unwritable files
      vim.g.suda_smart_edit = 1
    end,
  },
}
