-- MemoryStoreAdapter.luau
-- The ONLY file aware of the storage backend.
-- Flip Constants.USE_REAL_MEMORYSTORE and everything below this layer goes live.
--
-- Op cost model (matches real MemoryStore billing):
--   SetAsync      → 1 unit
--   GetRangeAsync → 1 + (items returned) units
--   UpdateAsync   → 2 units minimum
--   RemoveAsync   → 1 unit

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

local USE_REAL_MEMORYSTORE = Constants.USE_REAL_MEMORYSTORE

local MemoryStoreAdapter = {}
MemoryStoreAdapter.__index = MemoryStoreAdapter

-- Internal mock store entry shape
type MockEntry = {
	value: any,
	sortKey: number,
	expiresAt: number,
}

function MemoryStoreAdapter.new(mapName: string, useRealMemoryStore: boolean?): any
	local self = setmetatable({}, MemoryStoreAdapter)

	self._mapName = mapName
	self._stats = {
		totalUnits = 0,
		setCalls = 0,
		getRangeCalls = 0,
		updateCalls = 0,
		removeCalls = 0,
		totalMatches = 0, -- incremented by recordMatch(); drives units/match metric
	}

	-- Explicit false overrides the global constant (stress test forces mock regardless of USE_REAL_MEMORYSTORE).
	-- nil means "use the global default". true/false means "force this mode".
	local useReal = if useRealMemoryStore ~= nil then useRealMemoryStore else USE_REAL_MEMORYSTORE
	if useReal then
		local MemoryStoreService = game:GetService("MemoryStoreService")
		self._map = MemoryStoreService:GetSortedMap(mapName)
		self._isMock = false
	else
		-- key → MockEntry
		self._store = {} :: { [string]: MockEntry }
		self._isMock = true
	end

	return self
end

-- ─── Internal helpers ────────────────────────────────────────────────────────

function MemoryStoreAdapter:_addUnits(units: number)
	self._stats.totalUnits += units
end

-- Evict expired entries from the mock store (called lazily before reads)
function MemoryStoreAdapter:_evictExpired()
	local now = os.time()
	for key, entry in self._store do
		if entry.expiresAt <= now then
			self._store[key] = nil
		end
	end
end

-- ─── Stats ───────────────────────────────────────────────────────────────────

function MemoryStoreAdapter:getStats()
	-- Return a shallow copy so the caller can't mutate internal state
	return {
		totalUnits   = self._stats.totalUnits,
		setCalls     = self._stats.setCalls,
		getRangeCalls= self._stats.getRangeCalls,
		updateCalls  = self._stats.updateCalls,
		removeCalls  = self._stats.removeCalls,
		totalMatches = self._stats.totalMatches,
	}
end

-- Called by MatchmakingService once per committed match.
-- Lets the dashboard compute units/match instead of units/tick.
function MemoryStoreAdapter:recordMatch(count: number?)
	self._stats.totalMatches += (count or 1)
end

function MemoryStoreAdapter:resetStats()
	self._stats = {
		totalUnits   = 0,
		setCalls     = 0,
		getRangeCalls= 0,
		updateCalls  = 0,
		removeCalls  = 0,
		totalMatches = 0,
	}
end

-- ─── SetAsync ────────────────────────────────────────────────────────────────

-- Writes a queue entry. sortKey must be the player's MMR for range queries to work.
function MemoryStoreAdapter:setAsync(key: string, value: any, ttl: number): boolean
	self._stats.setCalls += 1
	self:_addUnits(1)

	if self._isMock then
		task.wait() -- simulate async round-trip; yields to let other coroutines run
		self._store[key] = {
			value = value,
			sortKey = value.avgMmr or value.mmr,
			expiresAt = os.time() + ttl,
		}
		return true
	else
		local ok, err = pcall(function()
			self._map:SetAsync(key, value, ttl, value.avgMmr or value.mmr)
		end)
		if not ok then
			warn("[MemoryStoreAdapter] SetAsync failed:", err)
		else
			print(key, value)
		end
		return ok
	end
end

-- ─── GetRangeAsync ───────────────────────────────────────────────────────────

