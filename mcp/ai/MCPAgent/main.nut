/**
 * MCPAgent - the in-game half of the MCP bridge.
 *
 * It does no planning of its own. Every round it publishes what it can see to
 * mcp/state.json and then executes whatever orders have been queued in
 * mcp/commands.jsonl, reporting the outcome to mcp/results.jsonl.
 *
 * Orders are pipe-separated rather than JSON, because this Squirrel dialect has
 * no JSON parser and hand-rolling one inside a tick budget is a poor trade:
 *
 *   <id>|<action>|<arg>|<arg>...
 *
 * Supported actions:
 *   bus_route|<town_a>|<town_b>       open a bus route between two towns
 *   add_buses|<route>|<count>         put more buses on an existing route
 *   truck_route|<ind_a>|<ind_b>       open a lorry route between two industries
 *   sell_vehicle|<vehicle>            get rid of one vehicle
 *   set_name|<text>                   rename the company
 *   loan|<amount>                     set the loan (-1 means take the maximum)
 */

class MCPAgent extends AIController {
	routes = null;      /* [{kind, a, b, depot, cargo, vehicles}] */
	poll_ticks = 25;
	round = 0;
	last_error = "";

	constructor() {
		this.routes = [];
	}
}

/* ------------------------------------------------------------------ helpers */

function MCPAgent::Money() {
	return AICompany.GetBankBalance(AICompany.COMPANY_SELF);
}

/** Split a string on '|' - this dialect has no split(). */
function MCPAgent::Split(text) {
	local parts = [];
	local current = "";
	for (local i = 0; i < text.len(); i++) {
		local ch = text.slice(i, i + 1);
		if (ch == "|") {
			parts.append(current);
			current = "";
		} else {
			current += ch;
		}
	}
	parts.append(current);
	return parts;
}

/** Escape the few characters that would break a JSON string. */
function MCPAgent::Esc(text) {
	local out = "";
	for (local i = 0; i < text.len(); i++) {
		local ch = text.slice(i, i + 1);
		if (ch == "\"") out += "\\\"";
		else if (ch == "\\") out += "\\\\";
		else if (ch == "\n") out += " ";
		else out += ch;
	}
	return out;
}

function MCPAgent::PassengerCargo() {
	foreach (c, _ in AICargoList()) {
		if (AICargo.HasCargoClass(c, AICargo.CC_PASSENGERS)) return c;
	}
	return -1;
}

function MCPAgent::PickEngine(cargo) {
	local list = AIEngineList(AIVehicle.VT_ROAD);
	local best = -1, best_score = -1;
	foreach (engine, _ in list) {
		if (!AIEngine.IsBuildable(engine)) continue;
		if (AIEngine.GetRoadType(engine) != AIRoad.ROADTYPE_ROAD) continue;
		if (AIEngine.GetCargoType(engine) != cargo && !AIEngine.CanRefitCargo(engine, cargo)) continue;
		local cap = AIEngine.GetCapacity(engine);
		if (cap <= 0) continue;
		local cost = AIEngine.GetRunningCost(engine);
		if (cost <= 0) cost = 1;
		local score = (cap * 1000 / cost) + AIEngine.GetMaxSpeed(engine);
		if (score > best_score) { best_score = score; best = engine; }
	}
	return best;
}

/* ------------------------------------------------------- state publication */

