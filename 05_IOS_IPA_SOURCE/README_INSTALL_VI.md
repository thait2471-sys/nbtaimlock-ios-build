# Hướng dẫn cài NBTAIMLOCK trên iPhone

> Trang hướng dẫn trực tuyến: **https://nbtaimlockshopcom.thait2471.workers.dev/ios/**
> (giao diện mobile/PC, có nút tải IPA, mã SHA-256 và phần xử lý lỗi)

## 1. Kết luận ngắn

Gói IPA đang phát hành là **IPA unsigned sạch** — đúng định dạng đầu vào cho
ESign / Sideloadly / AltStore. iOS **không** cài trực tiếp file unsigned; phải ký
bằng chứng chỉ Apple của bạn trước.

Lỗi **“Không thể cài đặt, vui lòng thử lại sau”** xuất hiện *trước khi* iOS xét tới
nội dung app, nên nguyên nhân gần như luôn nằm ở **chứng chỉ / provisioning profile**,
không phải ở mã nguồn. Ba lỗi cấu trúc của bản IPA cũ đã được sửa từ trước:

1. `Info.plist` thiếu `CFBundleSupportedPlatforms` và `UIRequiredDeviceCapabilities`.
2. `CFBundleIconFiles` trỏ tới `AppIcon76x76` nhưng file không có trong bundle.
3. Binary mang chữ ký ad-hoc tự chế (`CS_ADHOC`) kèm `_CodeSignature/CodeResources` cũ.

## 2. Bản đã deploy

- Trang hướng dẫn: `https://nbtaimlockshopcom.thait2471.workers.dev/ios/`
- File tải: `https://nbtaimlockshopcom.thait2471.workers.dev/nbtaimlock-release-unsigned.ipa`
- Kích thước: **3.009.908 bytes**
- SHA-256: `d8a77fde8a56bc0a0739ab157506045a18bf4cb7466cdf23c83e976550f55085`
- Bundle ID: `com.nbtaimlock.ios` · Version 4.2.0 (build 420) · MinimumOSVersion 14.0
- Binary: **Swift thật** (`1.079.024` bytes, có `__swift5_proto`), không phải bản ObjC

> **Đã deploy (12/11/2026):** file trên `nbtaimlockshopcom` nay là **bản Swift**
> build từ `05_IOS_IPA_SOURCE/NBTAimlock/NBTAimlock.xcodeproj` bằng GitHub Actions
> (`build-ios.yml`, runner `macos-15`) — xem mục 5.1. Bản Objective-C cũ
> (2.030.355 bytes, SHA `2e650423…`) không còn được phục vụ; bản sao lưu nằm ở
> `backups/ipa-release-20261112-054000/`.
>
> Metadata trên trang `/ios/` (dung lượng, SHA-256, version, build, bundle ID) được
> đọc trực tiếp từ file đang phục vụ qua `/api/ios/unsigned-build`, nên không thể
> lệch với file thật. Nút **Sao chép** đọc SHA-256 tại thời điểm bấm.

Kiểm tra bằng cổng cấu trúc của repo:

```bash
python3 tools/verify_unsigned_ipa.py dist/nbtaimlock-release-unsigned.ipa
```

Kết quả: **PASS** — `build : swift`, Mach-O arm64, 5 segment, 34 section, entry
point khớp `LC_MAIN`, 8 zip entry, 2 tiền tố icon, không có `LC_CODE_SIGNATURE`,
không có `_CodeSignature/`. **Không** cần cờ `--legacy-native`: binary thật sự
link Swift runtime và có `__swift5_proto`.

> Cờ `--legacy-native` chỉ dùng cho bản Objective-C cũ, và **không** phải cờ bỏ
> qua kiểm tra. Nó bật một phép so khớp danh tính chặt: binary phải link đúng 5
> system dylib, không có Swift runtime, không có `__swift5_*`, chứa đủ marker
> `NABATIMainViewController` / `AppDelegate` / `SceneDelegate` /
> `/api/license/authorize` / `/api/heartbeat`, và `LC_BUILD_VERSION` minos đúng
> `14.0.0`. Một binary lạ vẫn bị từ chối.

## 2.1. KEY hợp lệ cho iOS

App gửi header `X-Client-Platform: ios_ipa`; máy chủ chuẩn hoá thành `ios_web`.
Vì vậy KEY dùng để đăng nhập phải có platform **`ios_web`**.

