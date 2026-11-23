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
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "fa_IR"))
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
                DashboardView()
                    .tabItem { Label("خانه", systemImage: "antenna.radiowaves.left.and.right") }
                    .tag(AppTab.home)
                ThreadsView()
                    .tabItem { Label("پیام‌ها", systemImage: "message.fill") }
                    .badge(model.threads.reduce(0) { $0 + $1.unread })
                    .tag(AppTab.messages)
                PhoneView()
                    .tabItem { Label("تلفن", systemImage: "phone.fill") }
                    .tag(AppTab.phone)
                ContactsView()
                    .tabItem { Label("مخاطبین", systemImage: "person.2.fill") }
                    .tag(AppTab.contacts)
                SettingsView()
                    .tabItem { Label("تنظیمات", systemImage: "gearshape.fill") }
                    .tag(AppTab.settings)
            }
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
                Text(model.call.state == "ringing" ? "تماس ورودی: \(Phone.iso(model.call.display))" : "در تماس: \(Phone.iso(model.call.display))")
                    .lineLimit(1)
                Spacer()
                Text("بازگشت").font(.footnote.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Theme.good)
        }
    }
}