function MCPAgent::PublishState() {
	local s = "{";
	s += "\"tick\":" + AIController.GetTick();
	s += ",\"year\":" + AIDate.GetYear(AIDate.GetCurrentDate());
	s += ",\"money\":" + this.Money();
	s += ",\"loan\":" + AICompany.GetLoanAmount();
	s += ",\"max_loan\":" + AICompany.GetMaxLoanAmount();
	s += ",\"map\":{\"x\":" + AIMap.GetMapSizeX() + ",\"y\":" + AIMap.GetMapSizeY() + "}";

	/* Towns: the planner mostly reasons about these. */
	local towns = AITownList();
	towns.Valuate(AITown.GetPopulation);
	towns.Sort(AIList.SORT_BY_VALUE, AIList.SORT_DESCENDING);
	towns.KeepTop(40);
	s += ",\"towns\":[";
	local first = true;
	foreach (t, pop in towns) {
		local loc = AITown.GetLocation(t);
		if (!first) s += ",";
		first = false;
		s += "{\"id\":" + t;
		s += ",\"name\":\"" + this.Esc(AITown.GetName(t)) + "\"";
		s += ",\"pop\":" + pop;
		s += ",\"x\":" + AIMap.GetTileX(loc) + ",\"y\":" + AIMap.GetTileY(loc) + "}";
	}
	s += "]";
	this.Sleep(1);

	/* Industries, so lorry routes can be planned. */
	local inds = AIIndustryList();
	s += ",\"industries\":[";
	first = true;
	local count = 0;
	foreach (i, _ in inds) {
		if (count++ >= 40) break;
		local loc = AIIndustry.GetLocation(i);
		if (!first) s += ",";
		first = false;
		s += "{\"id\":" + i;
		s += ",\"name\":\"" + this.Esc(AIIndustry.GetName(i)) + "\"";
		s += ",\"x\":" + AIMap.GetTileX(loc) + ",\"y\":" + AIMap.GetTileY(loc) + "}";
	}
	s += "]";
	this.Sleep(1);

	/* Our own routes and how they are doing. */
	s += ",\"routes\":[";
	first = true;
	for (local r = 0; r < this.routes.len(); r++) {
		local route = this.routes[r];
		local alive = 0, profit = 0;
		foreach (v in route.vehicles) {
			if (!AIVehicle.IsValidVehicle(v)) continue;
			alive++;
			profit += AIVehicle.GetProfitThisYear(v);
		}
		local station = AIStation.GetStationID(route.a);
		local waiting = AIStation.IsValidStation(station) ? AIStation.GetCargoWaiting(station, route.cargo) : 0;
		if (!first) s += ",";
		first = false;
		s += "{\"index\":" + r;
		s += ",\"kind\":\"" + route.kind + "\"";
		s += ",\"vehicles\":" + alive;
		s += ",\"profit_this_year\":" + profit;
		s += ",\"waiting_at_a\":" + waiting + "}";
	}
	s += "]}";

	AIMCP.WriteState(s);
}

/* ------------------------------------------------------------- construction */

/** Find a drive-through stop site near a tile. Returns [tile, front] or null. */
function MCPAgent::StopSiteNear(centre, radius) {
	local cx = AIMap.GetTileX(centre), cy = AIMap.GetTileY(centre);
	for (local dist = 1; dist <= radius; dist++) {
		for (local dx = -dist; dx <= dist; dx++) {
			for (local dy = -dist; dy <= dist; dy++) {
				if (abs(dx) != dist && abs(dy) != dist) continue;
				local tile = AIMap.GetTileIndex(cx + dx, cy + dy);
				if (!AIMap.IsValidTile(tile) || !AIRoad.IsRoadTile(tile)) continue;
				if (AIRoad.IsDriveThroughRoadStationTile(tile)) continue;

				local tx = AIMap.GetTileX(tile), ty = AIMap.GetTileY(tile);
				local w = AIMap.GetTileIndex(tx - 1, ty), e = AIMap.GetTileIndex(tx + 1, ty);
				local n = AIMap.GetTileIndex(tx, ty - 1), so = AIMap.GetTileIndex(tx, ty + 1);
				if (AIMap.IsValidTile(w) && AIMap.IsValidTile(e) && AIRoad.IsRoadTile(w) && AIRoad.IsRoadTile(e)) return [tile, w];
				if (AIMap.IsValidTile(n) && AIMap.IsValidTile(so) && AIRoad.IsRoadTile(n) && AIRoad.IsRoadTile(so)) return [tile, n];
			}
		}
		this.Sleep(1);
	}
	return null;
}

