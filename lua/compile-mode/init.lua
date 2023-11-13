---@alias SplitModifier "aboveleft"|"belowright"|"topleft"|"botright"|""
---@alias SMods { vertical: boolean?, silent: boolean?, split: SplitModifier? }
---@alias CommandParam { args: string?, smods: SMods? }
---@alias Config { no_baleia_support: boolean?, default_command: string?, time_format: string?, baleia_opts: table?, buffer_name: string?, error_highlights: false|table<string, HighlightStyle|false>?, error_regexp_table: ErrorRegexpTable? }

local a = require("plenary.async")
local errors = require("compile-mode.errors")
local utils = require("compile-mode.utils")
local colors = require("compile-mode.colors")

local M = {}

local current_error = 0
---@type string|nil
local prev_dir = nil
---@type Config
local config = {
	buffer_name = "Compilation",
	default_command = "make -k",
	error_highlights = colors.default_highlights,
	time_format = "%a %b %e %H:%M:%S",
}

M.level = errors.level

---Configure `compile-mode.nvim`. Also sets up the highlight groups for errors.
---
---@param opts Config
function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts)

	errors.error_regexp_table = vim.tbl_extend("force", errors.error_regexp_table, config.error_regexp_table or {})

	if config.error_highlights then
		colors.setup_highlights(config.error_highlights)
	end
end

---@type fun(cmd: string, bufnr: integer, sync: boolean | nil): integer, integer, integer
local runjob = a.wrap(function(cmd, bufnr, sync, callback)
	local count = 0

	local on_either = a.void(function(_, data)
		if not data or (#data < 1 or data[1] == "") then
			return
		end

		count = count + #data

		local linecount = vim.api.nvim_buf_line_count(bufnr)
		for i, line in ipairs(data) do
			local error = errors.parse(line)

			if error then
				errors.error_list[linecount + i - 1] = error
			elseif not config.no_baleia_support then
				data[i] = vim.fn.substitute(line, "^\\([^: \\t]\\+\\):", "\x1b[34m\\1\x1b[0m:", "")
			end
		end

		vim.api.nvim_buf_set_lines(bufnr, -2, -1, false, data)
		utils.wait()
		errors.highlight(bufnr)
	end)

	local id = vim.fn.jobstart(cmd, {
		cwd = prev_dir,
		on_stdout = on_either,
		on_stderr = on_either,
		on_exit = function(id, code)
			callback(count, code, id)
		end,
	})

	if id <= 0 then
		vim.notify("Failed to start job with command " .. cmd, vim.log.levels.ERROR)
		return
	end

	vim.g.compile_job_id = id

	if sync then
		vim.fn.jobwait({ id })
	end

	vim.api.nvim_create_autocmd({ "BufDelete" }, {
		buffer = bufnr,
		callback = function()
			vim.fn.jobstop(id)
		end,
	})
end, 4)

---Get the current time, formatted.
local function time()
	return vim.fn.strftime(config.time_format)
end

---Get the default directory, formatted.
local function default_dir()
	local cwd = vim.fn.getcwd() --[[@as string]]
	return cwd:gsub("^" .. vim.env.HOME, "~")
end

---Go to the error on the current line
function M.goto_error()
	local linenum = unpack(vim.api.nvim_win_get_cursor(0))
	local error = errors.error_list[linenum]

	if not error then
		vim.notify("No error here")
		return
	end

	utils.jump_to_error(error)
end

---Run `command` and place the results in the "Compilation" buffer.
---
---@type fun(command: string, smods: SMods, sync: boolean | nil)
local runcommand = a.void(function(command, smods, sync)
	if vim.g.compile_job_id then

		local bufnr = vim.fn.bufnr(config.buffer_name --[[@as integer]]) --[[@as integer]]

		local interrupt_message
		if not config.no_baleia_support then
			interrupt_message = "Compilation \x1b[31minterrupted\x1b[0m"
		else
			interrupt_message = "Compilation interrupted"
		end

		utils.buf_set_opt(bufnr, "modifiable", true)
		vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
			"",
			interrupt_message .. " at " .. time(),
		})
		utils.wait()
		utils.buf_set_opt(bufnr, "modifiable", false)

		vim.fn.jobstop(vim.g.compile_job_id)
		vim.g.compile_job_id = nil

		utils.delay(1000)
	end

	local bufnr = utils.split_unless_open(config.buffer_name, smods)

	utils.buf_set_opt(bufnr, "modifiable", true)
	utils.buf_set_opt(bufnr, "filetype", "compilation")

	vim.keymap.set("n", "q", "<CMD>q<CR>", { silent = true, buffer = bufnr })
	vim.keymap.set("n", "<CR>", "<CMD>CompileGotoError<CR>", { silent = true, buffer = bufnr })

	vim.api.nvim_create_autocmd("ExitPre", {
		group = vim.api.nvim_create_augroup("compile-mode", { clear = true }),
		callback = function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.api.nvim_buf_delete(bufnr, { force = true })
			end
		end,
	})

	if not config.no_baleia_support then
		local baleia = require("baleia").setup(config.baleia_opts or {})
		baleia.automatically(bufnr)
		vim.api.nvim_create_user_command("BaleiaLogs", function()
			baleia.logger.show()
		end, {})
	end

	-- reset compilation buffer
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
	utils.wait()

	local rendered_command = command

	local error = errors.parse(command)
	if error then
		errors.error_list[4] = error
	elseif not config.no_baleia_support then
		rendered_command = vim.fn.substitute(command, "^\\([^: \\t]\\+\\):", "\x1b[34m\\1\x1b[0m:", "")
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, {
		'-*- mode: compilation; default-directory: "' .. default_dir() .. '" -*-',
		"Compilation started at " .. time(),
		"",
		rendered_command,
	})

	utils.wait()
	errors.highlight(bufnr)

	local count, code, job_id = runjob(command, bufnr, sync)
	if job_id ~= vim.g.compile_job_id then
		return
	end
	vim.g.compile_job_id = nil

	if count == 0 then
		vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "" })
	end

	local simple_message
	local finish_message
	if code == 0 then
		simple_message = "Compilation finished"
		finish_message = "Compilation \x1b[32mfinished\x1b[0m"
	else
		simple_message = "Compilation exited abnormally with code " .. tostring(code)
		finish_message = "Compilation \x1b[31mexited abnormally\x1b[0m with code \x1b[31m"
			.. tostring(code)
			.. "\x1b[0m"
	end

	local compliation_message = config.no_baleia_support and simple_message or finish_message
	vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
		compliation_message .. " at " .. time(),
		"",
	})

	if not smods.silent then
		vim.notify(simple_message)
	end

	utils.wait()

	utils.buf_set_opt(bufnr, "modifiable", false)
	utils.buf_set_opt(bufnr, "modified", false)