- KEY `ios_web` → xác thực và kích hoạt bình thường.
- KEY `android_apk` → bị từ chối `403 PLATFORM_MISMATCH` (bảo vệ đúng, không phải lỗi cài đặt).
- Nếu chưa có KEY iOS: vào Admin → Keys → tạo KEY với Platform = **iOS Web**.

## 3. Ký bằng ESign (trên iPhone)

1. Mở ESign → **File** → Import file IPA vừa tải (hoặc Share Sheet → ESign).
2. Chọn IPA → **Signature**.
3. Chọn **Certificate** là chứng chỉ Apple của bạn (còn hạn, không bị thu hồi).
4. Chọn **Provisioning Profile** tương ứng:
   - App ID của profile phải là `com.nbtaimlock.ios` **hoặc** profile wildcard `*`.
   - Với profile development/ad-hoc, UDID của iPhone phải nằm trong profile.
   - Không chọn chế độ “chỉ ký ad-hoc” nếu ESign có tuỳ chọn này.
5. Bật **Remove signature before signing** nếu ESign có.
6. Bấm **Sign** → chờ ESign đóng gói lại.
7. Cài bản vừa ký. Nếu hỏi ghi đè app cũ, chọn **xoá app cũ trước**.

## 4. Ký bằng Sideloadly / AltStore (PC + iPhone)

1. Cắm iPhone, mở Sideloadly.
2. Kéo file `nbtaimlock-release-unsigned.ipa` vào ô IPA.
3. Nhập Apple ID (hoặc chọn certificate) → Start.
4. Apple ID miễn phí: app hết hạn sau 7 ngày, phải ký lại — giới hạn của Apple,
   không phải lỗi app.

## 5. Build IPA thật từ Xcode project (GitHub Actions)

Workflow `.github/workflows/build-ios.yml` biên dịch **chính Xcode project**
(`05_IOS_IPA_SOURCE/NBTAimlock/NBTAimlock.xcodeproj`) trên runner `macos-15`:

- `xcodebuild` với `CODE_SIGNING_ALLOWED=NO` → app unsigned
- đóng gói `Payload/NBTAimlock.app` → `nbtaimlock-release-unsigned.ipa`
- gate bằng `verify_unsigned_ipa.py`
- upload artifact `nbtaimlock-unsigned-ipa`

Bước này **bắt buộc** nếu bạn muốn bản build từ Swift source thay vì binary
native đang đóng gói sẵn. Máy Windows không thể biên dịch Swift cho iOS.

### 5.1. Đã build thành công bản Swift thật (12/11/2026)

Lần build macOS đầu tiên đã lộ ra lỗi cú pháp thật trong source
(`NABATICrypto.swift:101` viết `with ""` thiếu dấu `:` → `expected ',' separator`).
Điều này xác nhận source Swift trước đó **chưa từng được biên dịch**. Sau khi sửa:

- Binary: `1.079.024` bytes — `MH_MAGIC_64`, arm64, `MH_EXECUTE`, minos `14.0.0`
- `__swift5_proto` / `__swift5_types` / `__swift5_fieldmd` / `__swift5_entry`: có đủ
- `LC_CODE_SIGNATURE`: **không có** (unsigned đúng như thiết kế)
- `_CodeSignature/` · `embedded.mobileprovision` · `SC_Info`: **không có**
- 5 marker của app Objective-C cũ (`NABATIMainViewController`, `nbt_hwid_v5`,
  `nbt_key_v5`, `_apply_locked_ui`, `/api/license/authorize`): **tất cả vắng mặt**
- SHA-256 IPA: `d8a77fde8a56bc0a0739ab157506045a18bf4cb7466cdf23c83e976550f55085`
  (**đây là bản đang phục vụ trên production** — 3.009.444 bytes)

Cổng `verify_unsigned_ipa.py` in `build : swift` và **PASS** — không cần cờ
`--legacy-native`. Bản này đã gồm bộ bảo vệ liên tục (heartbeat 20 giây +
watchdog hạn 1 giây) và chặn cứng khi phát hiện app bị chỉnh sửa.

#### Bốn lỗi khóa-oan / mất dữ liệu đã sửa trong bản này

Cả bốn đều xảy ra với khách trả tiền mà không có lỗi gì từ phía họ (hai lỗi
đầu bắn trên iPhone hoàn toàn nguyên bản):

