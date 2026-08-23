/**
 * EgernetAI - an aggressive bus operator.
 *
 * Performance notes, because an AI shares the game's tick budget:
 *  - Town pairs are enumerated once into a sorted work list, not rescanned
 *    every round. A naive double loop over towns is O(n^2) per round and each
 *    pair costs a tile scan, which is what makes an AI drag the game down.
 *  - Stop sites are cached per town, so a town is scanned at most once.
 *  - Exactly one construction attempt happens per round, followed by a Sleep,
 *    so opcodes are handed back to the game frequently.
 */

class EgernetAI extends AIController {
	routes = null;      /* [{a, b, depot, vehicles}] */
	pairs = null;       /* work list of [town_a, town_b], nearest-first */
	pair_index = 0;
	stop_cache = null;  /* town id -> [tile, front] or false when unusable */
	cargo = -1;
	aggression = 3;
	built_pairs = null; /* towns already served, so we spread out */

	constructor() {
		this.routes = [];
		this.pairs = [];
		this.stop_cache = {};
		this.built_pairs = {};
	}
}

function EgernetAI::GetPassengerCargo() {
	foreach (c, _ in AICargoList()) {
		if (AICargo.HasCargoClass(c, AICargo.CC_PASSENGERS)) return c;
	}
	return -1;
}

function EgernetAI::PickBus() {
	local list = AIEngineList(AIVehicle.VT_ROAD);
	local best = -1, best_score = -1;
	foreach (engine, _ in list) {
		if (!AIEngine.IsBuildable(engine)) continue;
		if (AIEngine.GetRoadType(engine) != AIRoad.ROADTYPE_ROAD) continue;
		if (AIEngine.GetCargoType(engine) != this.cargo && !AIEngine.CanRefitCargo(engine, this.cargo)) continue;

		local cap = AIEngine.GetCapacity(engine);
		if (cap <= 0) continue;
		local cost = AIEngine.GetRunningCost(engine);
		if (cost <= 0) cost = 1;
		local score = (cap * 1000 / cost) + AIEngine.GetMaxSpeed(engine);
		if (score > best_score) { best_score = score; best = engine; }
	}
	return best;
}

function EgernetAI::MaxOutLoan() {
	local max = AICompany.GetMaxLoanAmount();
	if (AICompany.GetLoanAmount() < max) AICompany.SetLoanAmount(max);
}

function EgernetAI::Money() {
	return AICompany.GetBankBalance(AICompany.COMPANY_SELF);
}

/**
 * Build the work list of town pairs once, nearest pairs first so early routes
 * are short and cheap. Only the largest towns are considered, which keeps the
 * list small and the routes worthwhile.
 */
function EgernetAI::BuildPairList() {
	local towns = AITownList();
	towns.Valuate(AITown.GetPopulation);
	towns.Sort(AIList.SORT_BY_VALUE, AIList.SORT_DESCENDING);
	towns.KeepTop(28);

	local ids = [];
	foreach (t, _ in towns) ids.append(t);

	local list = [];
	for (local i = 0; i < ids.len(); i++) {
		for (local j = i + 1; j < ids.len(); j++) {
			local dist = AIMap.DistanceManhattan(AITown.GetLocation(ids[i]), AITown.GetLocation(ids[j]));
			if (dist < 15 || dist > 80) continue;
			list.append([dist, ids[i], ids[j]]);
		}
		this.Sleep(1);
	}
	/* This Squirrel version has neither lambda syntax ('@' starts a verbatim
	 * string) nor the <=> operator, so compare the long way round. */
	list.sort(function(a, b) {
		if (a[0] < b[0]) return -1;
		if (a[0] > b[0]) return 1;
		return 0;
	});

	this.pairs = [];
	foreach (entry in list) this.pairs.append([entry[1], entry[2]]);
	AILog.Info("Work list: " + this.pairs.len() + " town pairs");
}

/**
 * Cached lookup of a drive-through stop site in a town.
 * Returns [tile, front], or null when the town has no usable spot.
 */
