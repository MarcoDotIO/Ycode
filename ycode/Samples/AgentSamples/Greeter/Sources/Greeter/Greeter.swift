/// Makes greetings.
public struct Greeter {
    /// The word a greeting starts with.
    public var salutation: String

    public init(salutation: String = "Hello") {
        self.salutation = salutation
    }

    /// A greeting for `name`, ending with an exclamation mark.
    public func greeting(for name: String) -> String {
        "\(salutation), \(name)!"
    }
}