1. **Đổi bundle ID bị coi là "app bị chỉnh sửa".** ESign và Sideloadly đều đổi
   `CFBundleIdentifier` khi khách ký bằng chứng chỉ của mình — đúng như mục 3 và
   mục 4 của tài liệu này hướng dẫn, và Admin cũng có ô **Bundle ID** để nhập giá
   trị đó. Code cũ chặn trước khi gửi KEY, nên khách làm đúng hướng dẫn vẫn bị khóa.
   Nay cảnh báo vẫn được ghi log nhưng **không chặn**.
2. **Allowlist dylib thiếu đường dẫn cryptex.** Từ iOS 16 phần lớn hệ điều hành
   nằm trong cryptex và dyld báo đường dẫn `/private/preboot/Cryptexes/...` thay
   vì `/System/Library/...`. Allowlist cũ coi đó là "dylib lạ" → khóa máy nguyên bản.
   Đã bổ sung `/private/preboot/cryptexes/` và `/system/cryptexes/`.
3. **Mất mạng / bảo trì làm mất bộ độ nhạy đã chỉnh.** Hai nhánh heartbeat cũ
   gọi `resetPresetToDefault()` khi máy chủ bảo trì hoặc khi đủ 3 lần mất kết nối —
   khóa phiên là đúng nhưng đồng thời xóa luôn bộ độ nhạy khách đã chỉnh và lưu
   xuống UserDefaults. Nay chỉ khóa phiên, giữ nguyên dữ liệu khách.
4. **Đổi thiết bị oan sau khi ký lại / nâng cấp (HWID).** Bản Objective-C cũ và
   bản Swift dùng **cùng** keychain service `com.nbtaimlock.ios.vault` nhưng
   **khác tên account** (`nbt_hwid_v5` so với `nbt_secure_hwid_v4`), và bản Swift
   lại không đọc `NSUserDefaults`. Hệ quả: khách nâng cấp từ bản cũ — kể cả khi
   **không** ký lại — đọc thấy vault rỗng nên sinh HWID mới; nếu KEY đã chạm trần
   thiết bị thì bị `KEY_DA_GAN_THIET_BI` dù máy hoàn toàn nguyên bản. ESign /
   Sideloadly còn làm nặng thêm: chúng cấp **keychain access group khác** nên mọi
   item trong Keychain biến mất sau khi ký lại.

   Nay `getOrCreateHardwareUUID()` đọc theo thứ tự **ưu tiên giữ nguyên danh tính**:
   account cũ `nbt_hwid_v5` → bản sao trong `NSUserDefaults` → account của bản này
   → `identifierForVendor` (gắn với team + bundle ID, không phụ thuộc keychain nên
   sống sót qua ký lại) → UUID ngẫu nhiên. Danh tính sau khi giải được **ghi lại
   vào `NSUserDefaults`**, nơi ESign không xóa được, nên lần ký lại sau vẫn giữ
   nguyên thiết bị. Session token và KEY cũng đọc được từ account cũ, nên nâng
   cấp không bắt khách nhập lại KEY.

   Phía máy chủ **không đổi**: vẫn cùng cơ chế gắn thiết bị, cùng giới hạn, cùng
   mã lỗi. Chỉ client thôi trình một danh tính mới cho một thiết bị cũ.

   Kèm theo: khi bị chặn vì giới hạn thiết bị, app nay nói rõ cách xử lý
   (Admin → tab Keys → mở KEY → **📱 Gỡ 1 thiết bị**) và in ra HWID của chính máy
   để hỗ trợ đối chiếu. Trước đây khách chỉ thấy câu báo lỗi chung, không có lối ra.

Bằng chứng inject dylib (`RUNTIME_INJECTION_FRAMEWORKS_FOUND`,
`UNAUTHORIZED_RUNTIME_DYLIB_LOADED`) **vẫn chặn cứng** như trước.

> Nếu gặp `The configuration 'macos-14-arm64-us-default' is not supported`:
> tài khoản GitHub free không được cấp runner `macos-14`. Dùng `macos-15`
> (đã kiểm thử: `macos-15` và `macos-latest` chạy được, `macos-14` bị từ chối).

### 5.2. Bổ sung đầy đủ chức năng web vào bản source

> **Trạng thái:** source đã hoàn chỉnh, đã build thật thành công — xem mục 5.3.
> Bản IPA mới **chưa** được ký, **chưa** phát hành; production vẫn là bản 5.1.