/**
 * Lay one road tile and confirm the two tiles really are connected.
 *
 * BuildRoad returning false is not by itself a failure: the tile may already
 * carry road, which is exactly what we want. What matters is the end state, so
 * check that rather than the return value.
 */
function MCPAgent::LinkTiles(a, b) {
	if (AIRoad.AreRoadTilesConnected(a, b)) return true;
	AIRoad.BuildRoad(a, b);
	return AIRoad.AreRoadTilesConnected(a, b);
}

/** Can a road plausibly sit on this tile? */
function MCPAgent::Passable(tile) {
	if (!AIMap.IsValidTile(tile)) return false;
	if (AIRoad.IsRoadTile(tile)) return true;
	if (AITile.IsWaterTile(tile)) return false;
	if (AITile.IsStationTile(tile)) return false;
	if (!AITile.IsBuildable(tile)) return false;
	/* Steep slopes cannot take road without terraforming. */
	local slope = AITile.GetSlope(tile);
	if (slope == AITile.SLOPE_STEEP_W || slope == AITile.SLOPE_STEEP_S
			|| slope == AITile.SLOPE_STEEP_E || slope == AITile.SLOPE_STEEP_N) return false;
	return true;
}

/**
 * Breadth-first search for a road path between two tiles.
 *
 * An L-shaped path cannot go around anything, which is how a route ends up
 * with a road that stops in a forest and never reaches the town. This walks
 * the map properly instead.
 *
 * The search is boxed to the area around the two endpoints and capped in nodes,
 * because a script shares the game's tick budget and an unbounded flood fill
 * would stall the game.
 *
 * @return An array of tiles from start to goal, or null.
 */
function MCPAgent::FindPath(start, goal) {
	local sx = AIMap.GetTileX(start), sy = AIMap.GetTileY(start);
	local gx = AIMap.GetTileX(goal),  gy = AIMap.GetTileY(goal);

	/* Search box: the endpoints plus room to detour around obstacles. */
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
	local node_cap = 4000;

	while (head < queue.len()) {
		local tile = queue[head];
		head++;

		if (tile == goal) break;
		if (++visited > node_cap) return null;
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
			/* The goal itself is a station tile, so let it through. */
			if (next != goal && !this.Passable(next)) continue;

			came_from[next] <- tile;
			queue.append(next);
		}
	}

	if (!(goal in came_from)) return null;

	/* Walk the parents back, then reverse. */
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
 * Connect two tiles by road, following a searched path.
 *
 * Every link is confirmed, and a single missing link fails the whole thing: a
 * road with a gap is worse than no road, because the route looks finished and
 * the vehicles have nowhere to go.
 */
function MCPAgent::ConnectTiles(from, to) {
	local path = this.FindPath(from, to);
	if (path == null) return false;

	AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
	for (local i = 0; i < path.len() - 1; i++) {
		if (!this.LinkTiles(path[i], path[i + 1])) return false;
		if (i % 15 == 0) this.Sleep(1);
	}
	return true;
}

function MCPAgent::BuildDepotNear(stop_tile) {
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
					/* A depot the vehicles cannot drive out of is useless, so
					 * confirm the link instead of assuming it. */
					if (this.LinkTiles(plot, road)) return plot;
					AITile.DemolishTile(plot);
				}
			}
		}
		this.Sleep(1);
	}
	return -1;
}

function MCPAgent::AddVehicleTo(route, count) {
	local engine = this.PickEngine(route.cargo);
	if (engine == -1) return 0;
	local added = 0;
	for (local i = 0; i < count; i++) {
		if (this.Money() < AIEngine.GetPrice(engine) * 2) break;
		local v = AIVehicle.BuildVehicle(route.depot, engine);
		if (!AIVehicle.IsValidVehicle(v)) break;
		if (AIEngine.GetCargoType(engine) != route.cargo) AIVehicle.RefitVehicle(v, route.cargo);
		AIOrder.AppendOrder(v, route.a, AIOrder.OF_NON_STOP_INTERMEDIATE);
		AIOrder.AppendOrder(v, route.b, AIOrder.OF_NON_STOP_INTERMEDIATE);
		AIVehicle.StartStopVehicle(v);
		route.vehicles.append(v);
		added++;
	}
	return added;
}

