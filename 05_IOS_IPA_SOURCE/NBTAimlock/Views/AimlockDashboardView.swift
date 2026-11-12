import SwiftUI
import UIKit

/// The unlocked dashboard.
///
/// Feature parity target is the web client (`public/index.html`): the same eight
/// modules in two groups, each switch gated by a real `POST
/// /api/license/authorize` round trip, the same 1→100% activation overlay, the
/// same FFTH/FFM selector and game launch, the marquee announcement and the
/// brand text synced from Admin.
///
/// Every switch here reaches the server. There is no local "on" state: the
/// module only turns on after the Worker re-validated the KEY, the device
/// binding and the session for that specific `featureId`.
struct AimlockDashboardView: View {
    let session: NABATISessionInfo
    @ObservedObject var core = NABATICore.shared
    @ObservedObject var store = NABATIFeatureStore.shared

    /// 0 = AIMLOCK, 1 = TỐI ƯU MÁY, 2 = ĐỘ NHẠY, 3 = KEY.
    @State private var selectedTab: Int = 0

    /// Document open in the legal reader, if any.
    @State private var legalSelection: NABATILegalSelection? = nil

    /// Web parity: the web client guards every destructive action with
    /// `confirm(...)` before logging out or resetting modules. The native build
    /// did it immediately, which loses the KEY session on a stray tap.
    @State private var confirmChangeKey = false
    @State private var confirmLogout = false
    @State private var confirmRestoreDefault = false

    /// Web parity: the preset copy button shows a short confirmation instead of
    /// relying on an invisible message.
    @State private var presetCopied = false

    /// Web parity: the customer may re-confirm the display model.
    @State private var showModelPicker = false
    @State private var modelRevision = 0

    /// The web client greets the customer once after unlock and offers to hide
    /// the greeting for two hours. Same behaviour here, stored in UserDefaults.
    @State private var showWelcome = false

    private var accent: Color { Color(red: 0/255, green: 243/255, blue: 255/255) }
    private var accentGreen: Color { Color(red: 0/255, green: 255/255, blue: 157/255) }
    private var accentAmber: Color { Color(red: 255/255, green: 184/255, blue: 0/255) }
    private var cardBg: Color { Color(red: 16/255, green: 22/255, blue: 40/255) }

