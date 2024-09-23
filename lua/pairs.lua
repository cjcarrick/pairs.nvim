local MAX_LINES_FOR_SEARCH = 100

---@return integer,integer # row,col of the cursor; both are 0-based indices
local function pos()
	local r, c = unpack(vim.api.nvim_win_get_cursor(0))
	return r - 1, c
end

---Run the default action for a key. Call this inside of a vim.keymap.set()
---callback.
local function fallback_keymap(key)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, true, true), 'nt', false)
end

---@return integer #number of lines in a file
local function num_lines()
	return vim.api.nvim_buf_line_count(0)
end

---@param str string
local function first_char(str)
	return str:sub(1, 1)
end

---@param str string
local function last_char(str)
	return str:sub(#str, #str)
end

local function line_before_cursor()
	local row, col = pos()
	local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1]
	return line:sub(1, col)
end

local function line_after_cursor()
	local row, col = pos()
	local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1]
	return line:sub(col + 1)
end

local function count_occurences(str, pattern)
	local n = 0
	for _ in string.gmatch(str, pattern) do
		n = n + 1
	end
	return n
end

---Returns non-nil values if the given string is found after the cursor. Skips over
---whitespace to find it.
---@param str string
---@param immediately_after_cursor boolean
---if this is true, then a search immediately fails when a non-whitespace char is found
---@param skip_ws_only boolean
---@return integer|nil,integer|nil # row, col of the first char of the string in the buffer. Both are 0-based.
local function search_forwards(str, immediately_after_cursor, skip_ws_only)
	local row, col = pos()

	if immediately_after_cursor then
		local after_cursor = vim.api.nvim_buf_get_text(0, row, col - #str, row, col, {})[1]
		if after_cursor == str then
			return row, col - #str
		end
		return
	end

	local after = vim.api.nvim_buf_get_lines(0, row, math.min(row + MAX_LINES_FOR_SEARCH, num_lines()), true)
	local str_char_i = 1

	for r = 1, #after, 1 do
		local line = after[r]

		-- We get an array of lines, and search through each line looking for the
		-- opener. But for the first line, we need to start the search from the
		-- cursor's column, not from the first column of the line:
		-- {
		--    "...... . |... . . . ",
		--    "... ......... ... . . . ",
		--    "... . ... ... . . ",
		--    "... . ...... . . . "
		-- }
		local c_start = 1
		if r == 1 then c_start = col + 1 end

		for c = c_start, #line do
			local char = line:sub(c, c)
			if char == str:sub(str_char_i, str_char_i) then
				str_char_i = str_char_i + 1
				if str_char_i > #str then return row + r - 1, c - #str end
			else if skip_ws_only then
				if char ~= ' ' and char ~= '\t' and char ~= '\n' then
					return end
				end
			end
		end

		col = 1
	end
end

---@param str string specify which string to look for
---@param immediately_before_cursor boolean
---if this is true, then a search immediately fails when a non-whitespace char is found
---@param skip_ws_only boolean
---@return integer|nil,integer|nil #the row, col of the first char of the
---closing pair in the buffer. Both indices are 0-based
local function search_backwards(str, immediately_before_cursor, skip_ws_only)
	local row, col = pos()

	if immediately_before_cursor then
		if col < #str then return end
		local before_cursor = vim.api.nvim_buf_get_text(0, row, col - #str, row, col, {})[1]
		if before_cursor == str then
			return row, col - #str
		end
		return
	end

	local before = vim.api.nvim_buf_get_lines(0, math.max(row - MAX_LINES_FOR_SEARCH - 1, 0), row + 1, true)

	local str_char_i = #str

	for r = #before, 1, -1 do
		local line = before[r]
		-- string can't fit on this line, just skip it
		-- if #line >= #str then

		local c_begin = #line
		if r == #before then c_begin = col end
		for c = c_begin, 1, -1 do
			local char = line:sub(c, c)
			if char == str:sub(str_char_i, str_char_i) then
				str_char_i = str_char_i - 1
				if str_char_i == 0 then return row - #before + r, c - 1 end
			else if skip_ws_only then
				if char ~= ' ' and char ~= '\t' and char ~= '\n' then
					return end
				end
			end
		end
	end
end

---Check if the specified opener and closer to the left and right of the cursor
---have an equal number of spaces between themselves and the cursor
---@return boolean 
local function spaces_balanced(opener, closer)
	local row, col = pos()
	local opener_r, opener_c = search_backwards(opener, false, true)
	local closer_r, closer_c = search_forwards(closer, false, true)

	-- Closer and opener must be on the same line as the cursor
	if row == nil or row ~= opener_r or row ~= closer_r then
		return false
	end

	-- Check that the number of spaces on the left and right of the cursor is
	-- the same
	if (col - opener_c - #opener) ~= (closer_c - col) then
		return false
	end
	return true
end

---@class Opts
---
---The closing string for this pair
---@field 1 string
---
---       |     -->    (|)
---@field auto_insert_closer boolean|nil
---
---       (|)   -->    |
---@field auto_delete_closer boolean|nil
---
---  1)   (|)  -->  ()|
---  2)   (       (
---       |  -->  )|
---       )
---@field skip_over_closer boolean|nil
---
---  1)   (|)    --[press space]-->  ( | )
---  2)   ( | )  --[press <bs>]-->   (|)
---@field balance_spaces boolean|nil
---
---  1)   (|)    --[press <cr>]-->    (
---                                   |
---                                   )
---  2)   (                           (|)
---       |      --[press <bs>]-->
---       )
---  (You actually can't disable this option for now.)
---@field balance_newlines boolean|nil
---
---   false:    (|)    --[press <cr>]-->    (
---                                         |
---                                         )
---   true:     (|)    --[press <cr>]-->    (
---                                             |
---                                         )
---@field indent_on_cr boolean|nil

---Return a string that represents n levels of indentations. Intended to be used
---with vim.fn.indent()
---@param n integer
---@return string
local function indent(n)
	if vim.api.nvim_get_option_value('expandtab', {}) then
		return string.rep(' ', n)
	else
		n = n / vim.api.nvim_get_option_value('tabstop', {})
		return string.rep('\t', n)
	end
end

---@param opener string
---@param closer string
---@return boolean if something happened
local function do_skip_over_closer(opener, closer)
	local opener_r, opener_c = search_backwards(opener, false, false)
	local closer_r, closer_c = search_forwards(closer, false, true)
	if opener_r ~= nil and closer_r ~= nil then
		local row, col = pos()

		-- {       {
		-- |  -->  |}
		-- }
		local only_ws_before_cursor = search_backwards(opener, false, true) ~= nil
		if only_ws_before_cursor and opener_r == row - 1 and closer_r == row + 1 then
			local new_indent = indent(vim.fn.indent(opener_r + 1))
			vim.api.nvim_buf_set_text(0, opener_r, opener_c + #opener, closer_r, closer_c, { '', new_indent })
			closer_r = closer_r - 1

			-- {  |  }  -->  {  |}
		elseif spaces_balanced(opener, closer) then
			vim.api.nvim_buf_set_text(0, closer_r, col, closer_r, closer_c, {})
		end

		-- { |   }  -->  {    }|
		vim.api.nvim_win_set_cursor(0, { closer_r + 1, closer_c + #closer })
		return true
	end

	return false
end

---@param opener string
---@param closer string
---@return boolean if something happens
local function do_auto_insert_closer(opener, closer)
	-- Check if adding this last char would complete the opener.
	-- If it wouldn't, abort.
	local row, col = pos()
	local before_cursor = ''
	if col + 1 >= #opener then
		before_cursor = vim.api.nvim_buf_get_text(0, row, col - #opener + 1, row, col, {})[1]
	end
	if before_cursor .. last_char(opener) ~= opener then
		return false
	end

	-- special case:
	-- Consider when the pairs are '"' and '"' (the opener and closer are
	-- the same).
	if opener == closer then
		local l = count_occurences(line_before_cursor(), opener)
		local r = count_occurences(line_after_cursor(), closer)
		if l ~= r then
			return false
		end
	end

	local closer_r = search_forwards(closer, false, true)

	vim.opt.showmode = false
	if closer_r == nil then
		vim.api.nvim_put({ last_char(opener) }, 'c', false, true)
		vim.api.nvim_put({ closer }, 'c', false, false)
		-- vim.api.nvim_buf_set_text(0, row, col + 1, row, col + 1, { closer })
		return true
	else
		-- This handles the case when the opener is already placed, but the
		-- closer isn't.
		local opener_r = search_backwards(opener, false, false)

		if opener_r ~= nil then
			vim.api.nvim_put({ last_char(opener) }, 'c', false, true)
			vim.api.nvim_put({ closer }, 'c', false, false)
			return true
		end
	end

	return false
end


---@param opener string
---@param closer string
---@return boolean if something happened
local function do_delete_closer(opener, closer)
	local row, col = pos()

	local opener_r, opener_c = search_backwards(opener, false, true)
	local closer_r, closer_c = search_forwards(closer, false, true)

	if opener_r ~= nil and closer_r ~= nil then
		local immediately_before_cursor = opener_r == row and opener_c + #opener == col
		if immediately_before_cursor then
			vim.api.nvim_buf_set_text(0, row, opener_c, closer_r, closer_c + #closer, {})
			return true
		end
	end
	return false
end

---@param opener string
---@param closer string
---@return boolean if something happened
local function balance_spaces_remove(opener, closer)
	local row, col = pos()
	if spaces_balanced(opener, closer) then
		vim.api.nvim_buf_set_text(0, row, col - 1, row, col + 1, {})
		return true
	end
	return false
end

---@param opener string
---@param closer string
---@return boolean if something happened
local function balance_newlines_remove(opener, closer)
	local row, col = pos()

	local opener_r, opener_c = search_backwards(opener, false, true)
	local closer_r, closer_c = search_forwards(closer, false, true)

	if opener_r ~= nil and closer_r ~= nil then
		if opener_r == row - 1 and closer_r == row + 1 and col == 0 then
			vim.api.nvim_buf_set_text(0, opener_r, opener_c + #opener, closer_r, closer_c, {})
			return true
		end
	end
end

---@param opener string
---@param closer string
---@return boolean indicating if something happened
local function balance_spaces_add(opener, closer)
	if spaces_balanced(opener, closer) then
		vim.api.nvim_put({ ' ' }, 'c', false, true)
		vim.api.nvim_put({ ' ' }, 'c', false, false)
		return true
	end
	return false
end

---@param opener string
---@param closer string
---@param increase_indentation boolean
---@return boolean indicating if something happened
local function balance_newlines_add(opener, closer, increase_indentation)
	local row, col = pos()

	local opener_r, opener_c = search_backwards(opener, false, true)
	if not opener_r then
		return false
	end

	local closer_r, closer_c = search_forwards(closer, false, true)
	if closer_r ~= opener_r then
		return false
	end

	local existing_indent = vim.fn.indent(row + 1)
	local new_indent = existing_indent
	if increase_indentation then
		new_indent = new_indent + vim.api.nvim_get_option_value('tabstop', {})
	end
	vim.api.nvim_buf_set_text(0, opener_r, opener_c + #opener, closer_r, closer_c, {
		'',
		indent(new_indent),
		indent(existing_indent)
	})
	vim.api.nvim_win_set_cursor(0, { opener_r + 2, #indent(new_indent) })
	return true
end


---@param cfg { [string]: Opts }
local function setup(cfg)
	for opener, opts in pairs(cfg) do

		if opts.skip_over_closer then
			vim.keymap.set('i', first_char(opts[1]), function()
				if do_skip_over_closer(opener, opts[1]) then
					return
				end
				fallback_keymap(first_char(opts[1]))
			end)
		end

		if opts.auto_insert_closer then
			vim.keymap.set('i', last_char(opener), function()
				if do_auto_insert_closer(opener, opts[1]) then
					return
				end
				fallback_keymap(last_char(opener))
			end)
		end
	end

	vim.keymap.set('i', '<space>', function()
		for opener, opts in pairs(cfg) do
			if opts.balance_spaces and balance_spaces_add(opener, opts[1]) then
				return
			end
		end
		fallback_keymap '<space>'
	end)

	vim.keymap.set('i', '<bs>', function()
		for opener, opts in pairs(cfg) do
			if opts.auto_delete_closer and do_delete_closer(opener, opts[1]) then
				return
			end
			if opts.balance_spaces and balance_spaces_remove(opener, opts[1]) then
				return
			end
			if opts.balance_newlines and balance_newlines_remove(opener, opts[1]) then
				return
			end
		end
		fallback_keymap '<bs>'
	end)

	vim.keymap.set('i', '<cr>', function()
		for opener, opts in pairs(cfg) do
			if opts.balance_newlines and balance_newlines_add(opener, opts[1], opts.indent_on_cr) then
				return
			end
		end
		fallback_keymap '<cr>'
	end)
end

return { setup = setup }
