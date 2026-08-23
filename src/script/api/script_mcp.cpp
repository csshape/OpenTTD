/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file script_mcp.cpp Implementation of ScriptMCP. */

#include "../../stdafx.h"
#include "script_mcp.hpp"
#include "../../fileio_func.h"
#include "../../debug.h"

#include <fstream>
#include <sstream>

#include "../../safeguards.h"

/** Directory, inside the personal directory, holding the channel files. */
static const std::string MCP_SUBDIR = "mcp";

/**
 * Absolute path of one of the channel files.
 *
 * The name is chosen here rather than passed in, so a script can never point
 * this at a path of its own.
 */
static std::string McpPath(const std::string &name)
{
	std::string dir = _personal_dir;
	if (!dir.empty() && dir.back() != PATHSEPCHAR) dir += PATHSEPCHAR;
	dir += MCP_SUBDIR;
	dir += PATHSEPCHAR;

	FioCreateDirectory(dir);
	return dir + name;
}

/* static */ std::optional<std::string> ScriptMCP::ReadCommand()
{
	std::string path = McpPath("commands.jsonl");

	std::vector<std::string> lines;
	{
		std::ifstream in(path);
		if (!in.is_open()) return std::nullopt;

		std::string line;
		while (std::getline(in, line)) {
			/* Skip blank lines so a trailing newline is not a command. */
			if (!line.empty()) lines.push_back(line);
		}
	}
	if (lines.empty()) return std::nullopt;

	std::string command = lines.front();

	/* Write the remainder back, so the command is consumed exactly once. */
	std::ofstream out(path, std::ios::trunc);
	if (out.is_open()) {
		for (size_t i = 1; i < lines.size(); i++) out << lines[i] << "\n";
	} else {
		Debug(script, 0, "MCP: could not rewrite command queue at {}", path);
	}

	return command;
}

/* static */ bool ScriptMCP::WriteState(const std::string &state)
{
	std::ofstream out(McpPath("state.json"), std::ios::trunc);
	if (!out.is_open()) return false;
	out << state;
	return out.good();
}

/* static */ bool ScriptMCP::WriteResult(const std::string &result)
{
	std::ofstream out(McpPath("results.jsonl"), std::ios::app);
	if (!out.is_open()) return false;
	out << result << "\n";
	return out.good();
}
