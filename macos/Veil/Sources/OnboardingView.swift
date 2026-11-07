import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var store: AppStore
    @State private var name = ""

    var body: some View {
        ZStack {
            Color.vBg.ignoresSafeArea()
            RadialGradient(colors: [Color.vAccent.opacity(0.16), .clear],
                           center: .center, startRadius: 0, endRadius: 440)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()

                VeilLogo(size: 96)
                    .shadow(color: Color.vAccent.opacity(0.45), radius: 32, y: 14)

                VStack(spacing: 8) {
                    Text("Veil")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(Color.vText)
                    Text("Ваши сообщения под защитой")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.vMuted)
                }

                HStack(spacing: 6) {
                    TextField("Ваше имя", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.vText)
                        .padding(.leading, 20)
                        .onSubmit { store.createIdentity(name: name) }
                    Button("Начать") {
                        store.createIdentity(name: name)
                    }
                    .buttonStyle(VeilPrimaryButtonStyle())
                }
                .frame(maxWidth: 360)
                .padding(7)
                .background(Color.vField)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1))
                .clipShape(Capsule())
                .padding(.top, 10)

                Spacer()
                Spacer()
            }
        }
    }
}