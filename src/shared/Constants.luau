-- Constants.luau
-- All tuning values. Change here, effects everywhere.

return {
	-- Backend toggle: false = Luau table mock, true = real MemoryStoreSortedMap
	USE_REAL_MEMORYSTORE = true,

	-- Set true to run StressTest instead of the normal demo
	RUN_STRESS_TEST = false,
	-- Rank MMR thresholds (inclusive lower bound)
	RANK_THRESHOLDS = {
		Bronze = 0,
		Silver = 600,
		Gold = 1200,
		Platinum = 1800,
		Diamond = 2400,
	},

	-- Matchmaking
	BASE_MMR_SPREAD = 150, -- initial eligible MMR window (±)
	SPREAD_PER_SECOND = 10, -- widens by this much each second a player waits
	MAX_MMR_SPREAD = 500, -- hard cap
	QUEUE_TICK_RATE = 3, -- seconds between queue scans
	TEAM_SIZE = 3, -- players per team (2 = 2v2, 5 = 5v5)
	QUEUE_TTL = 600, -- seconds before a queue entry auto-expires (crash safety net)
	--Base ELO K-factor (max MMR delta from a single match)
	K_FACTOR = 32,

	-- Stress test parameters
	DEMO_PLAYER_COUNT = 50, -- number of mock players to seed in demo mode
	STRESS_SERVER_COUNT = 50, -- number of simulated concurrent servers
	STRESS_PLAYER_COUNT = 500, -- players seeded into the shared queue
	-- How many consecutive empty-queue ticks before the stress test stops.
	-- Needs to be large enough that task.delay(5-10s) re-queues have time to land
	-- between ticks (tick rate = QUEUE_TICK_RATE seconds).
	-- e.g. 5 rounds × 3s/tick = 15s idle window — covers the max 10s re-queue delay.
	STRESS_IDLE_ROUNDS = 5,
}
