-- Constants.luau
-- All tuning values. Change here, effects everywhere.

return {
	-- Backend toggle: false = Luau table mock, true = real MemoryStoreSortedMap
	USE_REAL_MEMORYSTORE = false,

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
	QUEUE_TICK_RATE = 2, -- seconds between queue scans
	MATCH_SIZE = 2, -- players per match (expand for team modes)
	QUEUE_TTL = 600, -- seconds before a queue entry auto-expires (crash safety net)

	-- ELO
	K_FACTOR = 32,

	-- Rarity weights (must sum to 100 for clean percentages, but any positive values work)
	RARITY_WEIGHTS = {
		Common = 60,
		Uncommon = 25,
		Rare = 10,
		Epic = 4,
		Legendary = 1,
	},

	-- Stress test parameters
	STRESS_SERVER_COUNT = 5, -- number of simulated concurrent servers
	STRESS_PLAYER_COUNT = 100, -- players seeded into the shared queue
	STRESS_TICK_ROUNDS = 8, -- how many rounds of parallel ticks to run
}
