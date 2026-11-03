import Greeter

let name = CommandLine.arguments.dropFirst().first ?? "world"
print(Greeter().greeting(for: name))
