-- Main.server.luau (init.server.luau)
-- Entry point. Wires everything together and runs the demo or stress test.
-- Set Constants.RUN_STRESS_TEST = true to run the stress test instead.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

-- ── Stress test mode ─────────────────────────────────────────────────────────
if Constants.RUN_STRESS_TEST then
	require(script.StressTest).run()
	return
end

-- ── Normal demo mode ─────────────────────────────────────────────────────────
local MemoryStoreAdapter = require(script.MemoryStoreAdapter)
local MockPlayerProvider = require(script.MockPlayerProvider)
local MatchmakingModule  = require(script.MatchmakingService)
local DashboardBridge    = require(script.DashboardBridge)

local adapter = MemoryStoreAdapter.new("MatchmakingQueue")
local MatchmakingService = MatchmakingModule.new(adapter)
DashboardBridge.new(MatchmakingService, adapter):start()

-- Log every match result to output
local function teamStr(members)
	local parts = {}
	for _, m in members do
		table.insert(parts, string.format("%s (%s %d)", m.displayName, m.rank, m.mmr))
	end
	return table.concat(parts, " + ")
end

MatchmakingService:onMatch(function(result)
	print(string.format(
		"[Match][%s] Team A [%.0f avg]: %s",
		result.matchType, result.avgMmrA, teamStr(result.teamA)
	))
	print(string.format(
		"[Match][%s] Team B [%.0f avg]: %s",
		result.matchType, result.avgMmrB, teamStr(result.teamB)
	))
	print(string.format(
		"[MMR]   Team A %+d | Team B %+d | Winner: Team %s",
		result.mmrDeltaA, result.mmrDeltaB, result.winner
	))

	-- Re-queue players in random group sizes (1, 2, or 3) after a simulated match.
	-- Shuffle all matched players first so pairings change each time.
	local matchDuration = math.random(5, 10)
	task.delay(matchDuration, function()
		local all = {}
		for _, team in { result.teamA, result.teamB } do
			for _, m in team do table.insert(all, m) end
		end
		-- Fisher-Yates shuffle
		for i = #all, 2, -1 do
			local j = math.random(1, i)
			all[i], all[j] = all[j], all[i]
		end
		-- Pack into random-sized groups and enqueue
		local idx = 1
		local gCounter = 0
		while idx <= #all do
			local size = math.min(math.random(1, 3), #all - idx + 1)
			local members, totalMmr, ids = {}, 0, {}
			for k = idx, idx + size - 1 do
				local m = all[k]
				table.insert(members, { userId=m.userId, displayName=m.displayName,
					mmr=m.mmr, rank=m.rank, region=m.region or "NA" })
				totalMmr += m.mmr
				table.insert(ids, tostring(m.userId))
			end
			gCounter += 1
			MatchmakingService:enqueueGroup({
				groupId       = "rq" .. gCounter .. "_" .. table.concat(ids, "_"),
				members       = members,
				avgMmr        = totalMmr / size,
				size          = size,
				queueType     = math.random(size, 3), -- solo can queue for any type; duo only 2v2/3v3
				region        = members[1].region or "NA",
				queueJoinTime = os.clock(),
				claimed       = false,
			})
			idx += size
		end
	end)
end)

-- Mixed seed: random distribution of solos, duos, trios across 40 players
-- Exercises 1v1, 2v2, and 3v3 brackets in a single run
local groups = MockPlayerProvider.seedMixed(Constants.DEMO_PLAYER_COUNT)
for _, group in groups do
	local names = {}
	for _, m in group.members do table.insert(names, m.displayName) end
	print(string.format("[Main] Enqueuing %s [size=%d, %.0f avgMMR]",
		table.concat(names, "+"), group.size, group.avgMmr))
	MatchmakingService:enqueueGroup(group)
end
print(string.format("[Main] Enqueued %d groups into queue", #groups))

-- Start the queue loop
MatchmakingService:start()