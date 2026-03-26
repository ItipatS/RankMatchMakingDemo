-- MatchmakingService.luau
-- Orchestrates the queue loop. Treats every player identically — mock or real.
-- The CAS claim pattern (claimAsync → match → removeAsync, or claimAsync → releaseAsync on failure)
-- is what makes this safe across multiple concurrent servers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local RankCalculator = require(script.Parent.RankCalculator)

local MatchmakingService = {}
MatchmakingService.__index = MatchmakingService

function MatchmakingService.new(adapter: any)
	local self = setmetatable({}, MatchmakingService)
	self._adapter = adapter
	self._running = false
	self._tickCount = 0
	self._onMatch = nil
	return self
end

-- Register a callback to receive match results.
function MatchmakingService:onMatch(callback: (any) -> ())
	self._onMatch = callback
end

-- Add a player to the shared queue.
function MatchmakingService:enqueue(player: any): boolean
	local entry = {
		userId = player.userId,
		displayName = player.displayName,
		mmr = player.mmr,
		rank = player.rank,
		region = player.region,
		queueJoinTime = player.queueJoinTime,
		claimed = false,
	}
	local key = "player_" .. player.userId
	return self._adapter:setAsync(key, entry, Constants.QUEUE_TTL)
end

local function entryKey(entry: any): string
	return "player_" .. entry.userId
end

-- Attempt to atomically claim both players and form a match.
-- Returns true only if both were claimed and removed successfully.
--
-- Why two-phase claim?
--   We need to reserve both players before committing the match.
--   If we could only claim A, B might simultaneously be claimed by another server.
--   The release on B-failure ensures A doesn't get stuck as "claimed but unmatched".
function MatchmakingService:_tryMatch(entryA: any, entryB: any): boolean
	if not RankCalculator.isEligibleMatch(entryA, entryB) then
		return false
	end

	local keyA = entryKey(entryA)
	local keyB = entryKey(entryB)

	-- Phase 1: claim A
	local claimedA = self._adapter:claimAsync(keyA, Constants.QUEUE_TTL)
	if not claimedA then
		return false -- A was already taken by another server
	end

	-- Phase 2: claim B
	local claimedB = self._adapter:claimAsync(keyB, Constants.QUEUE_TTL)
	if not claimedB then
		-- Roll back A so it can be matched with someone else
		self._adapter:releaseAsync(keyA, Constants.QUEUE_TTL)
		return false
	end

	-- Both claimed — remove from queue and fire the match result
	self._adapter:removeAsync(keyA)
	self._adapter:removeAsync(keyB)

	-- Simulate outcome: random winner (in a real game this is determined post-match)
	local winner, loser
	if math.random() > 0.5 then
		winner, loser = entryA, entryB
	else
		winner, loser = entryB, entryA
	end

	local deltaWin, deltaLose = RankCalculator.calculateMMRDelta(winner, loser)

	local result = {
		playerA = entryA,
		playerB = entryB,
		mmrDeltaA = (entryA.userId == winner.userId) and deltaWin or deltaLose,
		mmrDeltaB = (entryB.userId == winner.userId) and deltaWin or deltaLose,
		timestamp = os.time(),
	}

	if self._onMatch then
		self._onMatch(result)
	end

	return true
end

-- Run one queue scan.
-- Fetches a snapshot, walks it sorted by MMR, attempts greedy pair matching.
-- Returns the number of matches formed this tick.
-- serverId is optional — used for labelled logging in the stress test.
function MatchmakingService:tick(serverId: string?): number
	self._tickCount += 1
	local matchesThisTick = 0

	local snapshot = self._adapter:getSnapshotAsync()
	if #snapshot < 2 then
		return 0
	end

	-- Snapshot is already sorted by MMR from the adapter, but sort defensively
	table.sort(snapshot, function(a, b)
		return a.mmr < b.mmr
	end)

	-- Track locally which indices we've consumed this tick.
	-- This is a local optimisation — the CAS is still the real guard against duplicates.
	local used = {}

	for i = 1, #snapshot do
		if used[i] then
			continue
		end
		local candidate = snapshot[i]
		local spread = RankCalculator.getMMRSpread(candidate.queueJoinTime)

		for j = i + 1, #snapshot do
			if used[j] then
				continue
			end
			local other = snapshot[j]
			-- Snapshot is sorted by MMR ascending; once we exceed spread we can stop scanning
			if (other.mmr - candidate.mmr) > spread then
				break
			end

			if self:_tryMatch(candidate, other) then
				used[i] = true
				used[j] = true
				matchesThisTick += 1
				break
			end
		end
	end

	-- Queue-level logging (only in normal demo mode; stress test does its own reporting)
	if serverId == nil then
		local remaining = self._adapter:getSizeAsync()
		local spreadCount = 0
		for _, entry in snapshot do
			if RankCalculator.getMMRSpread(entry.queueJoinTime) > Constants.BASE_MMR_SPREAD then
				spreadCount += 1
			end
		end
		local spreadNote = spreadCount > 0
			and string.format(" (spread expanded for %d players)", spreadCount)
			or ""
		print(
			string.format(
				"[Queue] Tick %d — %d players waiting%s",
				self._tickCount,
				remaining,
				spreadNote
			)
		)
	end

	return matchesThisTick
end

-- Start the continuous queue loop in a background task.
function MatchmakingService:start(serverId: string?)
	self._running = true
	task.spawn(function()
		while self._running do
			self:tick(serverId)
			task.wait(Constants.QUEUE_TICK_RATE)
		end
	end)
end

function MatchmakingService:stop()
	self._running = false
end

return MatchmakingService