    private var aimFeatures: [NABATIFeatureState] { store.features.filter { $0.isAim } }
    private var deviceFeatures: [NABATIFeatureState] { store.features.filter { !$0.isAim } }

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    headerCard
                    if store.shouldShowMarquee {
                        MarqueeBanner(text: store.marqueeText)
                    }
                    tabBar
                    tabContent
                    supportCard
                    Spacer(minLength: 36)
                }
                .padding(.bottom, 8)
            }

            if let activation = store.activation {
                ActivationOverlay(progress: activation, store: store)
                    .transition(.opacity)
                    .zIndex(10)
            }

            if showWelcome && store.activation == nil {
                welcomeOverlay
                    .transition(.opacity)
                    .zIndex(9)
            }
        }
        .onAppear {
            core.revalidateSession()
            store.loadConfigIfNeeded()
            if NABATIWelcomeGate.shouldPresent {
                showWelcome = true
                NABATIWelcomeGate.markShown()
            }
        }
        .sheet(item: $legalSelection) { selection in
            LegalDocumentView(type: selection.id)
        }
    }

    // MARK: - Welcome

    private var welcomeOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 12) {
                Text("🎉").font(.system(size: 52))
                Text("CHÀO MỪNG!")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(.white)

                Text("\(NABATIDevice.shared.displayModelName) • iOS \(NABATIDevice.shared.systemVersion)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.12))
                    .cornerRadius(20)

                Text("Thiết bị đã được xác thực thành công. Chúc bạn chơi game vui vẻ!")
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 200/255, green: 212/255, blue: 232/255))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(action: {
                        NABATIWelcomeGate.snoozeTwoHours()
                        showWelcome = false
                    }) {
                        Text("Ẩn 2 giờ")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(11)
                    }

                    Button(action: { showWelcome = false }) {
                        Text("Bắt đầu")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(LinearGradient(
                                colors: [accent, Color(red: 0/255, green: 190/255, blue: 255/255)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .cornerRadius(11)
                    }
                }
                .padding(.top, 6)
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(Color(red: 16/255, green: 22/255, blue: 40/255))
            .cornerRadius(20)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.1), lineWidth: 1))
            .padding(.horizontal, 28)
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.config.appName)
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(store.config.appSub)
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(1.2)
                        .foregroundColor(accent)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Key: \(session.maskedKey) • \(session.planType)")
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 139/255, green: 151/255, blue: 179/255))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(session.remainingBadge)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(accentGreen)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(accentGreen.opacity(0.15))
                    .cornerRadius(12)
            }

            Divider().background(Color.white.opacity(0.08))

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("THIẾT BỊ")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.2)
                        .foregroundColor(Color(red: 90/255, green: 104/255, blue: 132/255))
                    Text(NABATIDevice.shared.displayModelName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Color(red: 200/255, green: 212/255, blue: 232/255))
                        .lineLimit(1)
                }
                Spacer()
                Button(action: { showModelPicker = true }) {
                    Text("📱")
                        .font(.system(size: 13))
                        .foregroundColor(accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(accent.opacity(0.12))
                        .cornerRadius(8)
                }
                Button(action: { confirmChangeKey = true }) {
                    Text("Đổi Key")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Color(red: 248/255, green: 113/255, blue: 113/255))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(red: 248/255, green: 113/255, blue: 113/255).opacity(0.12))
                        .cornerRadius(9)
                }
                .alert(isPresented: $confirmChangeKey) {
                    Alert(
                        title: Text("Đổi mã key khác?"),
                        message: Text("Bạn sẽ quay lại màn hình nhập KEY. Các module đang bật sẽ được tắt."),
                        primaryButton: .destructive(Text("Đổi key")) { core.logout() },
                        secondaryButton: .cancel(Text("Hủy"))
                    )
                }
            }

            if let message = store.statusMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(accentGreen)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(cardBg.opacity(0.9))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(accent.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 16)
        // iOS 14 presents one `.sheet` per view reliably, so this rides on the
        // header card while the root keeps the legal-document sheet.
        .sheet(isPresented: $showModelPicker) {
            PhoneModelPickerView(isPresented: $showModelPicker) { _ in
                modelRevision += 1
            }
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 5) {
            tabChip("🎯 AIMLOCK", index: 0)
            tabChip("⚡ TỐI ƯU", index: 1)
            tabChip("🔫 ĐỘ NHẠY", index: 2)
            tabChip("ℹ️ KEY", index: 3)
        }
        .padding(5)
        .background(Color(red: 20/255, green: 27/255, blue: 43/255))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 42/255, green: 55/255, blue: 82/255), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func tabChip(_ label: String, index: Int) -> some View {
        let selected = selectedTab == index
        return Button(action: { selectedTab = index }) {
            Text(label)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(selected ? .black : Color(red: 169/255, green: 182/255, blue: 206/255))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(selected ? accent : Color.clear)
                .cornerRadius(8)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case 0:
            VStack(spacing: 16) {
                aimSection
                launchCard
            }
        case 1:
            deviceSection
        case 2:
            sensitivitySection
        default:
            keyInfoSection
        }
    }

    // MARK: - Tab 1: AIMLOCK

    private var aimSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("🎯 AIMLOCK")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.3)
                    .foregroundColor(accent)
                Text("\(aimFeatures.filter { $0.active }.count) bật")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(accent.opacity(0.13))
                    .cornerRadius(7)
                Spacer()
            }
            Text("Bật các module hỗ trợ kéo tâm. Mỗi module được máy chủ ủy quyền riêng trước khi kích hoạt.")
                .font(.system(size: 11))
                .foregroundColor(Color(red: 139/255, green: 151/255, blue: 179/255))
                .fixedSize(horizontal: false, vertical: true)

            if aimFeatures.isEmpty {
                Text("Máy chủ chưa cấu hình module kéo tâm nào.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(red: 139/255, green: 151/255, blue: 179/255))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(aimFeatures) { feature in
                    FeatureRow(feature: feature, tint: accent) { isOn in
                        store.toggle(featureId: feature.id, isOn: isOn)
                    }
                }
            }

            gameSelectorCard
        }
        .padding(16)
        .background(cardBg.opacity(0.7))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 16)
    }

    private var gameSelectorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("🎮 Chọn game để khởi chạy")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.1)
                .foregroundColor(.white)

            HStack(spacing: 9) {
                gameChip("Free Fire TH", value: "FFTH")
                gameChip("Free Fire MAX", value: "FFM")
            }

            Button(action: { store.optimizeAll() }) {
                HStack(spacing: 7) {
                    Image(systemName: nbtSymbol("bolt.fill", fallback: "bolt"))
                        .font(.system(size: 13, weight: .bold))
                    Text("KÍCH HOẠT & VÀO GAME")
                        .font(.system(size: 12.5, weight: .bold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(LinearGradient(
                    colors: [accent, accentGreen],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .cornerRadius(12)
                .shadow(color: accent.opacity(0.35), radius: 8, y: 3)
            }
        }
        .padding(14)
        .background(Color(red: 20/255, green: 27/255, blue: 43/255))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 42/255, green: 55/255, blue: 82/255), lineWidth: 1))
    }

    private func gameChip(_ label: String, value: String) -> some View {
        let selected = store.selectedGame == value
        return Button(action: { store.selectGame(value) }) {
            Text(label)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundColor(selected ? .black : Color(red: 169/255, green: 182/255, blue: 206/255))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(selected ? accent : Color(red: 28/255, green: 37/255, blue: 58/255))
                .cornerRadius(11)
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(selected ? Color.clear : Color(red: 42/255, green: 55/255, blue: 82/255), lineWidth: 1)
                )
        }
    }

    // MARK: - Tab 2: Device optimization

    private var deviceSection: some View {
        let facts = NABATIDeviceFacts.shared
        return VStack(alignment: .leading, spacing: 14) {
            Text("⚡ DEVICE OPTIMIZATION")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.3)
                .foregroundColor(accentGreen)
            Text("Thông tin thiết bị đọc từ hệ điều hành. Các preset chỉ là gợi ý cấu hình — không cam kết tăng FPS thực tế.")
                .font(.system(size: 11))
                .foregroundColor(Color(red: 139/255, green: 151/255, blue: 179/255))
                .fixedSize(horizontal: false, vertical: true)

            deviceInfoGrid(facts)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    presetButton("🍃 NHẸ", subtitle: "Ưu tiên tiết kiệm pin, giảm nhiệt. Phù hợp máy yếu / chơi lâu.", preset: "light")
                    presetButton("⚖️ CÂN BẰNG", subtitle: "Cân đối hiệu năng & nhiệt độ. Khuyên dùng cho đa số máy.", preset: "balanced")
                }
                HStack(spacing: 8) {
                    presetButton("🚀 HIỆU NĂNG", subtitle: "Ưu tiên độ mượt tối đa. Phù hợp máy khỏe, tản nhiệt tốt.", preset: "perf")
                    presetButton("🛠 TÙY CHỈNH", subtitle: "Tự bật từng module bên dưới theo ý bạn.", preset: "custom")
                }
            }

            if deviceFeatures.isEmpty {
                Text("Máy chủ chưa cấu hình module tối ưu nào.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(red: 139/255, green: 151/255, blue: 179/255))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(deviceFeatures) { feature in
                        FeatureRow(feature: feature, tint: accentGreen) { isOn in
                            store.toggle(featureId: feature.id, isOn: isOn)
                        }
                    }
                }
            }

            Button(action: { confirmRestoreDefault = true }) {
                Text("↺ Khôi phục mặc định")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 169/255, green: 182/255, blue: 206/255))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color(red: 20/255, green: 27/255, blue: 43/255))
                    .cornerRadius(11)
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(red: 42/255, green: 55/255, blue: 82/255), lineWidth: 1))
            }
            .alert(isPresented: $confirmRestoreDefault) {
                Alert(
                    title: Text("Khôi phục mặc định?"),
                    message: Text("Tất cả module tối ưu đang bật sẽ được tắt về trạng thái ban đầu."),
                    primaryButton: .destructive(Text("Khôi phục")) { store.restoreDefaultDeviceState() },
                    secondaryButton: .cancel(Text("Hủy"))
                )
            }
        }
        .padding(16)
        .background(cardBg.opacity(0.7))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 16)
    }

    private func deviceInfoGrid(_ facts: NABATIDeviceFacts) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                infoCell("MÁY", facts.model)
                infoCell("HỆ ĐIỀU HÀNH", facts.osText)
            }
            HStack(alignment: .top, spacing: 10) {
                infoCell("RAM", facts.ramText)
                infoCell("LƯU TRỮ", facts.storageText)
            }
            HStack(alignment: .top, spacing: 10) {
                infoCell("CPU (NHÂN)", facts.cpuText)
                infoCell("MÀN HÌNH", facts.screenSize)
            }
        }
        .padding(13)
        .background(Color(red: 20/255, green: 27/255, blue: 43/255))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 42/255, green: 55/255, blue: 82/255), lineWidth: 1))
    }

    private func infoCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .bold))
                .tracking(1)
                .foregroundColor(Color(red: 90/255, green: 104/255, blue: 132/255))
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(Color(red: 210/255, green: 220/255, blue: 236/255))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func presetButton(_ title: String, subtitle: String, preset: String) -> some View {
        let selected = store.activeDevicePreset == preset
        return Button(action: { store.applyDevicePreset(preset) }) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(selected ? .black : .white)
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundColor(selected ? Color.black.opacity(0.72) : Color(red: 139/255, green: 151/255, blue: 179/255))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(selected ? accentGreen : Color(red: 20/255, green: 27/255, blue: 43/255))
            .cornerRadius(11)
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(
                selected ? Color.clear : Color(red: 42/255, green: 55/255, blue: 82/255),
                lineWidth: 1
            ))
        }
    }

    // MARK: - Tab 3: Sensitivity

    private var sensitivitySection: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("🔫 ĐỘ NHẠY THEO DÒNG MÁY")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.3)
                    .foregroundColor(accentAmber)
                Text("Nhập tên dòng máy để nhận 3 cấu hình độ nhạy đề xuất — NHẸ TÂM / NHẠY TRUNG / ĐẦM TÂM.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 139/255, green: 151/255, blue: 179/255))
                    .fixedSize(horizontal: false, vertical: true)

                SensitivityLookupView()
            }
            .padding(16)
            .background(cardBg.opacity(0.7))
            .cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))

            quickSensitivityCard
        }
        .padding(.horizontal, 16)
    }

    /// Local reference values kept from the first build: these are numbers the
    /// customer types into the game's own settings screen. Nothing here writes to
    /// the game, and nothing here unlocks a module.
    private var quickSensitivityCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("CẤU HÌNH NHANH TRÊN MÁY")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundColor(.white)
                Spacer()
                Picker("", selection: $core.selectedGameIndex) {
                    Text("FF Thường").tag(0)
                    Text("FF MAX").tag(1)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 160)
            }

            Divider().background(Color.white.opacity(0.1))

            SensitivitySliderRow(label: "Nhìn Xung Quanh", value: $core.generalSensitivity)
            SensitivitySliderRow(label: "Red Dot Sight", value: $core.redDotSensitivity)
            SensitivitySliderRow(label: "Ống Ngắm 2x", value: $core.scope2xSensitivity)
            SensitivitySliderRow(label: "Ống Ngắm 4x", value: $core.scope4xSensitivity)

            Text("Nhập các giá trị này vào Cài đặt → Độ nhạy trong game. Ứng dụng không can thiệp vào bộ nhớ hay tiến trình của game.")
                .font(.system(size: 10.5))
                .foregroundColor(Color(red: 139/255, green: 151/255, blue: 179/255))
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
                        colors: [accentAmber, Color(red: 255/255, green: 107/255, blue: 0/255)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .cornerRadius(12)
                }

                Button(action: {
                    let copied = core.copySensitivityPreset()
                    guard copied else { return }
                    presetCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        presetCopied = false
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: presetCopied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                        Text(presetCopied ? "ĐÃ SAO CHÉP" : "SAO CHÉP")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(accent.opacity(0.14))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.4), lineWidth: 1))
                }
            }
        }
        .padding(16)
        .background(cardBg.opacity(0.7))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    // MARK: - Tab 4: Key info

    private var keyInfoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ℹ️ THÔNG TIN KEY")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.3)
                .foregroundColor(.white)

            VStack(spacing: 0) {
                keyRow("Mã key", session.maskedKey, mono: true)
                keyDivider
                keyRow("Trạng thái", "Hoạt động", color: accentGreen)
                keyDivider
                keyRow("Còn lại", session.remainingLabel, color: accentGreen)
                keyDivider
                keyRow("Hết hạn", session.expiryLabel)
                keyDivider
                keyRow("Thiết bị", NABATIDevice.shared.displayModelName)
                keyDivider
                keyRow("Phiên bản", "v\(NABATIAppVersion.version)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(Color(red: 20/255, green: 27/255, blue: 43/255))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 42/255, green: 55/255, blue: 82/255), lineWidth: 1))

            Text("🔐 Mọi xác thực đều do máy chủ quyết định. Ứng dụng không thể bỏ qua kiểm tra key.")
                .font(.system(size: 10.5))
                .foregroundColor(Color(red: 139/255, green: 151/255, blue: 179/255))
                .fixedSize(horizontal: false, vertical: true)

            // Same four documents as the web footer. The copy lives in Admin
            // (`/api/legal`), so a policy edit reaches the app without a build.
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    legalLink("Giới thiệu", type: "about")
                    legalLink("Hướng dẫn", type: "guide")
                }
                HStack(spacing: 16) {
                    legalLink("Điều khoản sử dụng", type: "terms")
                    legalLink("Chính sách bảo mật", type: "privacy")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)

            Button(action: { confirmLogout = true }) {
                Text("⎋ Đăng xuất / Đổi key")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(red: 248/255, green: 113/255, blue: 113/255))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color(red: 248/255, green: 113/255, blue: 113/255).opacity(0.1))
                    .cornerRadius(11)
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(red: 248/255, green: 113/255, blue: 113/255).opacity(0.3), lineWidth: 1))
            }
            .alert(isPresented: $confirmLogout) {
                Alert(
                    title: Text("Đăng xuất khỏi key hiện tại?"),
                    message: Text("Phiên sử dụng trên máy này sẽ kết thúc. KEY của bạn không bị thay đổi."),
                    primaryButton: .destructive(Text("Đăng xuất")) { core.logout() },
                    secondaryButton: .cancel(Text("Hủy"))
                )
            }
        }
        .padding(16)
        .background(cardBg.opacity(0.7))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 16)
    }

    private func legalLink(_ title: String, type: String) -> some View {
        Button(action: { legalSelection = NABATILegalSelection(id: type) }) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Color.white.opacity(0.45))
                .underline()
        }
    }

    private var keyDivider: some View {
        Divider().background(Color.white.opacity(0.06))
    }

    private func keyRow(
        _ label: String,
        _ value: String,
        mono: Bool = false,
        color: Color = Color(red: 210/255, green: 220/255, blue: 236/255)
    ) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(red: 90/255, green: 104/255, blue: 132/255))
            Spacer(minLength: 10)
            Text(value)
                .font(mono ? .system(size: 12, weight: .bold, design: .monospaced) : .system(size: 12.5, weight: .semibold))
                .foregroundColor(color)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 9)
    }

    // MARK: - Launch

    private var launchCard: some View {
        VStack(spacing: 10) {
            Button(action: { store.launchSelectedGame() }) {
                HStack {
                    Image(systemName: "gamecontroller.fill")
                    Text(store.selectedGame == "FFM" ? "VÀO FREE FIRE MAX" : "VÀO FREE FIRE")
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                }
                .foregroundColor(.black)
                .padding(.vertical, 15)
                .padding(.horizontal, 18)
                .background(LinearGradient(
                    colors: [accent, Color(red: 0/255, green: 190/255, blue: 255/255)],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .cornerRadius(13)
            }

            Text("Chức năng kéo tâm chỉ hoạt động khi KEY còn hạn và máy chủ xác nhận uỷ quyền.")
                .font(.system(size: 10.5))
                .foregroundColor(Color(red: 139/255, green: 151/255, blue: 179/255))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Support

    private var supportCard: some View {
        Button(action: { core.openZaloSupport() }) {
            HStack(spacing: 10) {
                Image(systemName: nbtSymbol("message.fill", fallback: "envelope.fill"))
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 2) {
                    Text("CẦN HỖ TRỢ?")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                    Text("Zalo: 0356075419")
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(Color(red: 169/255, green: 182/255, blue: 206/255))
            .padding(15)
            .frame(maxWidth: .infinity)
            .background(Color(red: 20/255, green: 27/255, blue: 43/255))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14).stroke(Color(red: 42/255, green: 55/255, blue: 82/255), lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Per-model sensitivity lookup

/// The web client's "ĐỘ NHẠY THEO DÒNG MÁY" panel, natively.
///
/// Looks a phone model up on `/api/sensitivity` and renders the three tiers
/// (`light` / `mid` / `heavy`) the database row carries, each with a "Sao chép"
/// button that copies the same text the web client's `copySensConfig` builds.
///
/// A miss returns the server's suggestion list as tappable chips; that is a
/// normal answer, not an error state to hide.
private struct SensitivityLookupView: View {
    @State private var inputModel: String = NABATIDevice.shared.displayModelName
    @State private var searching: Bool = false
    @State private var errorText: String? = nil
    @State private var suggestions: [NABATISensitivityLookup.NABATISensitivitySuggestion] = []
    @State private var result: NABATISensitivityResult? = nil
    @State private var copiedTier: String? = nil

    private var accent: Color { Color(red: 255/255, green: 184/255, blue: 0/255) }
    private var fieldBg: Color { Color(red: 20/255, green: 27/255, blue: 43/255) }
    private var stroke: Color { Color(red: 42/255, green: 55/255, blue: 82/255) }
    private var errorColor: Color { Color(red: 248/255, green: 113/255, blue: 113/255) }
    private var muted: Color { Color(red: 139/255, green: 151/255, blue: 179/255) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DÒNG MÁY CỦA BẠN")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(1.1)
                .foregroundColor(muted)

            HStack(spacing: 9) {
                TextField("vd: iPhone 15 Pro Max, Samsung S24 Ultra...", text: $inputModel, onCommit: lookup)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .background(fieldBg)
                    .cornerRadius(11)
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(stroke, lineWidth: 1))

                Button(action: lookup) {
                    Group {
                        if searching {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .black))
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 15, weight: .bold))
                        }
                    }
                    .frame(width: 46, height: 46)
                    .background(accent)
                    .foregroundColor(.black)
                    .cornerRadius(11)
                }
                .disabled(searching || inputModel.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if searching {
                HStack(spacing: 7) {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: accent))
                    Text("Đang tìm cấu hình...")
                        .font(.system(size: 11.5))
                        .foregroundColor(accent)
                    Spacer()
                }
            }

            if let error = errorText {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundColor(errorColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(errorColor.opacity(0.1))
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(errorColor.opacity(0.3), lineWidth: 1))
            }

            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.query) { suggestion in
                            Button(action: {
                                inputModel = suggestion.query
                                lookup()
                            }) {
                                Text("📱 \(suggestion.query)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(accent)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 7)
                                    .background(accent.opacity(0.1))
                                    .cornerRadius(9)
                                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(accent.opacity(0.3), lineWidth: 1))
                            }
                        }
                    }
                }
            }

            if let result = result {
                resultBlock(result)
            }
        }
    }

    // MARK: - Lookup

    private func lookup() {
        let query = inputModel.trimmingCharacters(in: .whitespaces)
        // Same minimum as the web client, so a one-letter query does not burn a
        // round trip.
        guard query.count >= 2 else {
            errorText = "Nhập tên dòng máy (vd: iPhone 15 Pro Max)"
            suggestions = []
            result = nil
            return
        }
        searching = true
        errorText = nil
        suggestions = []
        result = nil
        copiedTier = nil

        NABATISensitivityLookup.lookup(model: query) { outcome in
            searching = false
            switch outcome {
            case .success(let found):
                result = found
            case .failure(let error):
                if let miss = error as? NABATISensitivityLookup.NABATISensitivityMiss {
                    suggestions = miss.suggestions
                    errorText = miss.suggestions.isEmpty
                        ? "Không tìm thấy \"\(query)\" trong danh sách. Hãy thử tên khác."
                        : "Không tìm thấy \"\(query)\". Có thể bạn muốn:"
                } else {
                    errorText = (error as? LocalizedError)?.errorDescription
                        ?? "Lỗi kết nối máy chủ. Thử lại sau."
                }
            }
        }
    }

    // MARK: - Result

    private func resultBlock(_ found: NABATISensitivityResult) -> some View {
        let rows: [SensTierRow] = [
            found.light.map { SensTierRow(key: "light", tier: $0) },
            found.mid.map { SensTierRow(key: "mid", tier: $0) },
            found.heavy.map { SensTierRow(key: "heavy", tier: $0) }
        ].compactMap { $0 }
        return VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(found.model)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(found.brand)
                        .font(.system(size: 11))
                        .foregroundColor(muted)
                }
                Spacer()
                Button(action: {
                    result = nil
                    inputModel = ""
                }) {
                    Text("↺ Đổi máy")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(red: 169/255, green: 182/255, blue: 206/255))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(fieldBg)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(stroke, lineWidth: 1))
                }
            }

            ForEach(rows, id: \.key) { row in
                tierCard(row.tier, key: row.key, found: found)
            }
        }
    }

    private func tierCard(_ tier: NABATISensitivityTier, key: String, found: NABATISensitivityResult) -> some View {
        let color = tierColor(key)
        let keys = tier.params.keys.sorted()
        let copied = copiedTier == key
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(tierIcon(key)) \(tier.name)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(color)
                    if !tier.desc.isEmpty {
                        Text(tier.desc)
                            .font(.system(size: 10.5))
                            .foregroundColor(muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(tier.value)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }
            .padding(.bottom, 10)

            if !keys.isEmpty {
                VStack(spacing: 0) {
                    ForEach(keys, id: \.self) { param in
                        HStack {
                            Text(param)
                                .font(.system(size: 11.5))
                                .foregroundColor(muted)
                            Spacer(minLength: 8)
                            Text(tier.params[param] ?? "")
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.vertical, 5)
                        if param != keys.last {
                            Divider().background(Color.white.opacity(0.05))
                        }
                    }
                }
                .padding(.bottom, 10)
            } else {
                // Web fallback when a row has no per-parameter breakdown: it
                // still shows the headline figure rather than an empty gap.
                Text("Độ nhạy tổng: \(tier.value)")
                    .font(.system(size: 12))
                    .foregroundColor(muted)
                    .padding(.bottom, 10)
            }

            Button(action: {
                UIPasteboard.general.string = found.copyText(for: tier)
                copiedTier = key
            }) {
                HStack(spacing: 6) {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(copied ? "ĐÃ SAO CHÉP" : "SAO CHÉP")
                        .font(.system(size: 11.5, weight: .bold))
                }
                .foregroundColor(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(color.opacity(0.12))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35), lineWidth: 1))
            }
        }
        .padding(13)
        .background(fieldBg)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(stroke, lineWidth: 1))
    }

    /// Slot-based, not name-based: the Worker picks the labels, but the tier a
    /// row belongs to is fixed (`light`/`mid`/`heavy`) — the same meta the web
    /// client keeps in `SENS_TIER_META`.
    private func tierColor(_ key: String) -> Color {
        switch key {
        case "light": return Color(red: 34/255, green: 211/255, blue: 238/255)
        case "mid":   return Color(red: 139/255, green: 92/255, blue: 246/255)
        case "heavy": return Color(red: 52/255, green: 211/255, blue: 153/255)
        default:      return accent
        }
    }

    private func tierIcon(_ key: String) -> String {
        switch key {
        case "light": return "🪶"
        case "mid":   return "⚖️"
        case "heavy": return "🎯"
        default:      return "🎯"
        }
    }
}