**Nguyên nhân mất giao diện "hỗ trợ kéo tâm":** `project.pbxproj` được viết tay,
không dùng `PBXFileSystemSynchronizedRootGroup`, và **9 file `.swift` có trên đĩa
nhưng không nằm trong app target** — Xcode bỏ qua hoàn toàn nên không biên dịch.
Toàn bộ màn hình dashboard, các module và phần lớn lớp mạng không có trong binary.
Đã thêm đủ 9 file; target nay biên dịch **22/22** file Swift.

Để lỗi này không tái diễn, `tools/check_swift_sources.py` đọc thẳng pbxproj và
**FAIL** nếu có file trên đĩa không được biên dịch (hoặc ngược lại). Cổng này
chạy trong CI trước bước build, kèm 4 unit test cho chính nó. CI còn chạy `tools/swift_syntax_check.py` — parser Swift thật (tree-sitter), bắt lỗi cú pháp mà đếm ngoặc không thấy; hiện **22/22 file parse sạch**. Toàn bộ suite hiện có **40 test** ở workspace đầy đủ (16 test chạy được trong repo chỉ chứa source iOS, 2 test bỏ qua vì thiếu fixture IPA và `worker.js`), trong đó `tests/test_api_contract.py` đối chiếu source với `worker.js`: mọi endpoint app gọi đều tồn tại, 8 mã chức năng khớp `DEFAULT_CONFIG`, các field phản hồi mà client parse vẫn được Worker trả về, và không có `Button` nào rỗng.

**Chức năng đã đưa vào để ngang hàng web:**

| Nhóm | Nội dung |
|---|---|
| Dashboard 4 tab | AIMLOCK · TỐI ƯU MÁY · ĐỘ NHẠY · KEY, đúng cấu trúc và copy của `public/index.html` |
| 8 module | feat_aim_1..4 + feat_dev_1..4, mỗi công tắc gọi `/api/license/authorize` (máy chủ quyết định) |
| Preset | Tiết kiệm pin / Cân bằng / Hiệu năng / Tùy chỉnh, kèm mô tả như web |
| Độ nhạy theo máy | `/api/sensitivity`, 3 mức, gợi ý dòng máy khi không tìm thấy, nút sao chép |
| Khóa thiết bị | `/api/lockout-status`: hiện số lần thử còn lại và đếm ngược từ mốc máy chủ |
| Tài liệu pháp lý | `/api/legal`: Giới thiệu · Hướng dẫn · Điều khoản · Bảo mật, đọc trong app |
| Thông báo | `/api/announcement` chạy chữ trên dashboard |
| Chào mừng | Hộp thoại sau khi mở khóa, có nút "Ẩn 2 giờ" (lưu UserDefaults) như web |

**Mã hóa / chống crack:**

- 13 chuỗi nhạy cảm (mọi endpoint, base URL, keychain service, platform) được
  XOR bằng keystream SHA-256, sinh vào `NABATIObfuscationTables.swift`; CI fail
  nếu bảng lệch với `tools/obfuscate_strings.py --check`.
- CI fail nếu còn `workers.dev` hoặc `"/api/` dạng plaintext trong source.
- Release config bật `COPY_PHASE_STRIP`, `DEPLOYMENT_POSTPROCESSING`,
  `STRIP_INSTALLED_PRODUCT`, `GCC_SYMBOLS_PRIVATE_EXTERN`, tắt testability.
- Kiểm tra jailbreak / inject dylib / debugger vẫn chặn cứng như bản 5.1.

**Lưu ý:** không có toolchain Swift trên máy Windows, nên trước mục 5.3 các
thay đổi chỉ qua kiểm tra tĩnh. Build thật chạy trên macOS runner qua workflow
`build-ios.yml`.


### 5.3. Đã build thật bản 22 file Swift (12/11/2026)

Workflow `build-ios.yml` chạy trên `macos-15`. Hai lần build liên tiếp đều
**16/16 bước PASS**:

