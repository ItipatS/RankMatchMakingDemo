-- Types.luau
-- All shared type definitions. Never inline types in service files.

export type RankTier = "Bronze" | "Silver" | "Gold" | "Platinum" | "Diamond"
export type Region = "NA" | "EU" | "ASIA"

-- Shape of a mock player (mirrors a real player in production)
export type MockPlayer = {
	userId: number,
	displayName: string,
	mmr: number,
	rank: RankTier,
	wins: number,
	losses: number,
	region: Region,
	queueJoinTime: number, -- os.time() at queue entry (not os.clock — that resets per server)
	isBot: boolean,
}

-- What actually lives in MemoryStore per queued player
export type QueueEntry = {
	userId: number,
	displayName: string,
	mmr: number,
	rank: RankTier,
	region: Region,
	queueJoinTime: number,
	claimed: boolean, -- CAS flag: true means a server is in the process of matching this player
}

export type MatchResult = {
	playerA: QueueEntry,
	playerB: QueueEntry,
	mmrDeltaA: number, -- positive = playerA won
	mmrDeltaB: number,
	timestamp: number,
}

-- Instrumentation: unit costs match real MemoryStore billing
-- totalUnits = sum of all request units (UpdateAsync = 2 min, GetRangeAsync = 1 + items returned, others = 1)
export type AdapterStats = {
	totalUnits: number,
	setCalls: number,
	getRangeCalls: number,
	updateCalls: number,
	removeCalls: number,
}

return {}
