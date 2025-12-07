//
//  MCPKitTests.swift
//  MCPKit
//
//  MCPKit 單元測試
//

import XCTest
@testable import MCPKit

// MARK: - Mock Context

@MainActor
final class MockMCPContext: MCPContext {
    var serverPort: UInt16 = 8765
    var logs: [String] = []

    func executeJavaScript(_ script: String) async throws -> Any? {
        return "mock result for: \(script)"
    }

    func getLogs() -> [String] {
        return logs
    }

    func clearLogs() {
        logs.removeAll()
    }

    func log(_ message: String) {
        logs.append(message)
        print("[MockContext] \(message)")
    }
}

// MARK: - Mock Tool

struct MockTool: MCPTool {
    static let name = "mock_tool"
    static let description = "A mock tool for testing"
    static let inputSchema = MCPInputSchema(
        properties: [
            "message": .string("Test message")
        ],
        required: ["message"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let message = arguments["message"] as? String else {
            throw MCPToolError.missingParameter("message")
        }
        return ["echo": message]
    }
}

// MARK: - Tests

@MainActor
final class MCPKitTests: XCTestCase {

    var registry: MCPToolRegistry!
    var context: MockMCPContext!

    override func setUp() async throws {
        registry = MCPToolRegistry()
        context = MockMCPContext()
    }

    override func tearDown() async throws {
        registry.reset()
    }

    // MARK: - Registry Tests

    func testRegisterTool() async {
        registry.register(MockTool.self)
        XCTAssertTrue(registry.hasToolNamed("mock_tool"))
        XCTAssertEqual(registry.count, 1)
    }

    func testToolExecution() async {
        registry.register(MockTool.self)

        let result = await registry.execute(
            toolNamed: "mock_tool",
            arguments: ["message": "hello"],
            context: context
        )

        XCTAssertTrue(result.isSuccess)
        if case .success(let value) = result,
           let dict = value as? [String: Any],
           let echo = dict["echo"] as? String {
            XCTAssertEqual(echo, "hello")
        } else {
            XCTFail("Expected echo response")
        }
    }

    func testUnknownToolError() async {
        let result = await registry.execute(
            toolNamed: "unknown_tool",
            arguments: [:],
            context: context
        )

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.errorMessage, "Unknown tool: unknown_tool")
    }

    func testMissingParameterError() async {
        registry.register(MockTool.self)

        let result = await registry.execute(
            toolNamed: "mock_tool",
            arguments: [:],
            context: context
        )

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("Missing required parameter") ?? false)
    }

    func testToolDefinitions() async {
        registry.register(MockTool.self)

        let definitions = registry.allToolDefinitions()
        XCTAssertEqual(definitions.count, 1)

        let firstDef = definitions[0]
        XCTAssertEqual(firstDef["name"] as? String, "mock_tool")
        XCTAssertEqual(firstDef["description"] as? String, "A mock tool for testing")
    }

    // MARK: - Built-in Tools Tests

    func testBuiltInToolsRegistration() async {
        registry.registerBuiltInTools()
        XCTAssertTrue(registry.hasToolNamed("get_status"))
        XCTAssertTrue(registry.hasToolNamed("get_logs"))
        XCTAssertTrue(registry.hasToolNamed("clear_logs"))
        XCTAssertTrue(registry.hasToolNamed("execute_js"))
    }

    func testGetStatusTool() async {
        registry.registerBuiltInTools()

        let result = await registry.execute(
            toolNamed: "get_status",
            arguments: [:],
            context: context
        )

        XCTAssertTrue(result.isSuccess)
        if case .success(let value) = result,
           let dict = value as? [String: Any] {
            XCTAssertEqual(dict["status"] as? String, "running")
            XCTAssertEqual(dict["port"] as? UInt16, 8765)
        } else {
            XCTFail("Expected status response")
        }
    }

    // MARK: - Schema Tests

    func testInputSchemaToJSON() async {
        let schema = MCPInputSchema(
            properties: [
                "name": .string("User name"),
                "age": .integer("User age"),
                "active": .boolean("Is active")
            ],
            required: ["name"]
        )

        let json = schema.toJSON()
        XCTAssertEqual(json["type"] as? String, "object")
        XCTAssertEqual(json["required"] as? [String], ["name"])

        if let properties = json["properties"] as? [String: [String: Any]] {
            XCTAssertEqual(properties["name"]?["type"] as? String, "string")
            XCTAssertEqual(properties["age"]?["type"] as? String, "integer")
            XCTAssertEqual(properties["active"]?["type"] as? String, "boolean")
        } else {
            XCTFail("Expected properties in schema")
        }
    }
}