/**
 * Open a road route between two points, with a station type chosen by caller.
 * Returns the route index, or -1.
 */
function MCPAgent::OpenRoadRoute(kind, loc_a, loc_b, cargo, veh_type) {
	/* Record why we gave up, so a failed order says something useful. */
	this.last_error = "";

	local site_a = this.StopSiteNear(loc_a, 8);
	if (site_a == null) { this.last_error = "no room for a stop at the first end"; return -1; }
	local site_b = this.StopSiteNear(loc_b, 8);
	if (site_b == null) { this.last_error = "no room for a stop at the second end"; return -1; }

	AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_ROAD);
	if (!AIRoad.BuildDriveThroughRoadStation(site_a[0], site_a[1], veh_type, AIStation.STATION_NEW)
			&& AIError.GetLastError() != AIError.ERR_ALREADY_BUILT) {
		this.last_error = "could not build the first stop: " + AIError.GetLastErrorString();
		return -1;
	}
	if (!AIRoad.BuildDriveThroughRoadStation(site_b[0], site_b[1], veh_type, AIStation.STATION_NEW)
			&& AIError.GetLastError() != AIError.ERR_ALREADY_BUILT) {
		this.last_error = "could not build the second stop: " + AIError.GetLastErrorString();
		return -1;
	}
	if (!this.ConnectTiles(site_a[0], site_b[0])) {
		this.last_error = "no road path between the stops";
		return -1;
	}

	local depot = this.BuildDepotNear(site_a[0]);
	if (depot == -1) { this.last_error = "no room for a depot near the first stop"; return -1; }

	local route = { kind = kind, a = site_a[0], b = site_b[0], depot = depot, cargo = cargo, vehicles = [] };
	this.routes.append(route);
	return this.routes.len() - 1;
}

/* ----------------------------------------------------------- order handling */

function MCPAgent::Report(id, ok, message) {
	local s = "{\"id\":\"" + this.Esc(id) + "\",\"ok\":" + (ok ? "true" : "false");
	s += ",\"message\":\"" + this.Esc(message) + "\"}";
	AIMCP.WriteResult(s);
	AILog.Info((ok ? "OK   " : "FAIL ") + id + ": " + message);
}