/// One `light`/`mid`/`heavy` slot paired with its tier row, so the card meta
/// (icon, colour) follows the slot and not the admin-editable label.
private struct SensTierRow {
    let key: String
    let tier: NABATISensitivityTier
}

// MARK: - A single module row

private struct FeatureRow: View {
    let feature: NABATIFeatureState
    let tint: Color
    let onToggle: (Bool) -> Void

    private var symbol: String {
        switch feature.icon {
        case "crosshair": return nbtSymbol("scope", fallback: "circle.dashed")
        case "eye":       return nbtSymbol("eye.fill", fallback: "circle.fill")
        case "phone":     return nbtSymbol("iphone", fallback: "rectangle.fill")
        case "bolt":      return nbtSymbol("bolt.fill", fallback: "bolt")
        default:          return nbtSymbol("bolt.fill", fallback: "bolt")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill((feature.active ? tint : Color.white).opacity(feature.active ? 0.16 : 0.05))
                    .frame(width: 40, height: 40)
                if feature.authorizing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: tint))
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(feature.active ? tint : Color(red: 139/255, green: 151/255, blue: 179/255))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(feature.active ? .white : Color(red: 210/255, green: 220/255, blue: 236/255))
                Text(feature.desc)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(red: 139/255, green: 151/255, blue: 179/255))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Toggle("", isOn: Binding(
                get: { feature.active },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .disabled(feature.authorizing)
            .nbtTint(tint)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Marquee announcement

/// Horizontally scrolling admin announcement.
///
/// The web client uses a CSS marquee. UIKit's `UIView.animate` is used here with
/// `.repeat` so the text loops without a Timer, which keeps the run loop free and
/// survives backgrounding without accumulating work.
/// Internal, not private: the lock screen shows the same admin-controlled
/// notice bar the web client renders above its KEY form.
struct MarqueeBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: nbtSymbol("megaphone.fill", fallback: "bell.fill"))
                .font(.system(size: 11))
                .foregroundColor(Color(red: 255/255, green: 184/255, blue: 0/255))
            MarqueeText(text: text)
                .frame(height: 18)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(red: 255/255, green: 184/255, blue: 0/255).opacity(0.1))
        .cornerRadius(11)
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color(red: 255/255, green: 184/255, blue: 0/255).opacity(0.28), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }
}