function EgernetAI::StopSite(town) {
	if (town in this.stop_cache) {
		local c = this.stop_cache[town];
		return (c == false) ? null : c;
	}

	local centre = AITown.GetLocation(town);
	local cx = AIMap.GetTileX(centre), cy = AIMap.GetTileY(centre);
	local found = null;

	/* Radius 8 is plenty for a town centre and keeps the scan bounded. */
	for (local dist = 1; dist <= 8 && found == null; dist++) {
		for (local dx = -dist; dx <= dist && found == null; dx++) {
			for (local dy = -dist; dy <= dist; dy++) {
				if (abs(dx) != dist && abs(dy) != dist) continue;

				local tile = AIMap.GetTileIndex(cx + dx, cy + dy);
				if (!AIMap.IsValidTile(tile)) continue;
				if (!AIRoad.IsRoadTile(tile)) continue;
				if (AIRoad.IsDriveThroughRoadStationTile(tile)) continue;

				local tx = AIMap.GetTileX(tile), ty = AIMap.GetTileY(tile);
				local west = AIMap.GetTileIndex(tx - 1, ty), east = AIMap.GetTileIndex(tx + 1, ty);
				local north = AIMap.GetTileIndex(tx, ty - 1), south = AIMap.GetTileIndex(tx, ty + 1);

				if (AIMap.IsValidTile(west) && AIMap.IsValidTile(east)
						&& AIRoad.IsRoadTile(west) && AIRoad.IsRoadTile(east)) {
					found = [tile, west];
					break;
				}
				if (AIMap.IsValidTile(north) && AIMap.IsValidTile(south)
						&& AIRoad.IsRoadTile(north) && AIRoad.IsRoadTile(south)) {
					found = [tile, north];
					break;
				}
			}
		}
		/* Yield between rings so a big scan never hogs a tick. */
		this.Sleep(1);
	}

	this.stop_cache[town] <- (found == null) ? false : found;
	return found;
}

/**
 * Lay one road tile and confirm the two tiles really are connected.
 *
 * BuildRoad returning false is not by itself a failure - the tile may already
 * carry road, which is what we want. The end state is what matters.
 */
function EgernetAI::LinkTiles(a, b) {
	if (AIRoad.AreRoadTilesConnected(a, b)) return true;
	AIRoad.BuildRoad(a, b);
	return AIRoad.AreRoadTilesConnected(a, b);
}

/** Can a road plausibly sit on this tile? */
function EgernetAI::Passable(tile) {
	if (!AIMap.IsValidTile(tile)) return false;
	if (AIRoad.IsRoadTile(tile)) return true;
	if (AITile.IsWaterTile(tile)) return false;
	if (AITile.IsStationTile(tile)) return false;
	if (!AITile.IsBuildable(tile)) return false;
	local slope = AITile.GetSlope(tile);
	if (slope == AITile.SLOPE_STEEP_W || slope == AITile.SLOPE_STEEP_S
			|| slope == AITile.SLOPE_STEEP_E || slope == AITile.SLOPE_STEEP_N) return false;
	return true;
}

/**
 * Breadth-first search for a road path between two tiles.
 *
 * An L-shaped path cannot route around an obstacle, which leaves roads that
 * stop short of the town they were meant to reach. Boxed to the area around
 * the endpoints and capped in nodes, because an AI shares the game's tick
 * budget and an unbounded flood fill would stall the game.
 */
