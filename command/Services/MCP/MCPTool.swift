//
//  MCPTool.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  Naki 專用的 MCP 工具 Protocol
//

import Foundation
import MCPKit

// MARK: - Re-export MCPKit types

// MCPKit 提供的類型已通過 import MCPKit 可用：
// - MCPTool (protocol)
// - MCPInputSchema
// - MCPPropertySchema
// - MCPToolResult
// - MCPToolError
// - MCPContext (protocol)

// MARK: - Naki MCP Tool Protocol

/// Naki 專用的 MCP 工具協議
/// 擴展 MCPKit 的 MCPTool，使用 NakiMCPContext
protocol NakiMCPTool: MCPTool {
    /// Naki 專用上下文
    var nakiContext: NakiMCPContext { get }
}

// MARK: - Naki Tool Base

/// Naki 工具基礎類別
/// 提供 NakiMCPContext 的便利存取
class NakiToolBase {
    let context: MCPContext

    /// 獲取 Naki 專用上下文
    var nakiContext: NakiMCPContext? {
        context as? NakiMCPContext
    }

    required init(context: MCPContext) {
        self.context = context
    }
}
