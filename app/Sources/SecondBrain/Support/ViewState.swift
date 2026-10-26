import SwiftUI

/// The macOS 26+ SDK declares `@State` as a macro whose plugin (SwiftUIMacros) ships only with Xcode.
/// With Command Line Tools alone, `@State` fails to expand, so views use the property wrapper directly.
typealias ViewState<Value> = SwiftUI.State<Value>
