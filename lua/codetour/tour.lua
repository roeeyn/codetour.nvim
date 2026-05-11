local M = {}

---@class CodeTour.Tour
---@field name string Name of the tour (matches its on-disk filename)
---@field stops CodeTour.Stop[] Ordered list of stops; the array index identifies them (1-based)

-- Tour is a pure data module: zero dependencies on vim, storage, notify, or
-- any other codetour module. Mutations return (ok, err) instead of calling
-- log.warn so the user-facing notify layer stays in state.lua. File paths
-- are compared by string equality — callers are responsible for
-- canonicalising paths before passing them in.

---Construct a new empty tour.
---@param name string
---@return CodeTour.Tour
function M.new(name)
  return { name = name, stops = {} }
end

---Does the tour contain a stop at (file, lnum)?
---File comparison is plain string equality.
---@param tour CodeTour.Tour
---@param file string canonical file path
---@param lnum integer
---@return boolean
function M.has_stop_at(tour, file, lnum)
  for _, stop in ipairs(tour.stops) do
    if stop.file == file and stop.lnum == lnum then
      return true
    end
  end
  return false
end

---Append a stop. Refuses if another stop already lives at the same (file, lnum).
---@param tour CodeTour.Tour
---@param stop CodeTour.Stop
---@return boolean ok
---@return string? err
function M.add_stop(tour, stop)
  if M.has_stop_at(tour, stop.file, stop.lnum) then
    return false, string.format("a stop already exists at %s:%d", stop.file, stop.lnum)
  end
  table.insert(tour.stops, stop)
  return true
end

---Remove the stop at `idx`. Returns the removed stop on success, or nil + err
---if `idx` is out of range.
---@param tour CodeTour.Tour
---@param idx integer
---@return CodeTour.Stop? removed
---@return string? err
function M.remove_stop(tour, idx)
  if idx == nil or idx < 1 or idx > #tour.stops then
    return nil, string.format("stop #%s doesn't exist", tostring(idx))
  end
  return table.remove(tour.stops, idx)
end

---Replace the note text of the stop at `idx`.
---@param tour CodeTour.Tour
---@param idx integer
---@param text string
---@return boolean ok
---@return string? err
function M.update_note(tour, idx, text)
  if idx == nil or idx < 1 or idx > #tour.stops then
    return false, string.format("stop #%s doesn't exist", tostring(idx))
  end
  tour.stops[idx].note = text or ""
  return true
end

---Atomically replace the entire stops list. Validates that no two entries
---share a (file, lnum) pair. Empty `new_stops` is allowed (a tour with zero
---stops is a valid state — the user just hasn't added any yet, or removed
---them all via :TourEdit).
---@param tour CodeTour.Tour
---@param new_stops CodeTour.Stop[]
---@return boolean ok
---@return string? err
function M.replace_stops(tour, new_stops)
  local seen = {}
  for i, stop in ipairs(new_stops) do
    local key = stop.file .. ":" .. stop.lnum
    if seen[key] then
      return false, string.format("entry #%d is a duplicate of an earlier entry at %s", i, key)
    end
    seen[key] = true
  end
  tour.stops = new_stops
  return true
end

---Find the index of the stop in `tour.stops` nearest the given lnum, within
---the same file. Same-line preferred; otherwise nearest by line distance.
---Returns nil if no stop lives in this file.
---@param tour CodeTour.Tour
---@param file string canonical file path
---@param lnum integer
---@return integer? idx
function M.nearest_stop_idx(tour, file, lnum)
  local best_idx, best_dist = nil, math.huge
  for idx, stop in ipairs(tour.stops) do
    if stop.file == file then
      local dist = math.abs((stop.lnum or 1) - lnum)
      if dist < best_dist then
        best_idx = idx
        best_dist = dist
      end
    end
  end
  return best_idx
end

---Find the next (or previous) stop *strictly beyond* `lnum`, sorted by lnum
---ascending, within the same file. Returns nil at the boundary.
---@param tour CodeTour.Tour
---@param file string canonical file path
---@param lnum integer
---@param direction "next"|"prev"
---@return CodeTour.Stop?
function M.adjacent_stop(tour, file, lnum, direction)
  local in_file = {}
  for _, stop in ipairs(tour.stops) do
    if stop.file == file then
      table.insert(in_file, stop)
    end
  end
  if #in_file == 0 then
    return nil
  end
  table.sort(in_file, function(a, b)
    return (a.lnum or 1) < (b.lnum or 1)
  end)
  if direction == "next" then
    for _, stop in ipairs(in_file) do
      if (stop.lnum or 1) > lnum then
        return stop
      end
    end
  else
    for i = #in_file, 1, -1 do
      if (in_file[i].lnum or 1) < lnum then
        return in_file[i]
      end
    end
  end
  return nil
end

return M
