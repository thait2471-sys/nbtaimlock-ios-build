import SwiftUI
import UIKit
import Combine

/// `.animation(_:value:)` only exists on iOS 15+, while this app targets iOS 14.
/// Keep one call site so the availability branch lives in a single place.
private extension View {
    @ViewBuilder
    func nbtSpringAnimation<V: Equatable>(_ value: V) -> some View {
        if #available(iOS 15.0, *) {
            self.animation(.spring(response: 0.4, dampingFraction: 0.8), value: value)
        } else {
            self.animation(.spring(response: 0.4, dampingFraction: 0.8))
        }
    }
}

/// `SwitchToggleStyle(tint:)` is iOS 15+; on iOS 14 the switch follows
/// `accentColor`. One wrapper keeps both paths compiling on a 14.0 target.
///
/// Internal, not private: `AimlockDashboardView.swift` uses it on its module
/// toggles, and a `private extension` is only visible inside the file that
/// declares it.
extension View {
    @ViewBuilder
    func nbtTint(_ color: Color) -> some View {
        if #available(iOS 15.0, *) {
            self.tint(color)
        } else {
            self.accentColor(color)
        }
    }
}

/// An SF Symbol whose name is newer than the deployment target renders as a
/// blank gap, not a compile error — the build stays green and the icon silently
/// disappears on iOS 14. Resolve the preferred name at runtime and fall back to
/// one that has shipped since iOS 13.
func nbtSymbol(_ preferred: String, fallback: String) -> String {
    UIImage(systemName: preferred) != nil ? preferred : fallback
}

public struct NativeAppView: View {
    @ObservedObject var core = NABATICore.shared

    public init() {}

    public var body: some View {
        ZStack {
            // Dark Cyberpunk Gradient Background
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 6/255, green: 9/255, blue: 19/255),
                    Color(red: 10/255, green: 15/255, blue: 30/255),
                    Color(red: 4/255, green: 6/255, blue: 14/255)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            switch core.appState {
            case .locked, .verifying:
                KeyVerificationView()
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            case .authorized(let session):
                AimlockDashboardView(session: session)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }

            ServiceGateOverlay()
        }
        .nbtSpringAnimation(core.isAuthorized)
        .onAppear {
            // Refresh the server state whenever the UI comes up, without
            // re-running the whole session bootstrap.
            if case .checking = core.gateMode {
                core.checkServiceGate(isUserRetry: false)
            }
        }
    }
}

// MARK: - Screen 1: Key Verification Screen
struct KeyVerificationView: View {
    @ObservedObject var core = NABATICore.shared
    @ObservedObject var store = NABATIFeatureStore.shared
    @State private var inputKey: String = ""

    /// Web parity: each key-entry attempt gets a 45-second UX budget. This is a
    /// presentation guard only. `/api/verify` and `/api/lockout-status` stay the
    /// final authorities; the timer can never grant or bypass anything.
    private static let keyEntryTimeLimit: TimeInterval = 45
    @State private var keyEntryDeadline: Date? = nil
    @State private var keyEntryTimedOut = false

    /// The server's brute-force state for this device. `nil` means "not known
    /// yet" or "could not ask" — never "unlocked".
    @State private var lockout: NABATILockoutState? = nil
    @State private var lockoutDeadline: Date? = nil
    /// Updated once a second while a lock is counting down, so the text
    /// re-renders. A quiet tick that mutates nothing would leave the countdown
    /// frozen on screen.
    @State private var now: Date = Date()
    /// One second tick only drives the countdown text; the deadline itself comes
    /// from the server, so a backgrounded app cannot drift the unlock time.
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// Which legal document the reader sheet is showing, if any.
    @State private var legalSelection: NABATILegalSelection? = nil
    /// Web parity: the customer can re-confirm which phone model they use.
    @State private var showModelPicker = false
    /// Bumped on a confirmed change so the label re-renders.
    @State private var modelRevision = 0

