return {
  "stevearc/oil.nvim",
  dependencies = { "nvim-mini/mini.icons", opts = {} },
  opts = {
    columns = { "icon" },
    view_options = {
      show_hidden = true,
    },
  },
  vim.keymap.set("n", "-", "<cmd>Oil<cr>"),
}
