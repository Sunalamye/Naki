//
//  MCPTool.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  MCP 工具 Protocol 定義
//

import Foundation

// MARK: - MCP Tool Protocol

/// MCP 工具協議
/// 每個工具實現此協議，提供名稱、描述、參數 Schema 和執行邏輯
protocol MCPTool {
    /// 工具名稱（唯一標識符）
    static var name: String { get }

    /// 工具描述（給 AI 看的說明）
    static var description: String { get }

    /// 輸入參數 Schema
    static var inputSchema: MCPInputSchema { get }

    /// 使用上下文初始化工具
    init(context: MCPContext)

    /// 執行工具
    /// - Parameter arguments: 調用參數
    /// - Returns: 執行結果（會被序列化為 JSON）
    func execute(arguments: [String: Any]) async throws -> Any
}

// MARK: - Input Schema

/// MCP 輸入參數 Schema
struct MCPInputSchema {
    let properties: [String: MCPPropertySchema]
    let required: [String]

    /// 無參數的 Schema
    static let empty = MCPInputSchema(properties: [:], required: [])

    /// 轉換為 JSON 格式
    func toJSON() -> [String: Any] {
        var propsDict: [String: Any] = [:]
        for (key, prop) in properties {
            propsDict[key] = prop.toJSON()
        }
        return [
            "type": "object",
            "properties": propsDict,
            "required": required
        ]
    }
}

/// MCP 參數屬性 Schema
struct MCPPropertySchema {
    let type: String
    let description: String?

    init(type: String, description: String? = nil) {
        self.type = type
        self.description = description
    }

    /// 整數類型
    static func integer(_ description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "integer", description: description)
    }

    /// 數字類型
    static func number(_ description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "number", description: description)
    }

    /// 字串類型
    static func string(_ description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "string", description: description)
    }

    /// 布林類型
    static func boolean(_ description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "boolean", description: description)
    }

    /// 物件類型
    static func object(_ description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "object", description: description)
    }

    /// 轉換為 JSON 格式
    func toJSON() -> [String: Any] {
        var dict: [String: Any] = ["type": type]
        if let desc = description {
            dict["description"] = desc
        }
        return dict
    }
}

// MARK: - Tool Result

/// 工具執行結果
enum MCPToolResult {
    case success(Any)
    case error(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var value: Any? {
        if case .success(let v) = self { return v }
        return nil
    }

    var errorMessage: String? {
        if case .error(let msg) = self { return msg }
        return nil
    }
}

// MARK: - Tool Errors

/// MCP 工具錯誤
enum MCPToolError: LocalizedError {
    case missingParameter(String)
    case invalidParameter(String, expected: String)
    case executionFailed(String)
    case notAvailable(String)

    var errorDescription: String? {
        switch self {
        case .missingParameter(let name):
            return "Missing required parameter: \(name)"
        case .invalidParameter(let name, let expected):
            return "Invalid parameter '\(name)': expected \(expected)"
        case .executionFailed(let reason):
            return "Execution failed: \(reason)"
        case .notAvailable(let resource):
            return "\(resource) not available"
        }
    }
}
