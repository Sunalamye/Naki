//
//  Color+Extension.swift
//  Naki
//
//  Created by Suoie on 2025/12/4.
//

import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Color {
    // 內容區域背景（table view, collection view 等）
    static var contentBackground: Color {
        #if os(iOS)
        return Color(UIColor.systemGroupedBackground)
        #elseif os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #endif
    }
    
    // 視窗/主要背景
    static var windowBackground: Color {
        #if os(iOS)
        return Color(UIColor.systemBackground)
        #elseif os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #endif
    }
    
    // 文字輸入框背景
    static var textFieldBackground: Color {
        #if os(iOS)
        return Color(UIColor.secondarySystemBackground)
        #elseif os(macOS)
        return Color(NSColor.textBackgroundColor)
        #endif
    }
}