function MCPAgent::Execute(line) {
	local parts = this.Split(line);
	if (parts.len() < 2) {
		this.Report("?", false, "malformed order: " + line);
		return;
	}
	local id = parts[0];
	local action = parts[1];

	if (action == "set_name") {
		if (parts.len() < 3) { this.Report(id, false, "set_name needs a name"); return; }
		AICompany.SetName(parts[2]);
		this.Report(id, true, "renamed to " + parts[2]);
		return;
	}

	if (action == "loan") {
		if (parts.len() < 3) { this.Report(id, false, "loan needs an amount"); return; }
		local amount = parts[2].tointeger();
		if (amount < 0) amount = AICompany.GetMaxLoanAmount();
		AICompany.SetLoanAmount(amount);
		this.Report(id, true, "loan set to " + AICompany.GetLoanAmount());
		return;
	}

	if (action == "bus_route") {
		if (parts.len() < 4) { this.Report(id, false, "bus_route needs two town ids"); return; }
		local ta = parts[2].tointeger(), tb = parts[3].tointeger();
		if (!AITown.IsValidTown(ta) || !AITown.IsValidTown(tb)) { this.Report(id, false, "invalid town id"); return; }
		local cargo = this.PassengerCargo();
		if (cargo == -1) { this.Report(id, false, "no passenger cargo in this climate"); return; }

		local idx = this.OpenRoadRoute("bus", AITown.GetLocation(ta), AITown.GetLocation(tb), cargo, AIRoad.ROADVEHTYPE_BUS);
		if (idx == -1) { this.Report(id, false, AITown.GetName(ta) + " <-> " + AITown.GetName(tb) + ": " + this.last_error); return; }
		local n = this.AddVehicleTo(this.routes[idx], 3);
		this.Report(id, true, "route " + idx + " open: " + AITown.GetName(ta) + " <-> " + AITown.GetName(tb) + ", " + n + " buses");
		return;
	}

	if (action == "truck_route") {
		if (parts.len() < 4) { this.Report(id, false, "truck_route needs two industry ids"); return; }
		local ia = parts[2].tointeger(), ib = parts[3].tointeger();
		if (!AIIndustry.IsValidIndustry(ia) || !AIIndustry.IsValidIndustry(ib)) { this.Report(id, false, "invalid industry id"); return; }

		/* Pick a cargo the source produces and the destination accepts. */
		local cargo = -1;
		foreach (c, _ in AICargoList()) {
			if (AIIndustry.IsCargoAccepted(ib, c) == AIIndustry.CAS_ACCEPTED
					&& AIIndustry.GetLastMonthProduction(ia, c) > 0) {
				cargo = c;
				break;
			}
		}
		if (cargo == -1) { this.Report(id, false, "no cargo links those industries"); return; }

		local idx = this.OpenRoadRoute("truck", AIIndustry.GetLocation(ia), AIIndustry.GetLocation(ib), cargo, AIRoad.ROADVEHTYPE_TRUCK);
		if (idx == -1) { this.Report(id, false, AIIndustry.GetName(ia) + " -> " + AIIndustry.GetName(ib) + ": " + this.last_error); return; }
		local n = this.AddVehicleTo(this.routes[idx], 3);
		this.Report(id, true, "route " + idx + " open: " + AIIndustry.GetName(ia) + " -> " + AIIndustry.GetName(ib)
			+ " (" + AICargo.GetCargoLabel(cargo) + "), " + n + " lorries");
		return;
	}

	if (action == "add_buses" || action == "add_vehicles") {
		if (parts.len() < 4) { this.Report(id, false, "needs route index and count"); return; }
		local idx = parts[2].tointeger(), count = parts[3].tointeger();
		if (idx < 0 || idx >= this.routes.len()) { this.Report(id, false, "no such route"); return; }
		local n = this.AddVehicleTo(this.routes[idx], count);
		this.Report(id, n > 0, "added " + n + " of " + count + " to route " + idx);
		return;
	}

	if (action == "sell_vehicle") {
		if (parts.len() < 3) { this.Report(id, false, "sell_vehicle needs a vehicle id"); return; }
		local v = parts[2].tointeger();
		if (!AIVehicle.IsValidVehicle(v)) { this.Report(id, false, "invalid vehicle"); return; }
		AIVehicle.SendVehicleToDepot(v);
		this.Report(id, true, "vehicle " + v + " sent to depot for selling");
		return;
	}

	this.Report(id, false, "unknown action: " + action);
}

/* --------------------------------------------------------------- main loop */

function MCPAgent::Start() {
	AICompany.SetName("MCP Planner");
	this.poll_ticks = AIController.GetSetting("poll_ticks");
	AILog.Info("MCPAgent ready; waiting for orders on mcp/commands.jsonl");

	while (true) {
		this.round++;

		/* Publish first, so a planner always has fresh ground truth. */
		this.PublishState();

		/* Drain the queue, but bounded, so one round cannot run away. */
		local handled = 0;
		while (handled < 4) {
			local line = AIMCP.ReadCommand();
			if (line == null) break;
			this.Execute(line);
			handled++;
		}

		this.Sleep(this.poll_ticks);
	}
}

function MCPAgent::Save() { return {}; }
function MCPAgent::Load(version, data) { }