/// UIView-backed marquee. SwiftUI has no built-in scrolling text on iOS 14 and
/// the usual `TimelineView`/`offset` approaches need iOS 15+, so this bridges a
/// plain UIKit label whose position is animated once and repeated.
private struct MarqueeText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> MarqueeLabelView {
        let view = MarqueeLabelView()
        view.configure(text: text)
        return view
    }

    func updateUIView(_ uiView: MarqueeLabelView, context: Context) {
        uiView.configure(text: text)
    }
}

final class MarqueeLabelView: UIView {
    private let label = UILabel()
    private var currentText: String = ""
    private var animationKey = "nbt.marquee"

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        label.font = UIFont.systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = UIColor(red: 1.0, green: 0.84, blue: 0.42, alpha: 1.0)
        label.numberOfLines = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String) {
        guard text != currentText else { return }
        currentText = text
        label.text = text
        label.sizeToFit()
        label.layer.removeAnimation(forKey: animationKey)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        label.sizeToFit()

        let textWidth = label.bounds.width
        guard textWidth > 0 else { return }

        if textWidth <= bounds.width {
            // Fits: pin left, no scroll. Animating a static string would look
            // like a rendering bug.
            label.frame = CGRect(x: 0, y: (bounds.height - label.bounds.height) / 2,
                                 width: textWidth, height: label.bounds.height)
            label.layer.removeAnimation(forKey: animationKey)
            return
        }

        let start = bounds.width
        label.frame = CGRect(x: start, y: (bounds.height - label.bounds.height) / 2,
                             width: textWidth, height: label.bounds.height)

        guard label.layer.animation(forKey: animationKey) == nil else { return }
        let distance = start + textWidth
        // Constant speed regardless of text length: ~38 pt per second.
        let duration = Double(distance) / 38.0

        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = start + textWidth / 2
        animation.toValue = -textWidth / 2
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        label.layer.add(animation, forKey: animationKey)
    }
}