-- Returns all unclaimed entries whose MMR sort key falls in [minMMR, maxMMR].
-- Cost: 1 + (items returned) units — mirrors real GetRangeAsync billing.
function MemoryStoreAdapter:getRangeAsync(minMMR: number, maxMMR: number, limit: number?): { any }
	local maxItems = limit or 100
	self._stats.getRangeCalls += 1

	if self._isMock then
		task.wait()
		self:_evictExpired()

		local results = {}
		for _, entry in self._store do
			if entry.sortKey >= minMMR and entry.sortKey <= maxMMR and not entry.value.claimed then
				table.insert(results, { value = entry.value, sortKey = entry.sortKey })
			end
		end
		table.sort(results, function(a, b)
			return a.sortKey < b.sortKey
		end)

		local out = {}
		for i = 1, math.min(#results, maxItems) do
			table.insert(out, results[i].value)
		end

		self:_addUnits(1 + #out)
		return out
	else
		local results = {}
		-- Fetch all items with no bounds, then filter by MMR in Luau.
		-- The bounds API requires referencing existing keys with valid UTF-8,
		-- which is fragile for a dynamic queue. For a queue this size it's fine.
		local ok, data = pcall(function()
			return self._map:GetRangeAsync(Enum.SortDirection.Ascending, maxItems)
		end)
		if ok and data then
			-- item.sortKey can be nil for entries stored without a sort key (stale data).
			-- Guard the comparison so we don't throw on nil >= number.
			for _, item in data do
				if type(item.sortKey) == "number"
					and item.sortKey >= minMMR
					and item.sortKey <= maxMMR
					and item.value
					and not item.value.claimed
				then
					table.insert(results, item.value)
				end
			end
			self:_addUnits(1 + #results)
		else
			warn("[MemoryStoreAdapter] GetRangeAsync failed:", data)
			self:_addUnits(1)
		end
		return results
	end
end

-- ─── ClaimAsync (UpdateAsync) ─────────────────────────────────────────────────

-- Atomically marks a player as "claimed" so no other server matches them simultaneously.
-- Returns true if this server successfully claimed the entry.
-- Cost: 2 units (UpdateAsync minimum).
--
-- MOCK SIMULATION:
--   task.wait() before the read gives other coroutines a chance to claim first,
--   simulating the race condition that real UpdateAsync atomicity prevents.
--   The read-check-write block after the yield is NOT interrupted (cooperative scheduler),
--   which correctly mirrors the server-side atomicity of real UpdateAsync.
function MemoryStoreAdapter:claimAsync(key: string, ttl: number): boolean
	self._stats.updateCalls += 1
	self:_addUnits(2) -- UpdateAsync always costs at least 2 units

	if self._isMock then
		task.wait() -- yield: let competing coroutines race to this point
		-- From here to return: no yield = atomic in cooperative Luau scheduler
		local entry = self._store[key]
		if entry == nil or entry.expiresAt <= os.time() then
			return false -- entry expired or already removed
		end
		if entry.value.claimed then
			return false -- another server claimed it during our task.wait()
		end
		entry.value.claimed = true
		return true
	else
		local claimed = false
		-- Retry up to 3 times on RequestThrottled with linear backoff.
		-- Any other error aborts immediately so we don't block the tick loop.
		for attempt = 1, 3 do
			local ok, err = pcall(function()
				self._map:UpdateAsync(key, function(current)
					if current == nil then return nil end
					if current.claimed then return nil end
					current.claimed = true
					claimed = true
					return current
				end, ttl)
			end)
			if ok then
				break
			elseif tostring(err):find("RequestThrottled") then
				task.wait(0.3 * attempt)
			else
				warn("[MemoryStoreAdapter] UpdateAsync (claim) failed:", err)
				break
			end
		end
		return claimed
	end
end

-- ─── ReleaseAsync (UpdateAsync) ───────────────────────────────────────────────

-- Rolls back a claim — used when we claimed player A but failed to claim player B.
-- Without this, claimed-but-unmatched players would be stuck until TTL expiry.
-- Cost: 2 units.
function MemoryStoreAdapter:releaseAsync(key: string, ttl: number): boolean
	self._stats.updateCalls += 1
	self:_addUnits(2)

	if self._isMock then
		task.wait()
		local entry = self._store[key]
		if entry == nil then
			return false
		end
		entry.value.claimed = false
		return true
	else
		local ok, err = pcall(function()
			self._map:UpdateAsync(key, function(current)
				if current == nil then
					return nil
				end
				current.claimed = false
				return current
			end, ttl)
		end)
		if not ok then
			warn("[MemoryStoreAdapter] UpdateAsync (release) failed:", err)
		end
		return ok
	end
end

-- ─── RemoveAsync ─────────────────────────────────────────────────────────────

-- Permanently removes a player from the queue (match confirmed).
-- Cost: 1 unit.
function MemoryStoreAdapter:removeAsync(key: string): boolean
	self._stats.removeCalls += 1
	self:_addUnits(1)

	if self._isMock then
		task.wait()
		local existed = self._store[key] ~= nil
		self._store[key] = nil
		return existed
	else
		local ok, err = pcall(function()
			self._map:RemoveAsync(key)
		end)
		if not ok then
			warn("[MemoryStoreAdapter] RemoveAsync failed:", err)
		end
		return ok
	end
end

-- ─── Snapshot / Size ─────────────────────────────────────────────────────────

-- Returns all unclaimed, non-expired entries sorted by MMR ascending.
-- In production this uses GetRangeAsync with a full MMR sweep.
function MemoryStoreAdapter:getSnapshotAsync(): { any }
	return self:getRangeAsync(0, 9999, 100)
end

-- Count of currently active (unclaimed, non-expired) entries.
function MemoryStoreAdapter:getSizeAsync(): number
	if self._isMock then
		self:_evictExpired()
		local count = 0
		for _, entry in self._store do
			if not entry.value.claimed then
				count += 1
			end
		end
		return count
	else
		local ok, size = pcall(function()
			return self._map:GetSizeAsync()
		end)
		return ok and size or 0
	end
end

-- Wipe everything — mock only, used between stress test runs.
function MemoryStoreAdapter:clearAll()
	if self._isMock then
		self._store = {}
	else
		warn("[MemoryStoreAdapter] clearAll() is not supported in production mode")
	end
end

return MemoryStoreAdapter
