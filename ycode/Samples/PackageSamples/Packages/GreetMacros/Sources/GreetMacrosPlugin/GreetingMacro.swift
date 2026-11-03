import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `#greeting("name")` into a string literal.
public struct GreetingMacro: ExpressionMacro {
    public static func expansion(of node: some FreestandingMacroExpansionSyntax,
                                 in context: some MacroExpansionContext) -> ExprSyntax {
        let name = node.arguments.first?.expression.as(StringLiteralExprSyntax.self)?
            .segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined() ?? "nobody"
        return ExprSyntax(StringLiteralExprSyntax(content: "Hello, \(name)! (expanded by a macro)"))
    }
}

@main
struct GreetMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [GreetingMacro.self]
}
