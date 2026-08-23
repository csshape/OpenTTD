/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file script_mcp.hpp A command channel between a script and an external process. */

#ifndef SCRIPT_MCP_HPP
#define SCRIPT_MCP_HPP

#include "script_object.hpp"

/**
 * Lets a script exchange messages with a process outside the game, so an
 * external planner (for example a language model behind an MCP server) can
 * decide what to build while the script carries the orders out.
 *
 * Scripts normally have no access to the outside world at all. This class
 * deliberately opens a narrow hole in that sandbox, and keeps it narrow:
 * the two files live at fixed paths inside the personal directory, under
 * "mcp/", and a script cannot name a path of its own.
 *
 * @api ai game
 */
class ScriptMCP : public ScriptObject {
public:
	/**
	 * Take the next queued command, removing it from the queue.
	 *
	 * The external process appends one command per line to
	 * "mcp/commands.jsonl" in the personal directory. Each call consumes the
	 * oldest line, so a command is never handed out twice.
	 *
	 * @return The command line, or null when the queue is empty.
	 */
	static std::optional<std::string> ReadCommand();

	/**
	 * Publish what the script currently knows, for the external process to read.
	 *
	 * Replaces "mcp/state.json" in the personal directory. The content is
	 * whatever the script wants to say; the game does not interpret it.
	 *
	 * @param state The text to publish, normally JSON.
	 * @return True when the file was written.
	 */
	static bool WriteState(const std::string &state);

	/**
	 * Report a finished command back to the external process.
	 *
	 * Appends one line to "mcp/results.jsonl" in the personal directory, so
	 * the planner can see how its orders turned out.
	 *
	 * @param result The text to append, normally JSON.
	 * @return True when the line was appended.
	 */
	static bool WriteResult(const std::string &result);
};

#endif /* SCRIPT_MCP_HPP */
