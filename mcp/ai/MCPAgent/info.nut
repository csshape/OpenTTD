class MCPAgent extends AIInfo {
	function GetAuthor()      { return "Egernet"; }
	function GetName()        { return "MCPAgent"; }
	function GetShortName()   { return "MCPA"; }
	function GetDescription() { return "Carries out orders from an external planner over the MCP channel, and publishes what it sees."; }
	function GetVersion()     { return 1; }
	function GetDate()        { return "2026-08-23"; }
	function CreateInstance() { return "MCPAgent"; }
	function GetAPIVersion()  { return "15"; }

	function GetSettings() {
		AddSetting({
			name = "poll_ticks",
			description = "Ticks between checks for new orders (lower reacts faster, costs more)",
			easy_value = 40, medium_value = 25, hard_value = 15,
			custom_value = 25, flags = AICONFIG_INGAME,
			min_value = 5, max_value = 200
		});
	}
}

RegisterAI(MCPAgent());