1. commit `be8e568` / run
   [43214289005](https://github.com/thait2471-sys/nbtaimlock-ios-build/actions/runs/43214289005)
   — bản đầu tiên biên dịch đủ 22 file Swift.
2. commit `b288c82` / run
   [43216671300](https://github.com/thait2471-sys/nbtaimlock-ios-build/actions/runs/43216671300)
   — bản đang lưu ở mục này, đã gỡ host khỏi `Info.plist`.

Artifact tải về: `nbtaimlock-unsigned-ipa`.

| Hạng mục | Kết quả |
|---|---|
| Dung lượng IPA | 5.676.020 bytes (bản ObjC cũ 2.030.355 bytes) |
| SHA-256 | `eecc72c593a518968c486ed15e2d27faad1ae6b223713b268e5d11ed21fe77f2` |
| `verify_unsigned_ipa.py` | PASS — `build: swift`, min iOS 14.0.0, Mach-O 1.010.392 bytes, 10 zip entry |
| Assets | `Assets.car` + 2 icon prefix (`AppIcon60x60@2x`, `AppIcon76x76@2x~ipad`) |
| Bundle | `com.nbtaimlock.ios` 4.2.0 (build 420), `CFBundleIconName=AppIcon` |
| Endpoint trong binary | `/api/verify`, `/api/heartbeat`, `/api/license/authorize` = 0; `workers.dev`, `pages.dev` = 0 (đã XOR) |
| Symbol UI | `AimlockDashboardView`, `NABATIFeatureStore`, `NABATIAppIntegrity` có trong binary |

**Lỗi biên dịch đầu tiên đã sửa:** `NABATIAppIntegrity.swift` dùng `KERN_PID` —
hằng số Darwin không tồn tại. Lần build đầu fail đúng chỗ này; đổi sang
`KERN_PROC_PID` (mib `CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()`).

**Cổng CI bị "pass giả" đã sửa:** bước `Swift syntax parse` chạy `pip install`
trên python3 của runner macOS (PEP 668 — externally managed), pip từ chối cài,
tool in `SKIP` rồi exit 0. Nay cài vào `build/venv` nên grammar thật sự chạy.

**Chưa làm (cần bạn quyết định):**

- IPA này **chưa ký** — chỉ là đầu vào cho ESign/Sideloadly. Muốn bản cài trực
  tiếp phải chạy `sign-ios.yml` với chứng chỉ + provisioning profile.
- **Chưa** deploy, **chưa** đưa lên trang `/ios/`, **chưa** phát hành.
- `Info.plist` **không còn** `NSExceptionDomains`: ATS nay là mặc định chặn
  (`NSAllowsArbitraryLoads=false`, không domain nào), nên bundle không còn manh
  mối plaintext về host API. `check_swift_sources.py` fail nếu host quay lại.
  Đổi này **chưa** được thử trên iPhone thật — cần kiểm tra đăng nhập KEY và tải
  tài liệu pháp lý một lần trước khi phát hành.
- Chưa test cài/chạy trên iPhone thật (không có thiết bị trong phiên này).


## 6. Ký bằng GitHub Actions (khuyến nghị cho bản phát hành)

> **Đã thay đổi:** workflow ký cũ ký file IPA có sẵn trong repo. File đó là bản
> **Objective-C** (link `libobjc.A.dylib`, class `NABATIMainViewController`),
> trong khi mã nguồn trong repo là **Swift/SwiftUI**. Ký nó sẽ cho ra một IPA
> cài được nhưng **không phải app đang phát triển**. Vì vậy workflow hiện tại
> **biên dịch từ Xcode project rồi mới ký chính binary vừa build**.

Workflow `.github/workflows/sign-ios.yml` có 2 chế độ:

| `mode` | Kết quả |
|---|---|
| `installable` (mặc định) | build → strip chữ ký → ký bằng cert + profile → gate → upload IPA đã ký |
| `unsigned` | chỉ build + gate, không cần secret Apple |

Quy trình `installable`:

1. `xcodebuild` build `NBTAimlock.xcodeproj` với `CODE_SIGNING_ALLOWED=NO`.
2. Kiểm tra binary vừa build **có link Swift runtime** (`otool -L | grep Swift`).
   Không có Swift runtime → workflow dừng, không phát hành binary lạ.
3. Đóng gói `Payload/NBTAimlock.app` → IPA unsigned, gate bằng `verify_unsigned_ipa.py`.
4. Import `.p12`, chọn identity **đúng Team ID** (`IOS_TEAM_ID`), import profile.
5. Ký lại bằng `tools/sign_existing_ipa.sh` (ký nested code trước, app sau).
6. Gate bằng `validate_ios_release.py` — phải ra **INSTALLABLE CANDIDATE**.
7. Upload artifact `nbtaimlock-signed-ipa`.

Thêm 4 repository secrets:

| Secret | Nội dung |
|---|---|
| `IOS_CERT_P12_BASE64` | file `.p12` (cert + private key) mã hoá base64 |
| `IOS_CERT_PASSWORD` | mật khẩu của `.p12` |
| `IOS_PROVISIONING_PROFILE_BASE64` | file `.mobileprovision` mã hoá base64 |
| `IOS_TEAM_ID` | Apple Developer Team ID (10 ký tự, vd `A1B2C3D4E5`) |

Tạo base64 trên Windows (PowerShell):

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\cert.p12")) | Set-Clipboard
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\profile.mobileprovision")) | Set-Clipboard
```

Sau đó: **Actions → Build and sign iOS IPA → Run workflow** (mode `installable`).
Tải artifact `nbtaimlock-signed-ipa`. Nếu gate báo `REJECTED`, đọc các dòng
`[FAIL]` để biết chính xác lỗi cert/profile/binary.

> **Không** đưa `.p12` hay mật khẩu lên chat. Chỉ lưu trong GitHub Secrets.

### Gate chặn những gì

`tools/validate_ios_release.py` từ chối IPA nếu:

- thiếu `Payload/NBTAimlock.app/embedded.mobileprovision` hoặc profile hết hạn;
- profile là App Store (không có UDID, không enterprise) — không cài trực tiếp được;
- `application-identifier` của profile không khớp `com.nbtaimlock.ios` (hoặc wildcard);
- Mach-O thiếu `LC_CODE_SIGNATURE`, hoặc CodeDirectory có `CS_ADHOC`;
- hash SHA-256 của từng page không khớp (bắt được cả file bị sửa sau khi ký);
- slot CMS không phải DER SignedData thật (bắt được "chữ ký" chỉ là stub);
- Team ID của chữ ký khác Team ID của profile;
- archive có entry `__MACOSX` / `._*`;
- binary **không link Swift runtime** trong khi source là Swift (bắt được bản cũ).


## 7. Phát hành OTA sau khi có IPA đã ký

1. Vào Admin → **Update & Maintenance** → **Phiên bản mới** → chọn **iOS (IPA)**.
2. Bấm **📤 Tải file lên máy chủ** và chọn file `.ipa` đã ký (tối đa 24 MB).
   Hệ thống lưu file trong kho riêng, tự điền **Link tải**, **SHA-256**, **Dung lượng**,
   đồng thời đọc `CFBundleShortVersionString` / `CFBundleVersion` từ chính file để
   điền **Phiên bản** và **Build** nếu bạn chưa nhập.
   (Nếu file lớn hơn 24 MB, host ở nơi khác rồi dán link HTTPS vào ô Link tải.)
3. Kiểm tra các ô trong form:
   - Version: `4.2.0` (**CFBundleShortVersionString**), Build: `420` (**CFBundleVersion**)
   - Bundle ID: ID thực tế trong bản đã ký (để trống = `com.nbtaimlock.ios`)
   - Download URL: URL HTTPS của file đã ký
   - SHA-256: mã SHA của file đã ký
   - Status: `published`
4. Manifest OTA: `https://nbtaimlockshopcom.thait2471.workers.dev/api/ios/install-manifest.plist`
   sẽ đọc đúng URL vừa phát hành.

> **Quan trọng — Build phải bằng `CFBundleVersion`.**
> Manifest OTA gửi `<key>bundle-version</key>` và Apple so khớp giá trị này với
> `CFBundleVersion` của binary (build number), **không** phải
> `CFBundleShortVersionString`. Nếu bạn publish Version `4.2.0` nhưng IPA ghi
> `CFBundleVersion = 420`, iOS trả đúng câu “Không thể cài đặt, vui lòng thử lại
> sau” mà không nêu lý do. Từ bản worker hiện tại, manifest tự ưu tiên
> `build_number` trong D1, và Admin tự đọc `CFBundleVersion` từ IPA rồi điền
> vào ô Build nếu bạn để trống.

> **Bundle ID cũng phải khớp.** Manifest gửi `<key>bundle-identifier</key>` và
> Apple so với `CFBundleIdentifier` trong binary. Nếu ESign/dịch vụ ký đổi
> bundle ID (ví dụ thêm hậu tố để tránh trùng), hãy nhập đúng ID đó vào ô
> **Bundle ID** — Admin cũng tự đọc từ IPA khi bạn tải file lên. Lệch ID cũng
> cho ra đúng câu “Không thể cài đặt, vui lòng thử lại sau”.

**Hiện tại bảng `platform_releases` không có bản ghi iOS nào**, nên manifest trả
`404 No published iOS release`. Đây là trạng thái **đúng**: phát hành IPA unsigned
qua OTA sẽ khiến mọi máy báo đúng lỗi “Không thể cài đặt”. Chỉ publish sau khi
`validate_ios_release.py` báo **INSTALLABLE CANDIDATE**.

## 7.1. Trang /ios/ tự nhận bản đã ký

Trang `https://nbtaimlockshopcom.thait2471.workers.dev/ios/` gọi
`/api/update-center` khi tải. Khi Admin publish một bản iOS:

- Nếu có bản published → trang hiện nút **“Cài trực tiếp trên iPhone”**
  (`itms-services://…install-manifest.plist`) và đổi nút tải thành “Tải IPA gốc (tự ký)”.
- Nếu chưa có bản nào → trang chỉ hiện bản unsigned kèm hướng dẫn ký (trạng thái hiện tại).

Admin cũng **phân tích thật file IPA** trước khi publish (tải file, đọc ZIP +
`Info.plist` + `embedded.mobileprovision` + Mach-O header ngay trên trình duyệt):

- Nếu IPA thiếu `embedded.mobileprovision`, binary chưa ký, profile hết hạn,
  `application-identifier` không khớp bundle ID, hoặc UDID máy không có trong
  profile → Admin liệt kê từng lỗi và hỏi lại trước khi phát hành.
- Nếu **Build number nhập tay khác `CFBundleVersion`** trong IPA → Admin cảnh
  báo và đề nghị dùng đúng giá trị trong file (đây chính là nguyên nhân phổ biến
  nhất của lỗi “Không thể cài đặt”).
- Nếu để trống ô Build, Admin tự điền `CFBundleVersion` đọc từ IPA.
- Nếu để trống ô **Bundle ID**, Admin tự điền `CFBundleIdentifier` đọc từ IPA;
  nếu bạn nhập khác với file, Admin cảnh báo và đề nghị dùng đúng giá trị trong file.

Cùng công cụ đó có sẵn cho người dùng cuối ở mục **“Chẩn đoán cài đặt”** trên
trang `/ios/`: chọn file `.ipa` đã ký, trình duyệt đọc trực tiếp trên máy
(**file không được tải lên máy chủ**) và trả về danh sách lỗi cụ thể.

> Muốn kiểm tra file trước khi publish mà không tải lên máy chủ: bấm
> **🧪 Phân tích file trên máy** ngay dưới ô Link tải. Công cụ đọc ZIP, Info.plist,
> `embedded.mobileprovision`, chữ ký Mach-O, hạn profile và danh sách icon ngay
> trong trình duyệt, rồi tự điền Build / Bundle ID. Nếu file nằm ở host ngoài,
> đây là cách duy nhất kiểm tra được (trình duyệt bị CSP/CORS chặn đọc file khác
> nguồn, nên hệ thống không thể tự tải link ngoài để phân tích).

> `App/Info.plist` phải giữ định dạng **XML** (không phải binary plist) để Xcode và
> các cổng kiểm tra đọc được. Test `IOS-NATIVE-09` sẽ fail nếu file bị chuyển sang binary.

## 8. Nếu vẫn báo “Không thể cài đặt”

Kiểm tra theo thứ tự:

- **Chứng chỉ hết hạn / bị thu hồi** → tạo cert mới.
- **UDID chưa có trong profile** (development/ad-hoc) → thêm UDID hoặc dùng enterprise cert.
- **App ID không khớp**: profile là `com.abc.xyz` nhưng app là `com.nbtaimlock.ios` → dùng
  profile đúng hoặc wildcard.
- **Không mở được app / app tự đóng ngay khi vào**: gần như luôn là profile không khớp
  hoặc cert bị thu hồi. Cài bằng Sideloadly để xem log, hoặc thử một chứng chỉ khác.
  (Lưu ý: app **không** khóa vì bundle ID bị đổi — xem mục 5.1.)
- **Profile không được nhúng**: sau khi ký, IPA phải có
  `Payload/NBTAimlock.app/embedded.mobileprovision`.
- **iPhone chạy iOS < 14.0** → app yêu cầu iOS 14.0 trở lên.
- **Còn app cũ cùng bundle id** → xoá app cũ rồi cài lại.
- **Dùng “Sign only” của ESign mà không chọn profile** → chọn đầy đủ cert + profile.
- **Bundle ID bị đổi khi ký** → nhập đúng ID trong ô **Bundle ID** của Admin
  (hoặc để trống để dùng `com.nbtaimlock.ios`). Manifest cũ và app lệch ID cũng
  báo đúng lỗi này.
- **Build number trong Admin lệch `CFBundleVersion`** → manifest OTA gửi sai
  version. Dùng mục **Chẩn đoán cài đặt** trên `/ios/` để đọc đúng giá trị
  `CFBundleVersion` của file rồi nhập lại.

Cách nhanh nhất để biết file của bạn hỏng ở đâu: mở
`https://nbtaimlockshopcom.thait2471.workers.dev/ios/` → mục **“Chẩn đoán cài
đặt”** → chọn file `.ipa` đã ký. Trang chạy hoàn toàn trong trình duyệt, không
upload file, và chỉ ra chính xác: bundle ID, UDID, hạn profile, chữ ký binary,
`CFBundleVersion`…

Chẩn đoán trên macOS:

```bash
python3 tools/validate_ios_release.py /path/to/signed.ipa                        # bản đã ký, bản Swift
python3 tools/validate_ios_release.py --legacy-native /path/to/signed.ipa        # bản đã ký, app native
python3 tools/verify_unsigned_ipa.py --legacy-native /path/to/unsigned.ipa       # bản unsigned, app native
python3 tools/verify_unsigned_ipa.py /path/to/unsigned.ipa                       # bản unsigned, bản Swift
```

Nếu là app native Objective-C mà chạy **không** có `--legacy-native`, cổng sẽ báo
`FAIL: binary has no Swift runtime or __swift5 metadata`. Đó là hành vi đúng —
cổng đang bắt bạn xác nhận rõ mình đang đóng gói nhánh native đã được review,
thay vì im lặng nhận một binary lạ.

`tools/sign_existing_ipa.sh` tự đọc `CFBundleExecutable` và kiểm tra binary có
link `libswift` hay không rồi **tự chọn** cờ cho cổng cuối. Trước đây script gọi
cổng mà không có `--legacy-native`, nên mọi lần ký bản native đều kết thúc bằng
`REJECTED` ở bước cuối — nếu bạn không kiểm tra exit code thì vẫn tưởng là thành
công. Bây giờ cờ không còn phải nhớ tay, và cờ `--legacy-native` vẫn **không**
phải bỏ qua kiểm tra: cổng vẫn đối chiếu 5 dylib, 5 marker và minos 14.0.0.

`validate_ios_release.py` chỉ dành cho **bản đã ký**. Nếu chạy trên bản unsigned
nó sẽ báo `REJECTED` kèm ghi chú rằng đây là input sideload hợp lệ — dùng
`verify_unsigned_ipa.py` thay thế.

## 9. Giới hạn thực tế

Máy Windows hiện tại **không có** chứng chỉ Apple (`.p12`) và provisioning profile,
nên không thể tạo IPA đã ký Apple ngay tại đây. Bản đã deploy là IPA unsigned sạch —
đúng định dạng để ESign/Sideloadly ký. Việc ký cuối cùng bắt buộc dùng chứng chỉ của
bạn (hoặc chạy workflow GitHub Actions ở mục 6).

## 10. Ghi chú kỹ thuật về hai nhánh mã nguồn

- **Binary đang đóng trong IPA đang phát hành trên server**: **bản Swift** (xem
  mục 5.1). Bản Objective-C cũ (`scratch/nabati_ios_native_v2.c`, 87.280 bytes)
  không còn được phục vụ và chỉ còn giá trị tham khảo: nó chỉ làm đúng hai việc —
  nhập KEY, xác thực với máy chủ (`/api/verify`), heartbeat 45 giây
  (`/api/heartbeat`), lưu session trong Keychain. Không có tính năng can thiệp game.
  Binary đó **không** link Swift runtime, nên nếu ai đóng gói lại nó thì mọi cổng
  kiểm tra phải chạy kèm `--legacy-native` (mục 8).
- **Swift source** trong `05_IOS_IPA_SOURCE/NBTAimlock/`: UI SwiftUI đầy đủ hơn,
  build bằng workflow `build-ios.yml`. Các toggle “Aimlock / Recoil / Anti-Cheat”
  giả đã được **loại bỏ**; phần thay thế là bộ **độ nhạy gợi ý** lưu cục bộ và sao
  chép vào clipboard để người dùng tự nhập trong Cài đặt của game.
  Bản Swift đã build (mục 5.1) và **đang phục vụ trên production**.