    private var accent: Color { Color(red: 0/255, green: 243/255, blue: 255/255) }
    private var accentGreen: Color { Color(red: 0/255, green: 255/255, blue: 157/255) }
    private var accentAmber: Color { Color(red: 255/255, green: 184/255, blue: 0/255) }

    private var lockoutRemainingText: String {
        guard let deadline = lockoutDeadline else { return lockout?.remainingText ?? "00:00" }
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var keyEntryRemainingSeconds: Int {
        guard let deadline = keyEntryDeadline else { return 0 }
        return max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    private var keyEntryRemainingText: String {
        let seconds = keyEntryRemainingSeconds
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var isInputBlocked: Bool {
        keyEntryTimedOut || (lockout?.isLockedOut ?? false) || core.isVerifying || core.isGateBlocking
    }

    private var unlockButtonLabel: String {
        if keyEntryTimedOut { return "HẾT THỜI GIAN (45S)" }
        return core.isVerifying ? "ĐANG XÁC THỰC..." : "MỞ KHÓA NGAY (UNLOCK)"
    }

    private func beginKeyEntryWindow() {
        now = Date()
        keyEntryTimedOut = false
        keyEntryDeadline = now.addingTimeInterval(Self.keyEntryTimeLimit)
    }

    private func submitKey() {
        guard !isInputBlocked else { return }
        let cleaned = inputKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        core.unlockWithKey(cleaned)
    }

    private func refreshLockoutStatus() {
        NABATILockoutClient.fetch { state in
            lockout = state
            if let state = state, state.isLockedOut {
                // At least one second, so a zero-second answer still schedules
                // one re-check instead of freezing at "00:00".
                lockoutDeadline = Date().addingTimeInterval(Double(max(1, state.remainingSeconds)))
            } else {
                lockoutDeadline = nil
            }
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                // Header Logo & Branding
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(RadialGradient(
                                colors: [accent.opacity(0.35), Color.clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: 50
                            ))
                            .frame(width: 100, height: 100)

                        Image(systemName: "cross.fill")
                            .font(.system(size: 40, weight: .bold))
                            .foregroundColor(accent)
                            .shadow(color: accent.opacity(0.8), radius: 10)
                    }

                    Text("NABATI AIMLOCK ACCESS")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .tracking(1.5)

                    Text("VIP AIMLOCK BOOSTER • NATIVE iOS v\(NABATIAppVersion.version)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.12))
                        .cornerRadius(20)
                }
                .padding(.top, 40)

                // Same admin-authored notice bar as the web lock screen. Config
                // and announcements both come from the server, so an edit in
                // Admin reaches this screen without a new build.
                if store.shouldShowMarquee {
                    MarqueeBanner(text: store.marqueeText)
                }

                // Device Identity Card
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: nbtSymbol("iphone.gen3", fallback: "iphone"))
                            .foregroundColor(accent)
                        Text("THIẾT BỊ NHẬN DIỆN")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Text("ĐÃ KHÓA HWID")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(accentGreen)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(accentGreen.opacity(0.15))
                            .cornerRadius(10)
                    }

                    Divider().background(Color.white.opacity(0.1))

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NABATIDevice.shared.displayModelName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text("iOS \(NABATIDevice.shared.systemVersion) • \(NABATIDevice.shared.machineId)")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                    }

                    Text("HWID: \(NABATIDevice.shared.hardwareId)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.8))
                        .lineLimit(1)

                    Button(action: { showModelPicker = true }) {
                        HStack(spacing: 5) {
                            Image(systemName: "iphone")
                                .font(.system(size: 10, weight: .bold))
                            Text("ĐỔI DÒNG MÁY")
                                .font(.system(size: 10.5, weight: .bold))
                        }
                        .foregroundColor(accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(accent.opacity(0.12))
                        .cornerRadius(8)
                    }
                }
                .padding(16)
                .background(Color(red: 16/255, green: 22/255, blue: 40/255).opacity(0.75))
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
                .padding(.horizontal, 20)
                // Attached to the device card, not the screen root: iOS 14 only
                // presents one `.sheet` reliably per view, and the root already
                // owns the legal-document sheet.
                .sheet(isPresented: $showModelPicker) {
                    PhoneModelPickerView(isPresented: $showModelPicker) { _ in
                        modelRevision += 1
                    }
                }

                // Server state chip — never claims ONLINE unless the server said so.
                ServerStateChip()

                // License Key Input Card
                VStack(spacing: 14) {
                    HStack {
                        Image(systemName: "key.fill")
                            .foregroundColor(accent)
                        TextField("Nhập mã kích hoạt key...", text: $inputKey, onCommit: submitKey)
                            .font(.system(size: 15))
                            .foregroundColor(.white)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .disabled(isInputBlocked)

                        if !inputKey.isEmpty {
                            Button(action: { inputKey = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.gray)
                            }
                            .disabled(isInputBlocked)
                        }

                        Button(action: {
                            guard !isInputBlocked,
                                  let paste = UIPasteboard.general.string else { return }
                            let cleaned = paste.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !cleaned.isEmpty else { return }
                            inputKey = cleaned
                            // Web parity: a non-empty paste goes straight to the
                            // same server verification as pressing UNLOCK. The
                            // server still decides the outcome. Pass the cleaned
                            // string rather than re-reading the @State wrapper.
                            core.unlockWithKey(cleaned)
                        }) {
                            Text("DÁN KEY")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(accent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(accent.opacity(0.15))
                                .cornerRadius(8)
                        }
                    }
                    .padding(14)
                    .background(Color(red: 12/255, green: 18/255, blue: 34/255))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.4), lineWidth: 1))

                    if let status = core.statusMessage {
                        HStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: accent))
                            Text(status)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(accent)
                            Spacer()
                        }
                    }

                    // Error Message Display
                    if let err = core.errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(err)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                    }

                    // Local key-entry budget. It never replaces the server
                    // lockout; it only keeps an abandoned form from staying live.
                    if keyEntryTimedOut {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("⛔ HẾT THỜI GIAN KÍCH HOẠT (45s)")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundColor(accentAmber)
                            Text("Màn hình nhập key đã tự động khóa để bảo mật. Vui lòng tắt hẳn ứng dụng và mở lại để tiếp tục.")
                                .font(.system(size: 11.5))
                                .foregroundColor(.gray)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(accentAmber.opacity(0.1))
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accentAmber.opacity(0.3), lineWidth: 1))
                    } else if keyEntryDeadline != nil {
                        HStack(spacing: 8) {
                            Text("THỜI GIAN KÍCH HOẠT")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(Color.white.opacity(0.55))
                            Spacer()
                            Text(keyEntryRemainingText)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(keyEntryRemainingSeconds <= 10 ? accentAmber : accent)
                        }
                        .padding(.horizontal, 2)
                    }

                    // Brute-force state straight from `/api/lockout-status`.
                    if let state = lockout {
                        if state.isLockedOut {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("🔒 THIẾT BỊ TẠM KHÓA")
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundColor(accentAmber)
                                Text(lockoutRemainingText)
                                    .font(.system(size: 26, weight: .black, design: .monospaced))
                                    .foregroundColor(accentAmber)
                                Text("Nhập sai quá nhiều lần. Vui lòng thử lại sau.")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.gray)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(accentAmber.opacity(0.1))
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(accentAmber.opacity(0.3), lineWidth: 1))
                        } else if state.failedCount > 0 {
                            Text("⚠️ Còn \(state.attemptsLeft) lần thử trước khi thiết bị bị tạm khóa.")
                                .font(.system(size: 11.5))
                                .foregroundColor(Color(red: 255/255, green: 184/255, blue: 0/255))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // Unlock Button
                    Button(action: submitKey) {
                        HStack(spacing: 10) {
                            if core.isVerifying {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .black))
                            } else {
                                Image(systemName: "lock.open.fill")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            Text(unlockButtonLabel)
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(LinearGradient(
                            colors: [accent, accentGreen],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .cornerRadius(14)
                        .shadow(color: accent.opacity(0.4), radius: 8, y: 4)
                    }
                    .disabled(inputKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInputBlocked)
                    .opacity(inputKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInputBlocked ? 0.6 : 1.0)
                }
                .padding(20)
                .background(Color(red: 16/255, green: 22/255, blue: 40/255).opacity(0.75))
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
                .padding(.horizontal, 20)

                // Support & Contact Button
                Button(action: {
                    core.openZaloSupport()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.circle")
                        Text("Chưa có key? Liên hệ Zalo: 0356075419")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(accent.opacity(0.9))
                }
                .padding(.top, 10)

                // Footer links — the same four documents the web client opens
                // from its footer. The text lives in Admin (`/api/legal`), so
                // editing a policy there updates the app without a new build.
                VStack(spacing: 12) {
                    HStack(spacing: 20) {
                        legalLink("Giới thiệu", type: "about")
                        legalLink("Hướng dẫn", type: "guide")
                    }
                    HStack(spacing: 20) {
                        legalLink("Điều khoản sử dụng", type: "terms")
                        legalLink("Chính sách bảo mật", type: "privacy")
                    }
                }
                .padding(.top, 4)

                Spacer(minLength: 40)
            }
        }
        .onAppear {
            beginKeyEntryWindow()
            refreshLockoutStatus()
            store.loadConfigIfNeeded()
        }
        .onReceive(ticker) { tick in
            now = tick
            // Wall-clock deadline, so time spent in the background counts even
            // though iOS suspends the ticker. Timers are presentation only.
            if !keyEntryTimedOut,
               let deadline = keyEntryDeadline,
               deadline.timeIntervalSince(tick) <= 0 {
                keyEntryTimedOut = true
                keyEntryDeadline = nil
                inputKey = ""
            }
            if let deadline = lockoutDeadline, deadline.timeIntervalSince(tick) <= 0 {
                // The lock has elapsed; ask again rather than trusting the
                // clock. If the server still refuses, the new deadline applies.
                lockoutDeadline = nil
                refreshLockoutStatus()
            }
        }
        .onChange(of: core.errorMessage) { message in
            if message != nil { refreshLockoutStatus() }
        }
        .sheet(item: $legalSelection) { selection in
            LegalDocumentView(type: selection.id)
        }
    }

    private func legalLink(_ title: String, type: String) -> some View {
        Button(action: { legalSelection = NABATILegalSelection(id: type) }) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.white.opacity(0.5))
                .underline()
        }
    }
}