function EgernetAI::FindPath(start, goal) {
	local sx = AIMap.GetTileX(start), sy = AIMap.GetTileY(start);
	local gx = AIMap.GetTileX(goal),  gy = AIMap.GetTileY(goal);

	local margin = 14;
	local min_x = (sx < gx ? sx : gx) - margin;
	local max_x = (sx > gx ? sx : gx) + margin;
	local min_y = (sy < gy ? sy : gy) - margin;
	local max_y = (sy > gy ? sy : gy) + margin;

	local came_from = {};
	local queue = [start];
	local head = 0;
	came_from[start] <- -1;

	local visited = 0;
	while (head < queue.len()) {
		local tile = queue[head];
		head++;

		if (tile == goal) break;
		if (++visited > 4000) return null;
		if (visited % 150 == 0) this.Sleep(1);

		local tx = AIMap.GetTileX(tile), ty = AIMap.GetTileY(tile);
		local neighbours = [
			AIMap.GetTileIndex(tx + 1, ty), AIMap.GetTileIndex(tx - 1, ty),
			AIMap.GetTileIndex(tx, ty + 1), AIMap.GetTileIndex(tx, ty - 1),
		];
		foreach (next in neighbours) {
			if (next in came_from) continue;
			local nx = AIMap.GetTileX(next), ny = AIMap.GetTileY(next);
			if (nx < min_x || nx > max_x || ny < min_y || ny > max_y) continue;
			if (next != goal && !this.Passable(next)) continue;
			came_from[next] <- tile;
			queue.append(next);
		}
	}

	if (!(goal in came_from)) return null;

	local reverse = [];
	local cur = goal;
	while (cur != -1) {
		reverse.append(cur);
		cur = came_from[cur];
	}
	local path = [];
	for (local i = reverse.len() - 1; i >= 0; i--) path.append(reverse[i]);
	return path;
}

/**
 * Connect two tiles by road along a searched path.
 *
 * One missing link fails the whole route: a road with a gap is worse than no
 * road, because the route reads as open and the buses have nowhere to go.
 */
function EgernetAI::ConnectTiles(from, to) {
	local path = this.FindPath(from, to);
	if (path == null) return false;

	AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
	for (local i = 0; i < path.len() - 1; i++) {
		if (!this.LinkTiles(path[i], path[i + 1])) return false;
		if (i % 15 == 0) this.Sleep(1);
	}
	return true;
}

function EgernetAI::BuildDepotNear(stop_tile) {
	AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
	local x = AIMap.GetTileX(stop_tile), y = AIMap.GetTileY(stop_tile);

	for (local dist = 1; dist <= 5; dist++) {
		for (local dx = -dist; dx <= dist; dx++) {
			for (local dy = -dist; dy <= dist; dy++) {
				if (abs(dx) != dist && abs(dy) != dist) continue;
				local road = AIMap.GetTileIndex(x + dx, y + dy);
				if (!AIMap.IsValidTile(road) || !AIRoad.IsRoadTile(road)) continue;

				local rx = AIMap.GetTileX(road), ry = AIMap.GetTileY(road);
				local plots = [
					AIMap.GetTileIndex(rx + 1, ry), AIMap.GetTileIndex(rx - 1, ry),
					AIMap.GetTileIndex(rx, ry + 1), AIMap.GetTileIndex(rx, ry - 1),
				];
				foreach (plot in plots) {
					if (!AIMap.IsValidTile(plot) || !AITile.IsBuildable(plot)) continue;
					if (!AIRoad.BuildRoadDepot(plot, road)) continue;
					/* A depot the buses cannot drive out of is useless. */
					if (this.LinkTiles(plot, road)) return plot;
					AITile.DemolishTile(plot);
				}
			}
		}
		this.Sleep(1);
	}
	return -1;
}

function EgernetAI::AddVehicle(route, engine) {
	if (this.Money() < AIEngine.GetPrice(engine) * 2) return false;

	local v = AIVehicle.BuildVehicle(route.depot, engine);
	if (!AIVehicle.IsValidVehicle(v)) return false;
	if (AIEngine.GetCargoType(engine) != this.cargo) AIVehicle.RefitVehicle(v, this.cargo);

	AIOrder.AppendOrder(v, route.a, AIOrder.OF_NON_STOP_INTERMEDIATE);
	AIOrder.AppendOrder(v, route.b, AIOrder.OF_NON_STOP_INTERMEDIATE);
	AIVehicle.StartStopVehicle(v);
	route.vehicles.append(v);
	return true;
}

