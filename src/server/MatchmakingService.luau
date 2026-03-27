-- MatchmakingService.luau
-- TEAM_SIZE-vs-TEAM_SIZE matchmaking supporting solo players and premade groups.
-- Groups of any size ≤ TEAM_SIZE queue as a single entry. The matchmaker assembles
-- virtual teams from those groups, then matches two teams by avgMmr + spread.
--
-- CAS claim covers every group in both teams atomically:
--   claim all teamA groups → claim all teamB groups → commit
--   any failure → release everything claimed so far

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
	self._totalMatches = 0
	self._onMatch = nil
	self._onTick = nil
	self._recentMatches = {}
	return self
end

function MatchmakingService:onMatch(callback: (any) -> ())
	self._onMatch = callback
end

function MatchmakingService:onTick(callback: (any) -> ())
	self._onTick = callback
end

-- Enqueue a group (solo or premade). One MemoryStore entry per group.
function MatchmakingService:enqueueGroup(group: any): boolean
	local key = "group_" .. group.groupId
	return self._adapter:setAsync(key, group, Constants.QUEUE_TTL)
end

-- Backward compat: wrap a single player as a size-1 group.
-- Stress test and old call sites use this path.
function MatchmakingService:enqueue(player: any): boolean
	local group = {
		groupId = tostring(player.userId),
		members = {{
			userId = player.userId,
			displayName = player.displayName,
			mmr = player.mmr,
			rank = player.rank,
			region = player.region,
		}},
		avgMmr = player.mmr,
		size = 1,
		rank = player.rank,
		region = player.region,
		queueJoinTime = player.queueJoinTime,
		claimed = false,
	}
	return self:enqueueGroup(group)
end

-- Attempt to atomically claim all groups in both teams, then commit the match.
-- CAS order: teamA groups first, then teamB groups.
-- On any claim failure: release all keys claimed so far and return false.
function MatchmakingService:_tryMatchTeams(teamA: any, teamB: any): boolean
	local allGroups = {}
	for _, g in teamA.groups do table.insert(allGroups, g) end
	for _, g in teamB.groups do table.insert(allGroups, g) end

	local claimedKeys = {}
	local success = true

	for _, g in allGroups do
		local key = "group_" .. g.groupId
		if self._adapter:claimAsync(key, Constants.QUEUE_TTL) then
			table.insert(claimedKeys, key)
		else
			success = false
			break
		end
	end

	if not success then
		for _, key in claimedKeys do
			self._adapter:releaseAsync(key, Constants.QUEUE_TTL)
		end
		return false
	end

	-- All claimed — permanently remove from queue
	for _, key in claimedKeys do
		self._adapter:removeAsync(key)
	end

	-- Flatten group members into team rosters
	local membersA, membersB = {}, {}
	for _, g in teamA.groups do
		for _, m in g.members do table.insert(membersA, m) end
	end
	for _, g in teamB.groups do
		for _, m in g.members do table.insert(membersB, m) end
	end

	-- Team ELO: each team is treated as a single entity at avgMmr
	local winner = math.random() > 0.5 and "A" or "B"
	local winnerMmr = winner == "A" and teamA.avgMmr or teamB.avgMmr
	local loserMmr  = winner == "A" and teamB.avgMmr or teamA.avgMmr
	local deltaWin, deltaLose = RankCalculator.calculateMMRDelta({ mmr = winnerMmr }, { mmr = loserMmr })

	local result = {
		teamA     = membersA,
		teamB     = membersB,
		winner    = winner,        -- "A" or "B"
		mmrDeltaA = winner == "A" and deltaWin or deltaLose,
		mmrDeltaB = winner == "B" and deltaWin or deltaLose,
		avgMmrA   = teamA.avgMmr,
		avgMmrB   = teamB.avgMmr,
		matchType = string.format("%dv%d", #membersA, #membersB),
		timestamp = os.time(),
	}

	self._totalMatches += 1
	table.insert(self._recentMatches, 1, {
		teamA  = membersA,
		teamB  = membersB,
		winner = winner,
		deltaA = result.mmrDeltaA,
		deltaB = result.mmrDeltaB,
	})
	if #self._recentMatches > 10 then
		table.remove(self._recentMatches)
	end

	if self._onMatch then
		self._onMatch(result)
	end

	return true
end

-- Run one queue scan.
-- Groups are bucketed by size — a size-2 group only matches another size-2 group.
-- This gives you 1v1, 2v2, and 3v3 brackets from a single mixed queue.
-- Within each bracket the matching is greedy by avgMmr with the spread gate.
function MatchmakingService:tick(serverId: string?): number
	self._tickCount += 1
	local matchesThisTick = 0

	local snapshot = self._adapter:getSnapshotAsync()
	if #snapshot < 2 then return 0 end

	-- Bucket groups by size — each bucket is an independent bracket
	local buckets: { [number]: { any } } = {}
	for _, g in snapshot do
		local size = g.size or 1
		if not buckets[size] then buckets[size] = {} end
		table.insert(buckets[size], g)
	end

	local usedGroupIds = {}

	for _, groups in buckets do
		-- Sort each bracket by avgMmr so adjacent entries have the closest rating
		table.sort(groups, function(a, b)
			return (a.avgMmr or a.mmr) < (b.avgMmr or b.mmr)
		end)

		for i = 1, #groups do
			local gA = groups[i]
			if usedGroupIds[gA.groupId] then continue end

			local aAvgMmr = gA.avgMmr or gA.mmr
			local spread = RankCalculator.getMMRSpread(gA.queueJoinTime)
			local teamA = { groups = { gA }, avgMmr = aAvgMmr, queueJoinTime = gA.queueJoinTime }

			for j = i + 1, #groups do
				local gB = groups[j]
				if usedGroupIds[gB.groupId] then continue end

				local bAvgMmr = gB.avgMmr or gB.mmr
				if (bAvgMmr - aAvgMmr) > spread then break end

				local teamB = { groups = { gB }, avgMmr = bAvgMmr, queueJoinTime = gB.queueJoinTime }

				if self:_tryMatchTeams(teamA, teamB) then
					usedGroupIds[gA.groupId] = true
					usedGroupIds[gB.groupId] = true
					matchesThisTick += 1
					break
				end
			end
		end
	end

	-- Remaining player count: total in snapshot minus those just matched
	local totalPlayers = 0
	local matchedPlayers = 0
	for _, g in snapshot do
		local size = g.size or 1
		totalPlayers += size
		if usedGroupIds[g.groupId] then matchedPlayers += size end
	end
	local remaining = totalPlayers - matchedPlayers

	local spreadExpandedCount = 0
	for _, g in snapshot do
		if RankCalculator.getMMRSpread(g.queueJoinTime) > Constants.BASE_MMR_SPREAD then
			spreadExpandedCount += (g.size or 1)
		end
	end

	if serverId == nil then
		local spreadNote = spreadExpandedCount > 0
			and string.format(" (spread expanded for %d players)", spreadExpandedCount)
			or ""
		print(string.format("[Queue] Tick %d — %d players waiting%s",
			self._tickCount, remaining, spreadNote))
	end

	if self._onTick then
		self._onTick({
			tickCount = self._tickCount,
			matchesThisTick = matchesThisTick,
			totalMatches = self._totalMatches,
			queueSize = remaining,
			spreadExpandedCount = spreadExpandedCount,
			recentMatches = self._recentMatches,
		})
	end

	return matchesThisTick
end

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
