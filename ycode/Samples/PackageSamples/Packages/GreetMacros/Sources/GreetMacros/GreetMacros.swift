/// `#greeting("World")` → `"Hello, World! (expanded by a macro)"`.
@freestanding(expression)
public macro greeting(_ name: String) -> String = #externalMacro(module: "GreetMacrosPlugin", type: "GreetingMacro")
