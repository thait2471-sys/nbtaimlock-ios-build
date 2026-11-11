import SwiftUI
import UIKit

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
private extension View {
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
    @State private var inputKey: String = ""

    private var accent: Color { Color(red: 0/255, green: 243/255, blue: 255/255) }
    private var accentGreen: Color { Color(red: 0/255, green: 255/255, blue: 157/255) }

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
                            Text(NABATIDevice.shared.modelName)
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
                }
                .padding(16)
                .background(Color(red: 16/255, green: 22/255, blue: 40/255).opacity(0.75))
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
                .padding(.horizontal, 20)

                // Server state chip — never claims ONLINE unless the server said so.
                ServerStateChip()

                // License Key Input Card
                VStack(spacing: 14) {
                    HStack {
                        Image(systemName: "key.fill")
                            .foregroundColor(accent)
                        TextField("Nhập mã kích hoạt key...", text: $inputKey)
                            .font(.system(size: 15))
                            .foregroundColor(.white)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        if !inputKey.isEmpty {
                            Button(action: { inputKey = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.gray)
                            }
                        }

                        Button(action: {
                            if let paste = UIPasteboard.general.string {
                                inputKey = paste.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
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
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                    }

                    // Unlock Button
                    Button(action: {
                        core.unlockWithKey(inputKey)
                    }) {
                        HStack(spacing: 10) {
                            if core.isVerifying {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .black))
                            } else {
                                Image(systemName: "lock.open.fill")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            Text(core.isVerifying ? "ĐANG XÁC THỰC..." : "MỞ KHÓA NGAY (UNLOCK)")
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
                    .disabled(inputKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || core.isVerifying || core.isGateBlocking)
                    .opacity(inputKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || core.isGateBlocking ? 0.6 : 1.0)
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

                Spacer(minLength: 40)
            }
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

// MARK: - Screen 2: Aimlock Dashboard Screen
struct AimlockDashboardView: View {
    let session: NABATISessionInfo
    @ObservedObject var core = NABATICore.shared

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                // Header License Status
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("NABATI VIP DASHBOARD")
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .foregroundColor(.white)
                            Text("Key: \(session.maskedKey) • \(session.planType)")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Text("\(session.remainingDays) NGÀY")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Color(red: 0/255, green: 255/255, blue: 157/255))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(red: 0/255, green: 255/255, blue: 157/255).opacity(0.15))
                            .cornerRadius(12)
                    }

                    HStack {
                        Text("Thiết bị: \(NABATIDevice.shared.modelName)")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                        Spacer()
                        Button(action: { core.logout() }) {
                            Text("Đổi Key")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.red.opacity(0.8))
                        }
                    }
                }
                .padding(16)
                .background(Color(red: 16/255, green: 22/255, blue: 40/255).opacity(0.85))
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(red: 0/255, green: 243/255, blue: 255/255).opacity(0.3), lineWidth: 1))
                .padding(.horizontal, 20)
                .padding(.top, 20)

                // Sensitivity preset card. Every control here is local: the
                // numbers are stored on device and copied to the clipboard so
                // the customer can enter them in Free Fire's own settings.
                // Nothing here touches another app's memory or process.
                VStack(spacing: 14) {
                    HStack {
                        Text("ĐỘ NHẠY GỢI Ý")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Picker("", selection: $core.selectedGameIndex) {
                            Text("FF Thường").tag(0)
                            Text("FF MAX").tag(1)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 170)
                    }

                    Divider().background(Color.white.opacity(0.1))

                    SensitivitySliderRow(label: "Nhìn Xung Quanh", value: $core.generalSensitivity)
                    SensitivitySliderRow(label: "Red Dot Sight", value: $core.redDotSensitivity)
                    SensitivitySliderRow(label: "Ống Ngắm 2x", value: $core.scope2xSensitivity)
                    SensitivitySliderRow(label: "Ống Ngắm 4x", value: $core.scope4xSensitivity)

                    Text("Nhập các giá trị này vào Cài đặt → Độ nhạy trong game. Ứng dụng không can thiệp vào bộ nhớ hay tiến trình của game.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button(action: { core.applyRecommendedPreset() }) {
                            HStack(spacing: 6) {
                                Image(systemName: nbtSymbol("wand.and.stars", fallback: "sparkles"))
                                Text("GỢI Ý TỐI ƯU")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(LinearGradient(
                                colors: [Color(red: 255/255, green: 184/255, blue: 0/255), Color(red: 255/255, green: 107/255, blue: 0/255)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .cornerRadius(12)
                        }

                        Button(action: { core.copySensitivityPreset() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.doc.fill")
                                Text("SAO CHÉP")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(Color(red: 0/255, green: 243/255, blue: 255/255))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(red: 0/255, green: 243/255, blue: 255/255).opacity(0.14))
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0/255, green: 243/255, blue: 255/255).opacity(0.4), lineWidth: 1))
                        }
                    }

                    if let message = core.statusMessage {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 0/255, green: 255/255, blue: 157/255))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
                .background(Color(red: 16/255, green: 22/255, blue: 40/255).opacity(0.75))
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
                .padding(.horizontal, 20)

                // Game Launch Buttons
                VStack(spacing: 10) {
                    Button(action: { core.launchFreeFire() }) {
                        HStack {
                            Image(systemName: "gamecontroller.fill")
                            Text("MỞ FREE FIRE THƯỜNG")
                                .font(.system(size: 14, weight: .bold))
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 18)
                        .background(Color(red: 255/255, green: 59/255, blue: 48/255).opacity(0.85))
                        .cornerRadius(12)
                    }

                    Button(action: { core.launchFreeFireMax() }) {
                        HStack {
                            Image(systemName: "flame.fill")
                            Text("MỞ FREE FIRE MAX")
                                .font(.system(size: 14, weight: .bold))
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 18)
                        .background(Color(red: 255/255, green: 149/255, blue: 0/255).opacity(0.85))
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 40)
            }
        }
        .onAppear {
            // Revalidate the session with the server as soon as the dashboard shows.
            core.revalidateSession()
        }
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
