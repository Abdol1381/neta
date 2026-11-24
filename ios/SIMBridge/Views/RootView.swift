import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            if model.pairing == nil {
                OnboardingView()
                    .transition(.opacity)
            } else {
                MainTabView()
                    .transition(.opacity)
            }

            if let t = model.toast {
                ToastView(text: t)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { model.toast = nil }
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        if model.toast == t { withAnimation { model.toast = nil } }
                    }
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.toast)
        .animation(.easeInOut, value: model.pairing == nil)
        .fullScreenCover(isPresented: callScreenBinding) {
            CallScreen()
                .environmentObject(model)
                .environment(\.layoutDirection, .leftToRight)
                .environment(\.locale, Locale(identifier: "en_US"))
        }
    }

    private var callScreenBinding: Binding<Bool> {
        Binding(
            get: { model.pairing != nil && !model.call.isIdle && !model.callScreenMinimized },
            set: { shown in if !shown { model.callScreenMinimized = true } }
        )
    }
}

struct MainTabView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.call.isIdle && model.callScreenMinimized {
                OngoingCallBar()
            }
            TabView(selection: $model.tab) {
                ThreadsView()
                    .tabItem { Label("Messages", systemImage: "message.fill") }
                    .badge(model.threads.reduce(0) { $0 + $1.unread })
                    .tag(AppTab.messages)
                RecentsTab()
                    .tabItem { Label("Calls", systemImage: "phone.fill") }
                    .badge(model.recents.prefix(30).filter { $0.type == "missed" && $0.date > model.missedSeenAt }.count)
                    .tag(AppTab.calls)
                ContactsView()
                    .tabItem { Label("Contacts", systemImage: "person.crop.circle.fill") }
                    .tag(AppTab.contacts)
                KeypadTab()
                    .tabItem { Label("Keypad", systemImage: "circle.grid.3x3.fill") }
                    .tag(AppTab.keypad)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                    .tag(AppTab.settings)
            }
            .minimizingTabBar()
        }
    }
}

struct OngoingCallBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            model.callScreenMinimized = false
        } label: {
            HStack {
                Image(systemName: model.call.state == "ringing" ? "phone.arrow.down.left.fill" : "phone.fill")
                Text(model.call.state == "ringing" ? "Incoming call · \(model.call.display)" : model.call.display)
                    .lineLimit(1)
                Spacer()
                Text("Return to Call").font(.footnote.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(IOSColor.callGreen)
        }
    }
}