// MARK: - Activation overlay (1 → 100%)

/// Cosmetic progress around an authorization that already succeeded.
///
/// The grant is obtained *before* this overlay appears, so cancelling here
/// cancels the module — the animation never stands in for a server check.
private struct ActivationOverlay: View {
    let progress: NABATIActivationProgress
    @ObservedObject var store: NABATIFeatureStore

    private var accent: Color { Color(red: 0/255, green: 243/255, blue: 255/255) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(accent.opacity(0.15), lineWidth: 7)
                        .frame(width: 118, height: 118)
                    Circle()
                        .trim(from: 0, to: CGFloat(progress.percent) / 100.0)
                        .stroke(
                            LinearGradient(colors: [accent, Color(red: 0/255, green: 255/255, blue: 157/255)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .frame(width: 118, height: 118)
                        .rotationEffect(.degrees(-90))
                    Text("\(progress.percent)")
                        .font(.system(size: 30, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                }

                VStack(spacing: 5) {
                    Text(progress.phaseLabel)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.white)
                    Text(progress.subsystemLabel)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.6)
                        .foregroundColor(accent)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(progress.log) { line in
                            HStack(spacing: 6) {
                                Text(line.done ? "[OK]" : "[RUNNING]")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(line.done
                                                     ? Color(red: 0/255, green: 255/255, blue: 157/255)
                                                     : accent)
                                Text(line.module)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Color(red: 169/255, green: 182/255, blue: 206/255))
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
                .padding(10)
                .background(Color.black.opacity(0.45))
                .cornerRadius(9)

                if progress.finished {
                    HStack(spacing: 10) {
                        Button(action: { store.launchSelectedGame() }) {
                            Text("VÀO GAME")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(accent)
                                .cornerRadius(11)
                        }
                        Button(action: { store.dismissActivation() }) {
                            Text("ĐÓNG")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Color(red: 169/255, green: 182/255, blue: 206/255))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(red: 20/255, green: 27/255, blue: 43/255))
                                .cornerRadius(11)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11)
                                        .stroke(Color(red: 42/255, green: 55/255, blue: 82/255), lineWidth: 1)
                                )
                        }
                    }
                } else {
                    Button(action: { store.cancelActivation() }) {
                        Text("HỦY KHỞI TẠO")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Color(red: 248/255, green: 113/255, blue: 113/255))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color(red: 248/255, green: 113/255, blue: 113/255).opacity(0.1))
                            .cornerRadius(11)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 380)
            .background(Color(red: 10/255, green: 15/255, blue: 30/255))
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(accent.opacity(0.3), lineWidth: 1)
            )
            .padding(20)
        }
    }
}

/// Persists the "hide the greeting for two hours" choice, the same behaviour
/// the web client keeps in `localStorage`.
private enum NABATIWelcomeGate {
    private static let key = "nbt_welcome_mute_until"

    /// Dismissal is remembered for the life of the process as well as in
    /// `UserDefaults`: a view re-appearance must not pop the modal again after
    /// the customer already tapped "Bắt đầu".
    private static var shownThisSession = false

    static var shouldPresent: Bool {
        guard !shownThisSession else { return false }
        let until = UserDefaults.standard.double(forKey: key)
        return Date().timeIntervalSince1970 * 1000 >= until
    }

    static func markShown() {
        shownThisSession = true
    }

    static func snoozeTwoHours() {
        let until = (Date().timeIntervalSince1970 + 2 * 3600) * 1000
        UserDefaults.standard.set(until, forKey: key)
    }
}
