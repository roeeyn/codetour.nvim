local M = {}

-- Format produced by render() and consumed by parse():
--   [N]  rel/path:lnum  ─  note text
-- N is the original stop index (identifier). file:lnum is display-only and
-- not parsed back into the stop. note text is editable.
local LINE_PATTERN = "^%[(%d+)%]%s+(.-):(%d+)%s+─%s*(.*)$"

---@class CodeTour.Edit.Parsed
---@field idx integer Original 1-based stop index in state.data.stops
---@field note string The (possibly-edited) note text

---Render the active tour's stops as buffer lines.
---@param stops CodeTour.Stop[]
---@return string[]
function M.render(stops)
  local lines = {}
  for idx, stop in ipairs(stops) do
    local rel = vim.fn.fnamemodify(stop.file, ":~:.")
    table.insert(lines, string.format("[%d]  %s:%d  ─  %s", idx, rel, stop.lnum or 1, stop.note or ""))
  end
  return lines
end

---Parse buffer lines into stop-edit records.
---Empty/whitespace-only lines are skipped. Any other malformed line aborts
---the parse with a human-readable error.
---@param buf_lines string[]
---@return CodeTour.Edit.Parsed[]?
---@return string? err_message
function M.parse(buf_lines)
  local parsed = {}
  for lineno, line in ipairs(buf_lines) do
    if line:match "^%s*$" then
      -- skip blank lines
    else
      local idx, _file, _lnum, note = line:match(LINE_PATTERN)
      if idx == nil then
        return nil, string.format("line %d: malformed entry: %s", lineno, line)
      end
      table.insert(parsed, { idx = tonumber(idx), note = note or "" })
    end
  end
  return parsed
end

---Apply a parsed buffer to the current tour. Atomic: either every line maps
---to a valid stop, or nothing changes.
---Returns (ok, err_message). On ok, state.replace_stops has been called and
---the fan-out (notes/signs/qf/save) is complete.
---@param parsed CodeTour.Edit.Parsed[]
---@return boolean ok
---@return string? err
function M.apply(parsed)
  local state = require "codetour.state"
  state.ensure_loaded()
  if state.data.active_tour == nil then
    return false, "no active tour"
  end

  local seen = {}
  local new_stops = {}
  for _, p in ipairs(parsed) do
    local original = state.data.stops[p.idx]
    if original == nil then
      return false, string.format("stop #%d doesn't exist in this tour", p.idx)
    end
    if seen[p.idx] then
      return false, string.format("stop #%d appears more than once", p.idx)
    end
    seen[p.idx] = true

    table.insert(new_stops, vim.tbl_extend("force", original, { note = p.note }))
  end

  state.replace_stops(new_stops)
  return true
end

---Convenience: parse + apply in one shot.
---@param buf_lines string[]
---@return boolean ok
---@return string? err
function M.commit(buf_lines)
  local parsed, perr = M.parse(buf_lines)
  if parsed == nil then
    return false, perr
  end
  return M.apply(parsed)
end

return M
