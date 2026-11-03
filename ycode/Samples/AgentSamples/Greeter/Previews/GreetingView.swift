// Not part of a target: the previews tools read it (it needs SwiftUI).
import SwiftUI

struct GreetingView: View {
    var name: String
    var body: some View {
        Text("Hello, \(name)!")
            .padding()
    }
}

#Preview("Greeting") {
    GreetingView(name: "Ada")
}

#Preview("Dark") {
    GreetingView(name: "Bo")
}
