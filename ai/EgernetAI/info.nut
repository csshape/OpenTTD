class EgernetAI extends AIInfo {
	function GetAuthor()        { return "Egernet"; }
	function GetName()          { return "EgernetAI"; }
	function GetShortName()     { return "EGAI"; }
	function GetDescription()   { return "Aggressive bus operator: borrows to the hilt and floods town pairs with passenger routes."; }
	function GetVersion()       { return 1; }
	function GetDate()          { return "2026-08-23"; }
	function CreateInstance()   { return "EgernetAI"; }
	function GetAPIVersion()    { return "15"; }

	function GetSettings() {
		AddSetting({
			name = "aggression",
			description = "How hard to expand (higher borrows and builds more)",
			easy_value = 1, medium_value = 2, hard_value = 3,
			custom_value = 3, flags = AICONFIG_INGAME,
			min_value = 1, max_value = 3
		});
	}
}

RegisterAI(EgernetAI());