// MARK: - Server state chip
struct ServerStateChip: View {
    @ObservedObject var core = NABATICore.shared

    private var label: String {
        switch core.gateMode {
        case .checking: return "ĐANG KIỂM TRA MÁY CHỦ"
        case .connectionError: return "KHÔNG KẾT NỐI ĐƯỢC MÁY CHỦ"
        case .maintenance: return core.serviceStatus?.state.modeLabel ?? "ĐANG BẢO TRÌ"
        case .update: return "CÓ BẢN CẬP NHẬT MỚI"
        case .hidden:
            if let update = core.serviceStatus?.update, update.version.count > 0 {
                return "ONLINE • v\(update.version) SẴN SÀNG"
            }
            return "ONLINE"
        }
    }

    private var color: Color {
        switch core.gateMode {
        case .connectionError: return Color(red: 248/255, green: 113/255, blue: 113/255)
        case .maintenance: return Color(red: 255/255, green: 184/255, blue: 0/255)
        case .update: return Color(red: 52/255, green: 211/255, blue: 153/255)
        case .checking: return Color(red: 139/255, green: 151/255, blue: 179/255)
        case .hidden: return Color(red: 52/255, green: 211/255, blue: 153/255)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundColor(color)
            Spacer()
            Button(action: { core.checkServiceGate(isUserRetry: true) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(color.opacity(0.9))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(color.opacity(0.08))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 20)
    }
}

// MARK: - Service gate overlay (server authority)
struct ServiceGateOverlay: View {
    @ObservedObject var core = NABATICore.shared

    private var isVisible: Bool {
        switch core.gateMode {
        case .hidden, .checking: return false
        default: return true
        }
    }

    private var accent: Color {
        switch core.gateMode {
        case .connectionError: return Color(red: 248/255, green: 113/255, blue: 113/255)
        case .maintenance: return Color(red: 255/255, green: 184/255, blue: 0/255)
        case .update: return Color(red: 52/255, green: 211/255, blue: 153/255)
        default: return Color(red: 56/255, green: 189/255, blue: 248/255)
        }
    }

    private var icon: String {
        switch core.gateMode {
        case .connectionError: return nbtSymbol("wifi.exclamationmark", fallback: "wifi.slash")
        case .maintenance: return nbtSymbol("wrench.and.screwdriver.fill", fallback: "wrench.fill")
        case .update: return "arrow.up.circle.fill"
        default: return "clock"
        }
    }

    private var kicker: String {
        switch core.gateMode {
        case .connectionError: return "KHÔNG KẾT NỐI ĐƯỢC MÁY CHỦ"
        case .maintenance: return core.serviceStatus?.state.modeLabel ?? "TRẠNG THÁI HỆ THỐNG"
        case .update: return "ĐÃ CÓ PHIÊN BẢN MỚI"
        default: return "TRẠNG THÁI HỆ THỐNG"
        }
    }

    private var title: String {
        switch core.gateMode {
        case .connectionError: return "Không thể kết nối máy chủ"
        case .maintenance:
            let t = core.serviceStatus?.state.title ?? ""
            return t.isEmpty ? "NABATI AIMLOCK ĐANG BẢO TRÌ" : t
        case .update: return "NABATI AIMLOCK – ĐÃ CÓ PHIÊN BẢN MỚI"
        default: return "Đang kiểm tra trạng thái"
        }
    }

    private var bodyText: String {
        switch core.gateMode {
        case .connectionError:
            return "Vui lòng kiểm tra kết nối mạng rồi thử lại. Hệ thống chưa xác nhận trạng thái bảo trì."
        case .maintenance:
            let c = core.serviceStatus?.state.content ?? ""
            return c.isEmpty ? "Hệ thống hiện đang trong quá trình cập nhật và bảo trì. Vui lòng quay lại sau." : c
        case .update:
            let notes = core.serviceStatus?.update?.releaseNotes ?? ""
            return notes.isEmpty
                ? "Ứng dụng đã có phiên bản mới. Vui lòng cập nhật để tiếp tục sử dụng."
                : notes
        default:
            return "Đang lấy trạng thái hệ thống từ máy chủ..."
        }
    }

    /// Update links exist and the admin keeps the update center enabled.
    private var hasDownload: Bool {
        guard let update = core.serviceStatus?.update else { return false }
        return !update.downloadUrl.isEmpty
    }

    private var canDismiss: Bool {
        core.canDismissGate
    }

    var body: some View {
        if isVisible {
            ZStack {
                Color.black.opacity(0.86)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 13)
                                    .fill(accent.opacity(0.12))
                                    .frame(width: 46, height: 46)
                                Image(systemName: icon)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(accent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("NABATI AIMLOCK")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .tracking(1.6)
                                    .foregroundColor(Color(red: 90/255, green: 104/255, blue: 132/255))
                                Text(kicker)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(Color(red: 139/255, green: 151/255, blue: 179/255))
                            }
                            Spacer()
                        }
                        .padding(.bottom, 16)

                        Text(title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color(red: 230/255, green: 237/255, blue: 248/255))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 10)

                        Text(bodyText)
                            .font(.system(size: 13.5))
                            .foregroundColor(Color(red: 169/255, green: 182/255, blue: 206/255))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 14)

                        // Platform + timing chips
                        HStack(spacing: 8) {
                            chip("iOS", accent)
                            if let end = core.serviceStatus?.state.estimatedEndAt, end > 0 {
                                chip("Dự kiến: " + formatDate(end), Color(red: 255/255, green: 184/255, blue: 0/255))
                            }
                            if let update = core.serviceStatus?.update, update.version.count > 0 {
                                chip("Mới: \(update.version)\(update.buildNumber.isEmpty ? "" : " (\(update.buildNumber))")",
                                     Color(red: 52/255, green: 211/255, blue: 153/255))
                            }
                            if core.serviceStatus?.update?.forceUpdate == true {
                                chip("BẮT BUỘC CẬP NHẬT", Color(red: 248/255, green: 113/255, blue: 113/255))
                            }
                        }
                        .padding(.bottom, 14)

                        if let errorText = core.gateErrorText, !errorText.isEmpty {
                            Text(errorText)
                                .font(.system(size: 12.5))
                                .foregroundColor(Color(red: 248/255, green: 113/255, blue: 113/255))
                                .padding(11)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(red: 248/255, green: 113/255, blue: 113/255).opacity(0.1))
                                .cornerRadius(11)
                                .padding(.bottom, 14)
                        }

