local project_root = vim.fn.getcwd()
return dofile(project_root .. "/tests/helpers/child.lua")