function EgernetAI::TryPair(town_a, town_b, engine) {
	local site_a = this.StopSite(town_a);
	if (site_a == null) return false;
	local site_b = this.StopSite(town_b);
	if (site_b == null) return false;

	AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);

	if (!AIRoad.BuildDriveThroughRoadStation(site_a[0], site_a[1], AIRoad.ROADVEHTYPE_BUS, AIStation.STATION_NEW)
			&& AIError.GetLastError() != AIError.ERR_ALREADY_BUILT) {
		return false;
	}
	if (!AIRoad.BuildDriveThroughRoadStation(site_b[0], site_b[1], AIRoad.ROADVEHTYPE_BUS, AIStation.STATION_NEW)
			&& AIError.GetLastError() != AIError.ERR_ALREADY_BUILT) {
		return false;
	}
	if (!this.ConnectTiles(site_a[0], site_b[0])) return false;

	local depot = this.BuildDepotNear(site_a[0]);
	if (depot == -1) return false;

	local route = { a = site_a[0], b = site_b[0], depot = depot, vehicles = [] };
	local wanted = 2 + this.aggression;
	for (local i = 0; i < wanted; i++) {
		if (!this.AddVehicle(route, engine)) break;
	}
	if (route.vehicles.len() == 0) return false;

	this.routes.append(route);
	AILog.Info("Route " + this.routes.len() + ": " + AITown.GetName(town_a) + " <-> " + AITown.GetName(town_b)
		+ " (" + route.vehicles.len() + " buses)");
	return true;
}

/** One construction attempt per call, walking the pre-built work list. */
function EgernetAI::TryNextPair(engine) {
	local attempts = 0;
	while (this.pair_index < this.pairs.len() && attempts < 3) {
		local pair = this.pairs[this.pair_index];
		this.pair_index++;
		attempts++;

		/* Don't stack many routes on the same town early on. */
		local key_a = "t" + pair[0], key_b = "t" + pair[1];
		local served_a = (key_a in this.built_pairs) ? this.built_pairs[key_a] : 0;
		local served_b = (key_b in this.built_pairs) ? this.built_pairs[key_b] : 0;
		if (served_a >= 2 || served_b >= 2) continue;

		if (this.TryPair(pair[0], pair[1], engine)) {
			this.built_pairs[key_a] <- served_a + 1;
			this.built_pairs[key_b] <- served_b + 1;
			return true;
		}
	}
	return false;
}

function EgernetAI::Reinforce(engine) {
	local cap = this.aggression * 8;
	foreach (route in this.routes) {
		local station = AIStation.GetStationID(route.a);
		if (!AIStation.IsValidStation(station)) continue;
		if (route.vehicles.len() >= cap) continue;
		if (AIStation.GetCargoWaiting(station, this.cargo) < 30) continue;
		if (this.Money() < AIEngine.GetPrice(engine) * 3) break;
		this.AddVehicle(route, engine);
	}
}

function EgernetAI::Housekeeping() {
	foreach (route in this.routes) {
		for (local i = route.vehicles.len() - 1; i >= 0; i--) {
			local v = route.vehicles[i];
			if (!AIVehicle.IsValidVehicle(v)) { route.vehicles.remove(i); continue; }
			if (AIVehicle.GetAge(v) > 730 && AIVehicle.GetProfitLastYear(v) < 0) {
				AIVehicle.SendVehicleToDepot(v);
			}
		}
	}
}

function EgernetAI::Start() {
	AICompany.SetName("Egernet Transport");
	this.aggression = AIController.GetSetting("aggression");

	this.cargo = this.GetPassengerCargo();
	if (this.cargo == -1) {
		AILog.Error("No passenger cargo in this climate; nothing to do.");
		return;
	}

	this.MaxOutLoan();
	this.BuildPairList();

	local round = 0;
	while (true) {
		round++;
		this.MaxOutLoan();

		local engine = this.PickBus();
		if (engine == -1) {
			this.Sleep(300);
			continue;
		}

		/* Reinforcing is cheap; do it every round. */
		this.Reinforce(engine);

		/* Building is expensive; one attempt per round, and only with a buffer. */
		if (this.Money() > AIEngine.GetPrice(engine) * 8) {
			if (!this.TryNextPair(engine) && this.pair_index >= this.pairs.len()) {
				/* Exhausted the list: rebuild it, towns may have grown. */
				this.pair_index = 0;
				this.stop_cache = {};
				this.BuildPairList();
				this.Sleep(500);
			}
		}

		if (round % 10 == 0) this.Housekeeping();

		this.Sleep(75);
	}
}

function EgernetAI::Save() { return {}; }
function EgernetAI::Load(version, data) { }
