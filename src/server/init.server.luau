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
-- For StressTest mode, Look for StressTest module. 
local MemoryStoreAdapter = require(script.MemoryStoreAdapter)
local MockPlayerProvider = require(script.MockPlayerProvider)
local MatchmakingModule = require(script.MatchmakingService)

local adapter = MemoryStoreAdapter.new("MatchmakingQueue")
local MatchmakingService = MatchmakingModule.new(adapter)

-- Log every match result to output
MatchmakingService:onMatch(function(result)
	-- Determine winner and loser from deltas
	local winnerEntry = result.mmrDeltaA > 0 and result.playerA or result.playerB
	local loserEntry = result.mmrDeltaA > 0 and result.playerB or result.playerA
	local deltaWin = math.abs(result.mmrDeltaA) > math.abs(result.mmrDeltaB) and result.mmrDeltaA or result.mmrDeltaB
	local deltaLose = math.abs(result.mmrDeltaA) < math.abs(result.mmrDeltaB) and result.mmrDeltaA or result.mmrDeltaB

	print(string.format(
		"[Match] %s (%s %d MMR) vs %s (%s %d MMR) — MATCHED",
		result.playerA.displayName, result.playerA.rank, result.playerA.mmr,
		result.playerB.displayName, result.playerB.rank, result.playerB.mmr
	))
	print(string.format(
		"[MMR]   %s %+d → %d | %s %+d → %d",
		winnerEntry.displayName, deltaWin, winnerEntry.mmr + deltaWin,
		loserEntry.displayName, deltaLose, loserEntry.mmr + deltaLose
	))
end)

-- Bulk-enqueue all seeded players for simple test
if not Constants.RUN_STRESS_TEST then
    MockPlayerProvider.seed(20)
    local players = MockPlayerProvider.drainAll()
    for _, player in players do
        print(string.format("[Main] Enqueuing player %s (%s, %d MMR)", player.displayName, player.rank, player.mmr))
        MatchmakingService:enqueue(player)
        task.wait(math.random(1, 3)) -- random delay to simulate real player join timing and allow interleaving of matchmaking ticks
    end
    print(string.format("[MockProvider] Enqueued %d players into queue", #players))
end

-- Start the queue loop
MatchmakingService:start()
