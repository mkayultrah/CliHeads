import Foundation

func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("Test failed: \(label)") }
    print("PASS \(label)")
}

var buffer = JSONLineBuffer()
let utf8 = "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello 🌿\"}}}\n"
let bytes = Data(utf8.utf8)
let split = bytes.count - 3
check(buffer.append(Data(bytes.prefix(split))).isEmpty, "Partial UTF-8 line buffered")
let lines = buffer.append(Data(bytes.suffix(from: split)))
check(lines.count == 1, "Exactly one framed line")
check(ClaudeProtocol.parse(lines[0]).contains(.textDelta("Hello 🌿")), "Unicode delta parsed")

let input = try ClaudeProtocol.inputLine("Hello \"world\"\nsecond line")
let inputObject = try JSONSerialization.jsonObject(with: Data(input.dropLast())) as! [String: Any]
check(inputObject["type"] as? String == "user", "User message encoded")
check(ClaudeProtocol.parse("{\"type\":\"result\",\"result\":\"Done\",\"is_error\":false}").contains(.finished(text: "Done", isError: false)), "Completion parsed")
check(ClaudeProtocol.parse("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\"}]}}").contains(.toolUse("Bash")), "Tool event parsed")
var multi = JSONLineBuffer()
let combined = Data(("{\"type\":\"result\",\"result\":\"A\"}\n{\"type\":\"result\",\"result\":\"B\"}\n").utf8)
check(multi.append(combined).count == 2, "Two records in a single read")
check(ClaudeProtocol.parse("{\"type\":\"result\",\"is_error\":true}").contains(.finished(text: nil, isError: true)), "Error completion without a result field")
check(ClaudeProtocol.parse("{\"type\":\"unknown_future_event\"}").isEmpty, "Unknown CLI event safely ignored")
// Records below are trimmed copies of real Claude Code 2.1.330 stream-json output.
let thinkingLine = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"I'm weighing","estimated_tokens":null}},"parent_tool_use_id":null}"#
check(ClaudeProtocol.parse(thinkingLine) == [.thinkingDelta("I'm weighing")], "Thinking delta parsed")
let emptyThinking = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":""}}}"#
check(ClaudeProtocol.parse(emptyThinking).isEmpty, "Omitted thinking ignored")
let blockStart = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}}"#
check(ClaudeProtocol.parse(blockStart) == [.thinkingBlockStart], "Thinking block start parsed")
let subagent = #"{"type":"stream_event","parent_tool_use_id":"toolu_1","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"sub"}}}"#
check(ClaudeProtocol.parse(subagent).isEmpty, "Subagent text kept out of the chat")
let hook = #"{"type":"system","subtype":"informational","content":"UserPromptExpansion operation blocked by hook:\nblocked by policy","level":"warning"}"#
check(ClaudeProtocol.parse(hook) == [.systemNotice("blocked by policy")], "Hook reply shown as notice")
check(ClaudeProtocol.parse(#"{"type":"system","subtype":"status","status":"requesting"}"#).isEmpty, "Status records ignored")
let control = #"{"type":"control_request","request_id":"a95c","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"touch probe.txt","description":"Create it"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch probe.txt"}],"behavior":"allow","destination":"localSettings"}]}}"#
guard case .permissionRequest(let prompt)? = ClaudeProtocol.parse(control).first else { fatalError("Test failed: permission request") }
check(prompt.id == "a95c" && prompt.tool == "Bash" && prompt.summary == "touch probe.txt", "Permission request parsed")
let allowObject = try JSONSerialization.jsonObject(with: Data(ClaudeProtocol.permissionLine(prompt, allow: true, always: true).dropLast())) as! [String: Any]
let allowResponse = (allowObject["response"] as! [String: Any])
let allowDecision = allowResponse["response"] as! [String: Any]
check(allowObject["type"] as? String == "control_response" && allowResponse["request_id"] as? String == "a95c", "Permission reply addressed")
check(allowDecision["behavior"] as? String == "allow" && (allowDecision["updatedInput"] as? [String: Any])?["command"] as? String == "touch probe.txt", "Allow echoes the input")
check((allowDecision["updatedPermissions"] as? [Any])?.count == 1, "Always allow sends the suggested rule")
let denyObject = try JSONSerialization.jsonObject(with: Data(ClaudeProtocol.permissionLine(prompt, allow: false).dropLast())) as! [String: Any]
check(((denyObject["response"] as! [String: Any])["response"] as! [String: Any])["behavior"] as? String == "deny", "Deny encoded")
check(ClaudeProtocol.parse(#"{"type":"control_request","request_id":"x","request":{"subtype":"hook_callback"}}"#) == [.unsupportedControl(id: "x", subtype: "hook_callback")], "Unknown control request answered")
let initLine = #"{"type":"system","subtype":"init","permissionMode":"plan","slash_commands":["clear","compact","doctor","cost"],"terminal_slash_commands":["doctor"]}"#
check(ClaudeProtocol.parse(initLine).contains(.sessionInfo(mode: "plan", commands: ["clear", "compact", "cost"])), "Init gives mode and headless commands")
check(ClaudeProtocol.parse(#"{"type":"system","subtype":"status","status":null,"permissionMode":"auto"}"#) == [.permissionMode("auto")], "Mode change parsed")
check(ClaudeProtocol.parse(#"{"type":"control_response","response":{"subtype":"success","request_id":"m1","response":{"mode":"plan"}}}"#) == [.controlResult(id: "m1", error: nil)], "Mode change accepted")
check(ClaudeProtocol.parse(#"{"type":"control_response","response":{"subtype":"error","request_id":"m2","error":"nope"}}"#) == [.controlResult(id: "m2", error: "nope")], "Mode change refused")
let modeObject = try! JSONSerialization.jsonObject(with: ClaudeProtocol.setModeLine(id: "m3", mode: "plan")) as! [String: Any]
check(((modeObject["request"] as! [String: Any])["mode"] as? String) == "plan" && modeObject["request_id"] as? String == "m3", "Mode request encoded")
check(PermissionMode.default.next(skipping: []) == .acceptEdits && PermissionMode.bypassPermissions.next(skipping: []) == .default, "Mode cycle wraps")
check(PermissionMode.auto.next(skipping: [.bypassPermissions]) == .default, "Unavailable modes skipped")
print("All protocol smoke tests passed")
