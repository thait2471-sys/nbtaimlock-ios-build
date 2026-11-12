import SwiftUI
import WebKit

/// A published legal document: terms, privacy, about or guide.
///
/// `/api/legal?type=` is the same public, read-only endpoint the web client's
/// footer opens. The body is admin-authored HTML, so it is rendered in a
/// `WKWebView` with a dark stylesheet rather than parsed into SwiftUI `Text`
/// (which cannot represent headings, lists or emphasis).
/// `String` is not `Identifiable`, and `.sheet(item:)` needs one, so a document
/// type travels in this wrapper.
public struct NABATILegalSelection: Identifiable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct NABATILegalDocument {
    public let title: String
    public let html: String
    public let updatedLabel: String
    public let contact: String

    /// Fallback heading, used when the document has not been published yet and
    /// while the request is still in flight.
    public static func fallbackTitle(for type: String) -> String {
        switch type {
        case "terms":   return "ĐIỀU KHOẢN SỬ DỤNG"
        case "privacy": return "CHÍNH SÁCH BẢO MẬT"
        case "about":   return "GIỚI THIỆU"
        case "guide":   return "HƯỚNG DẪN SỬ DỤNG KEY"
        default:        return "TÀI LIỆU"
        }
    }
}

public enum NABATILegalError: Error, LocalizedError {
    case notPublished
    case unreachable

    public var errorDescription: String? {
        switch self {
        case .notPublished:
            return "Nội dung chưa được xuất bản. Vui lòng quay lại sau."
        case .unreachable:
            return "Không tải được nội dung. Vui lòng kiểm tra kết nối."
        }
    }
}

public enum NABATILegalClient {
    public static func fetch(type: String, completion: @escaping (Result<NABATILegalDocument, NABATILegalError>) -> Void) {
        NABATINetwork.shared.get(endpoint: NBTF.K.apiLegal, query: ["type": type]) { result in
            switch result {
            case .success(let json):
                guard (json["success"] as? Bool) == true,
                      (json["found"] as? Bool) == true,
                      let doc = json["doc"] as? [String: Any] else {
                    completion(.failure(.notPublished))
                    return
                }
                completion(.success(NABATILegalDocument(
                    title: (doc["title"] as? String) ?? NABATILegalDocument.fallbackTitle(for: type),
                    html: (doc["content"] as? String) ?? "",
                    updatedLabel: (doc["updated_label"] as? String) ?? "",
                    contact: (doc["contact"] as? String) ?? ""
                )))
            case .failure:
                completion(.failure(.unreachable))
            }
        }
    }
}

/// Dark-themed reader for one legal document, presented as a sheet.
public struct LegalDocumentView: View {
    public let type: String

    @Environment(\.presentationMode) private var presentationMode
    @State private var document: NABATILegalDocument? = nil
    @State private var errorText: String? = nil
    @State private var loading: Bool = true

    private var accent: Color { Color(red: 0/255, green: 243/255, blue: 255/255) }
    private var background: Color { Color(red: 6/255, green: 9/255, blue: 19/255) }

    public init(type: String) {
        self.type = type
    }

    private var heading: String {
        if let title = document?.title, !title.isEmpty { return title }
        return NABATILegalDocument.fallbackTitle(for: type)
    }

    public var body: some View {
        NavigationView {
            ZStack {
                background.ignoresSafeArea()

                if loading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: accent))
                        Text("Đang tải nội dung…")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                } else if let errorText = errorText {
                    VStack(spacing: 12) {
                        Text("⚠️")
                            .font(.system(size: 30))
                        Text(errorText)
                            .font(.system(size: 13))
                            .foregroundColor(Color(red: 248/255, green: 113/255, blue: 113/255))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(action: load) {
                            Text("THỬ LẠI")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 10)
                                .background(accent)
                                .cornerRadius(10)
                        }
                    }
                    .padding(24)
                } else if let document = document {
                    // The contact line is part of the wrapped HTML, so it
                    // scrolls with the document instead of floating in a
                    // separate band.
                    LegalWebView(html: LegalDocumentView.wrapped(document, type: type))
                }
            }
            .navigationBarTitle(Text(heading), displayMode: .inline)
            .navigationBarItems(trailing: Button(action: {
                presentationMode.wrappedValue.dismiss()
            }) {
                Text("Đóng")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accent)
            })
        }
        .onAppear(perform: load)
    }

    private func load() {
        loading = true
        errorText = nil
        NABATILegalClient.fetch(type: type) { result in
            loading = false
            switch result {
            case .success(let doc):
                document = doc
            case .failure(let error):
                errorText = error.errorDescription ?? "Không tải được nội dung."
            }
        }
    }

    /// The document is an HTML fragment authored in Admin. It is wrapped here so
    /// the reader matches the app's palette and its text is legible on a dark
    /// background — without that, the browser default renders black-on-black.
    static func wrapped(_ document: NABATILegalDocument, type: String) -> String {
        let updated = document.updatedLabel.isEmpty
            ? ""
            : "<p class=\"updated\">\(escape(document.updatedLabel))</p>"
        let heading = document.title.isEmpty
            ? LegalDocumentView.fallback(type: type)
            : escape(document.title)
        let body = document.html.isEmpty ? "<p>Chưa có nội dung.</p>" : document.html
        let contact = document.contact.isEmpty
            ? ""
            : "<p class=\"contact\">Liên hệ: \(escape(document.contact))</p>"
        return """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
          :root { color-scheme: dark; }
          body {
            margin: 0; padding: 18px 18px 34px;
            background: #060913;
            color: #c8d4e8;
            font-family: -apple-system, "SF Pro Text", system-ui, sans-serif;
            font-size: 14px; line-height: 1.7;
            -webkit-text-size-adjust: 100%;
          }
          h1, h2, h3, h4 { color: #ffffff; letter-spacing: .2px; }
          h1 { font-size: 21px; margin: 0 0 10px; }
          h2 { font-size: 16px; margin: 22px 0 8px; }
          h3 { font-size: 14.5px; margin: 18px 0 6px; }
          p { margin: 8px 0; }
          ul, ol { margin: 8px 0 8px 20px; padding: 0; }
          li { margin: 5px 0; }
          a { color: #00f3ff; text-decoration: none; }
          strong { color: #ffffff; }
          hr { border: 0; border-top: 1px solid rgba(255,255,255,.12); margin: 18px 0; }
          .updated { color: #5a6884; font-size: 11.5px; margin: 0 0 14px; }
          .contact { color: #5a6884; font-size: 12px; margin: 24px 0 0; }
          img { max-width: 100%; height: auto; }
        </style>
        </head><body>
        <h1>\(heading)</h1>
        \(updated)
        \(body)
        \(contact)
        </body></html>
        """
    }

    /// Titles and the contact line are admin-entered plain text, but they are
    /// interpolated into HTML — escape them so a stray `<` or `&` cannot break
    /// the page. `content` is intentionally left as authored HTML.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func fallback(type: String) -> String {
        NABATILegalDocument.fallbackTitle(for: type)
    }
}

/// `WKWebView` wrapper that loads the HTML only when it actually changes.
///
/// `updateUIView` runs on every SwiftUI render pass; reloading there would
/// reset the scroll position each time the parent updates.
private struct LegalWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        // The body is admin-authored HTML. Rendering it needs no scripting, so
        // JavaScript stays off: a compromised admin session then cannot run
        // code inside the app's reader. CSS and links keep working.
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        uiView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String? = nil

        /// A link in an admin document opens in Safari instead of replacing the
        /// reader — otherwise the customer loses the document and has no back
        /// button inside the sheet.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
