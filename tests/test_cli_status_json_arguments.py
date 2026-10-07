#!/usr/bin/env python3
"""Exercise list-status dispatch through the real CLI and socket option parsers."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from regression_helpers import extract_block

ROOT = Path(__file__).resolve().parents[1]


class StatusJSONArgumentTests(unittest.TestCase):
    def test_json_mode_survives_option_terminator(self):
        cli = (ROOT / "CLI/cmux.swift").read_text()
        dispatch = cli.split('        case "list-status":', 1)[1].split('        case "set-progress":', 1)[0]
        sidebar = (ROOT / "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/Sidebar/ControlCommandCoordinator+SidebarV1.swift").read_text()
        methods = "\n".join(
            "nonisolated func " + signature + " " + extract_block(sidebar, "func " + signature)
            for signature in [
                "sidebarTokenizeArgs(_ args: String) -> [String]",
                "sidebarParseOptions(_ args: String) -> (positional: [String], options: [String: String])",
            ]
        )
        parser = (ROOT / "Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/CmuxCLIArgumentParser.swift").read_text()
        harness = """
import Foundation
struct Harness {
    let client = 0
    let windowId: String? = nil
    var forwarded: [String] = []
    METHODS
    mutating func forwardSidebarMetadataCommand(
        _ command: String, commandArgs: [String], client: Int, windowOverride: String?
    ) throws -> String {
        forwarded = commandArgs
        let parsed = sidebarParseOptions(commandArgs.map { "'" + $0 + "'" }.joined(separator: " "))
        let data = try JSONSerialization.data(withJSONObject: [
            "json": parsed.options["json"] == "true", "positional": parsed.positional,
            "tab": parsed.options["tab"] ?? "", "forwarded": forwarded
        ])
        return String(decoding: data, as: UTF8.self)
    }
    mutating func run(commandArgs: [String], jsonOutput: Bool) throws {
        switch "list-status" {
        case "list-status":
        DISPATCH
        default: break
        }
    }
}
let args = Array(CommandLine.arguments.dropFirst())
let parsed = try CmuxCLIArgumentParser().parse(Array(args.dropFirst()))
var harness = Harness()
try harness.run(commandArgs: parsed.remaining, jsonOutput: args[0] == "true" || parsed.jsonOutput)
""".replace("METHODS", methods).replace("DISPATCH", dispatch)
        cases = [
            (False, ["--json", "--"], True, []),
            (True, ["--"], True, []),
            (False, ["--json", "--tab=W", "--"], True, []),
            (False, ["--json"], True, []),
            (False, ["--"], False, []),
            (False, ["--", "--json"], False, ["--json"]),
            (True, ["--", "--json"], True, ["--json"]),
        ]
        with tempfile.TemporaryDirectory(prefix="cmux-status-json-") as directory:
            source = Path(directory) / "main.swift"
            binary = Path(directory) / "probe"
            source.write_text(parser + harness)
            subprocess.run(["swiftc", "-swift-version", "6", str(source), "-o", str(binary)], check=True, capture_output=True, text=True)
            for inherited, args, expected_json, positional in cases:
                with self.subTest(inherited=inherited, args=args):
                    result = subprocess.run([str(binary), str(inherited).lower(), *args], check=True, capture_output=True, text=True)
                    payload = json.loads(result.stdout)
                    self.assertEqual(payload["json"], expected_json, payload)
                    self.assertEqual(payload["positional"], positional, payload)
                    if "--tab=W" in args:
                        self.assertEqual(payload["tab"], "W")


if __name__ == "__main__":
    unittest.main()
