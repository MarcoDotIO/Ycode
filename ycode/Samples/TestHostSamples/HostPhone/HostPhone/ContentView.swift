import SwiftUI

/// What the hosted tests check: code that lives in the app.
enum PhoneModel {
    static let title = "HostPhone"
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
            Text(PhoneModel.title)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