                        // Primary action
                        Button(action: primaryAction) {
                            HStack(spacing: 8) {
                                if core.gateBusy {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                }
                                Text(primaryLabel)
                                    .font(.system(size: 13.5, weight: .bold))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(accent)
                            .cornerRadius(11)
                        }
                        .disabled(core.gateBusy)
                        .opacity(core.gateBusy ? 0.65 : 1.0)

                        if canDismiss {
                            Button(action: { core.dismissGateNotice() }) {
                                Text("ĐỂ SAU")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundColor(Color(red: 169/255, green: 182/255, blue: 206/255))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color(red: 20/255, green: 27/255, blue: 43/255))
                                    .cornerRadius(11)
                                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(red: 42/255, green: 55/255, blue: 82/255), lineWidth: 1))
                            }
                            .padding(.top, 10)
                        }

                        Text("NABATI AIMLOCK · iOS")
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 76/255, green: 90/255, blue: 117/255))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                    }
                    .padding(26)
                    .frame(maxWidth: 430)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color(red: 14/255, green: 20/255, blue: 36/255))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color(red: 36/255, green: 48/255, blue: 74/255), lineWidth: 1)
                    )
                    .padding(20)
                }
            }
            .transition(.opacity)
        }
    }

    private var primaryLabel: String {
        if core.gateBusy { return "ĐANG KIỂM TRA..." }
        switch core.gateMode {
        case .connectionError: return "THỬ LẠI"
        case .maintenance:
            if core.serviceStatus?.state.retryEnabled == false { return "ĐÓNG" }
            return "THỬ LẠI"
        case .update:
            return hasDownload ? "TẢI BẢN MỚI" : "THỬ LẠI"
        default:
            return "THỬ LẠI"
        }
    }

    private func primaryAction() {
        switch core.gateMode {
        case .hidden, .checking:
            core.checkServiceGate(isUserRetry: true)
        case .connectionError:
            core.checkServiceGate(isUserRetry: true)
        case .maintenance:
            if core.serviceStatus?.state.retryEnabled == false {
                // Admin disabled retry: closing is the only exit when the notice
                // is informational. When auth is still blocked there is nothing
                // to close, so re-check instead of pretending to dismiss.
                if core.canDismissGate {
                    core.dismissGateNotice()
                } else {
                    core.checkServiceGate(isUserRetry: true)
                }
            } else {
                core.checkServiceGate(isUserRetry: true)
            }
        case .update:
            if hasDownload {
                core.openDownloadUrl()
            } else {
                core.checkServiceGate(isUserRetry: true)
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.27), lineWidth: 1))
    }

    private func formatDate(_ millis: Double) -> String {
        let value = millis > 100_000_000_000 ? millis : millis * 1000
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: value / 1000))
    }
}

