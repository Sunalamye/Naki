//
//  MCPTool.swift
//  MCPKit
//
//  Model Context Protocol 工具協議定義
//  提供通用的 MCP 工具介面，可用於任何需要 MCP 支援的應用
//

import Foundation

// MARK: - MCP Tool Protocol

/// MCP 工具協議
/// 每個工具實現此協議，提供名稱、描述、參數 Schema 和執行邏輯
public protocol MCPTool {
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
public struct MCPInputSchema: Sendable {
    public let properties: [String: MCPPropertySchema]
    public let required: [String]

    public init(properties: [String: MCPPropertySchema], required: [String]) {
        self.properties = properties
        self.required = required
    }

    /// 無參數的 Schema
    public static let empty = MCPInputSchema(properties: [:], required: [])

    /// 轉換為 JSON 格式
    public func toJSON() -> [String: Any] {
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

// MARK: - Property Schema

/// MCP 參數屬性 Schema
public struct MCPPropertySchema: Sendable {
    public let type: String
    public let description: String?

    public init(type: String, description: String? = nil) {
        self.type = type
        self.description = description
    }

    /// 整數類型
    public static func integer(_ description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "integer", description: description)
    }

    /// 數字類型
    public static func number(_ description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "number", description: description)
    }

    /// 字串類型
    public static func string(_ description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "string", description: description)
    }

    /// 布林類型
    public static func boolean(_ description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "boolean", description: description)
    }

    /// 物件類型
    public static func object(_ description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "object", description: description)
    }

    /// 陣列類型
    public static func array(_ description: String? = nil) -> MCPPropertySchema {
        MCPPropertySchema(type: "array", description: description)
    }

    /// 轉換為 JSON 格式
    public func toJSON() -> [String: Any] {
        var dict: [String: Any] = ["type": type]
        if let desc = description {
            dict["description"] = desc
        }
        return dict
    }
}

// MARK: - Tool Result

/// 工具執行結果
public enum MCPToolResult {
    case success(Any)
    case error(String)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    public var value: Any? {
        if case .success(let v) = self { return v }
        return nil
    }

    public var errorMessage: String? {
        if case .error(let msg) = self { return msg }
        return nil
    }
}

// MARK: - Tool Errors

/// MCP 工具錯誤
public enum MCPToolError: LocalizedError, Sendable {
    case missingParameter(String)
    case invalidParameter(String, expected: String)
    case executionFailed(String)
    case notAvailable(String)

    public var errorDescription: String? {
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
