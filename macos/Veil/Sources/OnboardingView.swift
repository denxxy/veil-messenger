import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var store: AppStore
    @State private var name = ""

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            Text("Veil")
                .font(.largeTitle.bold())
            Text("Мессенджер, устойчивый к блокировкам.\nКлючи создаются на этом Mac и никогда не покидают его; relay-серверы видят только зашифрованные конверты.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 10) {
                TextField("Ваше имя (видно только контактам)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 340)
                Button {
                    store.createIdentity(name: name)
                } label: {
                    Label("Создать личность", systemImage: "key.horizontal")
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.top, 8)

            Spacer()
            Text("Прототип v0.1 · экспериментальное ПО, не для критически важной связи")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 560, minHeight: 480)
    }
}