// MARK: - Reusable UI Components
struct SensitivitySliderRow: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                Spacer()
                Text("\(Int(value))%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0/255, green: 243/255, blue: 255/255))
            }
            Slider(value: $value, in: 50...100, step: 1)
                .accentColor(Color(red: 0/255, green: 243/255, blue: 255/255))
        }
    }
}


// MARK: - Phone model picker (web parity: "CHỌN DÒNG MÁY")

/// Mirrors the web client's phone-confirmation screen: detected model shown
/// first, a filtered suggestion list, and an explicit confirm. Only the display
/// label changes — the server still binds the KEY to `NABATIDevice.hardwareId`.
struct PhoneModelPickerView: View {
    @Binding var isPresented: Bool
    var onConfirmed: (String) -> Void

    @State private var query: String = NABATIDevice.shared.hasConfirmedModelName
        ? NABATIDevice.shared.displayModelName
        : NABATIDevice.shared.modelName
    @State private var errorText: String? = nil

    private var accent: Color { Color(red: 0/255, green: 243/255, blue: 255/255) }
    private var accentGreen: Color { Color(red: 0/255, green: 255/255, blue: 157/255) }

    private var suggestions: [String] {
        NABATIPhoneCatalog.suggestions(for: query)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 6/255, green: 9/255, blue: 19/255),
                    Color(red: 10/255, green: 15/255, blue: 30/255)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("CHỌN DÒNG MÁY")
                                .font(.system(size: 18, weight: .black))
                                .foregroundColor(.white)
                            Text("Tự động nhận diện iOS: \(NABATIDevice.shared.modelName) • iOS \(NABATIDevice.shared.systemVersion)")
                                .font(.system(size: 11))
                                .foregroundColor(accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(action: { isPresented = false }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(Color.white.opacity(0.35))
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("TÊN DÒNG MÁY")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.2)
                            .foregroundColor(Color(red: 90/255, green: 104/255, blue: 132/255))

                        TextField("Ví dụ: iPhone 15 Pro Max", text: $query)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .autocapitalization(.words)
                            .disableAutocorrection(true)
                            .padding(12)
                            .background(Color(red: 12/255, green: 18/255, blue: 34/255))
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.4), lineWidth: 1))

                        if let errorText = errorText {
                            Text(errorText)
                                .font(.system(size: 11.5))
                                .foregroundColor(Color(red: 248/255, green: 113/255, blue: 113/255))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button(action: confirm) {
                            HStack(spacing: 8) {
                                Image(systemName: nbtSymbol("checkmark.seal.fill", fallback: "checkmark.circle.fill"))
                                Text("XÁC NHẬN DÒNG MÁY")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(LinearGradient(
                                colors: [accent, accentGreen],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .cornerRadius(11)
                        }
                    }
                    .padding(16)
                    .background(Color(red: 16/255, green: 22/255, blue: 40/255).opacity(0.85))
                    .cornerRadius(16)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))

                    VStack(spacing: 0) {
                        ForEach(suggestions, id: \.self) { name in
                            Button(action: {
                                query = name
                                errorText = nil
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "iphone")
                                        .font(.system(size: 11))
                                        .foregroundColor(accent.opacity(0.8))
                                    Text(name)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundColor(.white)
                                    Spacer()
                                    if name == NABATIDevice.shared.displayModelName {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(accentGreen)
                                    }
                                }
                                .padding(.horizontal, 13)
                                .padding(.vertical, 11)
                            }
                            if name != suggestions.last {
                                Divider().background(Color.white.opacity(0.06))
                            }
                        }
                    }
                    .background(Color(red: 16/255, green: 22/255, blue: 40/255).opacity(0.7))
                    .cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))

                    Text("Tên máy chỉ dùng để hiển thị trong quản trị và gợi ý độ nhạy. KEY vẫn được khóa theo mã phần cứng của thiết bị.")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(red: 139/255, green: 151/255, blue: 179/255))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
    }

    private func confirm() {
        let result = NABATIPhoneCatalog.normalize(query)
        guard result.valid else {
            errorText = result.message
            return
        }
        guard let canonical = NABATIDevice.shared.confirmModelName(result.canonicalName) else {
            errorText = "Tên máy không hợp lệ."
            return
        }
        errorText = nil
        onConfirmed(canonical)
        isPresented = false
    }
}