end)

---Prompt for (or get by parameter) a command and run it.
---
---@param param CommandParam
M.compile = a.void(function(param)
	param = param or {}

	local command = param.args ~= "" and param.args
		or utils.input({
			prompt = "Compile command: ",
			default = vim.g.compile_command or config.default_command,
			completion = "shellcmd",
		})

	if command == nil then
		return
	end

	vim.g.compile_command = command
	prev_dir = vim.fn.getcwd()

	runcommand(command, param.smods or {}, param.bang)
end)

---Rerun the last command.
---@param param CommandParam
M.recompile = a.void(function(param)
	if vim.g.compile_command then
		runcommand(vim.g.compile_command, param.smods or {}, param.bang)
	else
		vim.notify("Cannot recompile without previous command; compile first", vim.log.levels.ERROR)
	end
end)

---Jump to the next error in the error list.
M.next_error = a.void(function()
	local lowest_above = nil
	for line, _ in pairs(errors.error_list) do
		if line > current_error and (not lowest_above or lowest_above > line) then
			lowest_above = line
		end
	end

	if not lowest_above then
		vim.notify("Moved past last error")
		return
	end

	current_error = lowest_above
	utils.jump_to_error(errors.error_list[lowest_above])
end)

---Jump to the previous error in the error list.
M.prev_error = a.void(function()
	local highest_below = nil
	for line, _ in pairs(errors.error_list) do
		if line < current_error and (not highest_below or highest_below > line) then
			highest_below = line
		end
	end

	if not highest_below then
		vim.notify("Moved past first error")
		return
	end

	current_error = highest_below
	utils.jump_to_error(errors.error_list[highest_below])
end)

return M
