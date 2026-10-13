import AppKit
#if VIDEONOTES_ENHANCED
import WebKit
#endif

// MARK: - ClipboardManager

/// 剪贴板管理器
///
/// 使用 NSPasteboard 实现系统级剪贴板写入
/// 支持可读文本，以及增强版中的离线公式图片/富文本附件复制。
///
final class ClipboardManager {

    static let shared = ClipboardManager()

    private init() {}
#if VIDEONOTES_ENHANCED
    private var formulaRenderer: FormulaClipboardRenderer?
#endif

    // MARK: - Copy

    /// 复制文本到剪贴板
    /// - Parameter text: 要复制的文本
    func copy(text: String, completion: ((Bool) -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.copy(text: text, completion: completion) }
            return
        }
        let pb = NSPasteboard.general
#if VIDEONOTES_ENHANCED
        formulaRenderer?.cancel()
        if FormulaClipboardRenderer.containsMath(text) {
        ClipToastWindow.show(message: "正在把整段笔记排版为图片…")
        let clipboardRevision = pb.changeCount
        let renderer = FormulaClipboardRenderer()
        formulaRenderer = renderer
        renderer.render(text) { [weak self, weak renderer] image in
            guard let self, self.formulaRenderer === renderer else { completion?(false); return }
            self.formulaRenderer = nil
            guard pb.changeCount == clipboardRevision else { completion?(false); return }
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                ClipToastWindow.show(message: "图片排版未完成，请从历史记录重试复制")
                completion?(false)
                return
            }
            let renderedItem = NSPasteboardItem()
            renderedItem.setData(png, forType: .png)
            renderedItem.setData(tiff, forType: .tiff)
            // No public text flavor: iPad must receive the complete rendered
            // paragraph as an image rather than choosing its TeX/text source.
            renderedItem.setString(text, forType: NSPasteboard.PasteboardType("com.videonotes.math-source"))
            // Notes and other rich editors prefer RTFD. Give them the same
            // rendered image, not the plain-text approximation from above.
            let wrapper = FileWrapper(regularFileWithContents: png)
            wrapper.preferredFilename = "formula.png"
            let attachment = NSTextAttachment(fileWrapper: wrapper)
            attachment.bounds = NSRect(origin: .zero, size: image.size)
            let richImage = NSAttributedString(attachment: attachment)
            if let rtfd = try? richImage.data(from: NSRange(location: 0, length: richImage.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
                renderedItem.setData(rtfd, forType: .rtfd)
            }
            pb.clearContents()
            let copied = pb.writeObjects([renderedItem])
            ClipToastWindow.show(message: copied ? "整段笔记图片已复制，可到 iPad 粘贴" : "图片复制失败，请重试")
            completion?(copied)
        }
        return
        }
#endif
        let readable = MathClipboardText.convert(text)
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(readable, forType: .string)
        let attributed = NSAttributedString(string: readable, attributes: [
            .font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.black
        ])
        if let data = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            item.setData(data, forType: .rtf)
        }
        completion?(pb.writeObjects([item]))
    }

    // MARK: - Read

    /// 读取当前剪贴板内容
    func read() -> String? {
        return NSPasteboard.general.string(forType: NSPasteboard.PasteboardType("com.videonotes.math-source"))
            ?? NSPasteboard.general.string(forType: .string)
    }
}

#if VIDEONOTES_ENHANCED
/// Renders real TeX with bundled MathJax SVG fonts, entirely offline. Nothing
/// from the source can become executable HTML, and external navigation is denied.
final class FormulaClipboardRenderer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var completion: ((NSImage?) -> Void)?
    private var timeout: DispatchWorkItem?

    static func containsMath(_ text: String) -> Bool {
        text.contains("$$") || text.contains("\\(") || text.contains("\\[") ||
        text.range(of: #"\\(?:frac|dfrac|tfrac|sqrt|int|sum|begin|lim)\b|\$[^$\n]*[A-Za-z\\^_=][^$\n]*\$"#,
                   options: .regularExpression) != nil
    }

    func render(_ source: String, completion: @escaping (NSImage?) -> Void) {
        self.completion = completion
        guard let url = Bundle.main.url(forResource: "tex-svg-full", withExtension: "js", subdirectory: "MathJax"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let markdownURL = Bundle.main.url(forResource: "markdown-it.min", withExtension: "js", subdirectory: "MathJax"),
              let markdownScript = try? String(contentsOf: markdownURL, encoding: .utf8) else { finish(nil); return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "formulaReady")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        let host = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = view
        window = host
        var content = ClipboardInputText.normalizedLineBreaks(source)
        if !source.contains("$") && !source.contains("\\(") && !source.contains("\\[") {
            content = "\\[" + content + "\\]"
        }
        let encoded = Data(content.utf8).base64EncodedString()
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'">
        <style>
        html,body{margin:0;background:white;color:#111}
        body{display:inline-block;padding:28px;font:22px/1.7 -apple-system,serif;}
        #content{width:760px;overflow-wrap:anywhere;white-space:normal;}
        h1,h2,h3,h4,h5,h6{line-height:1.4;margin:0 0 18px;font-weight:700;}
        h1{font-size:30px}h2{font-size:28px}h3{font-size:25px}h4,h5,h6{font-size:23px}
        p{margin:0 0 14px;}ul,ol{margin:8px 0 18px;padding-left:32px;}
        li{padding-left:6px;margin:10px 0;}li>p{margin:8px 0;}
        li>ul,li>ol{margin-top:12px;}strong{font-weight:700;}
        blockquote{margin:16px 0;padding-left:18px;border-left:3px solid #ccc;}
        pre{white-space:pre-wrap;padding:12px;background:#f5f5f5;}code{font-size:0.9em;}
        table{border-collapse:collapse;width:100%;margin:16px 0;font-size:19px;}
        th,td{border:1px solid #ccc;padding:8px;text-align:left;vertical-align:top;}
        mjx-container{white-space:normal;}mjx-container[display=true]{margin:16px 0!important;}
        #content>:last-child{margin-bottom:0;}
        </style>
        <script>window.MathJax={loader:{load:[]},tex:{inlineMath:[['$','$'],['\\\\(','\\\\)']],displayMath:[['$$','$$'],['\\\\[','\\\\]']],packages:{'[-]':['autoload','require']}},svg:{fontCache:'none'},startup:{typeset:false}};</script>
        <script>\(markdownScript)</script><script>\(script)</script></head><body><div id="content"></div>
        <script>
        const source=new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'),c=>c.charCodeAt(0))).replace(/\\r\\n?/g,'\\n');
        const formulas=[];
        const marker='VNFORMULA'+Math.random().toString(36).slice(2).toUpperCase();
        // Protect TeX before Markdown: underscores, asterisks and backslashes
        // belong to the formula, not to Markdown emphasis or escaping.
        const protectedSource=source.replace(/\\$\\$[\\s\\S]*?\\$\\$|\\\\\\[[\\s\\S]*?\\\\\\]|\\\\\\([\\s\\S]*?\\\\\\)|(?<!\\\\)\\$[^\\n$]+?(?<!\\\\)\\$/g,math=>{
          const token=marker+formulas.length+'END';
          formulas.push(math);return token;
        });
        let markup=markdownit({html:false,breaks:true,linkify:false,typographer:false}).render(protectedSource);
        const escapeHTML=s=>s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
        formulas.forEach((math,i)=>{
          // Some AI copy outputs double-escape spacing commands. Correct only
          // these spacing escapes, retaining real matrix/aligned row breaks.
          math=math.replace(/\\\\\\\\([,;! ])/g,'\\\\$1');
          markup=markup.split(marker+i+'END').join(escapeHTML(math));
        });
        document.getElementById('content').innerHTML=markup;
        MathJax.startup.promise.then(()=>MathJax.typesetPromise()).then(()=>{
          if(document.querySelector('mjx-merror') || !document.querySelector('mjx-container svg')) throw Error('Invalid formula');
          const box=document.body.getBoundingClientRect();
          window.webkit.messageHandlers.formulaReady.postMessage({width:Math.ceil(Math.max(box.width,document.body.scrollWidth)),height:Math.ceil(Math.max(box.height,document.body.scrollHeight))});
        }).catch(()=>window.webkit.messageHandlers.formulaReady.postMessage({error:true}));</script>
        </body></html>
        """
        let deadline = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
        view.loadHTMLString(html, baseURL: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let size = message.body as? [String: Any], size["error"] == nil,
              let width = size["width"] as? Double, let height = size["height"] as? Double,
              width > 0, height > 0, width <= 3000, height <= 12000,
              let view = webView else { finish(nil); return }
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window?.setContentSize(view.frame.size)
        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = view.bounds
        snapshot.snapshotWidth = NSNumber(value: width * 2)
        view.takeSnapshot(with: snapshot) { [weak self] image, error in
            self?.finish(error == nil ? image : nil)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }

    func cancel() { finish(nil) }

    private func finish(_ image: NSImage?) {
        timeout?.cancel(); timeout = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "formulaReady")
        webView?.stopLoading()
        webView = nil
        window?.close(); window = nil
        let callback = completion
        completion = nil
        callback?(image)
    }
}
#endif

/// Recover paragraph breaks from rich clipboard data only when its formulas
/// still match the plain source. Never substitute rendered/flattened math.
enum ClipboardInputText {
    static func normalizedLineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n\n")
    }

    static func read(from pasteboard: NSPasteboard) -> String? {
        if let source = pasteboard.string(forType: NSPasteboard.PasteboardType("com.videonotes.math-source")) { return normalizedLineBreaks(source) }
        let plain = pasteboard.string(forType: .string).map(normalizedLineBreaks)
        if let plain, plain.contains("\n") || plain.contains("\r") { return plain }
        for (type, documentType) in [(NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf), (.html, .html)] {
            guard var data = pasteboard.data(forType: type) else { continue }
            if type == .html {
                guard var html = String(data: data, encoding: .utf8) else { continue }
                html = restoreTeXAnnotations(in: html)
                // The HTML importer needs no remote resources or styling.
                for pattern in [#"(?is)<(script|style|iframe|object)[\s\S]*?</\1\s*>"#,
                                #"(?is)<(img|link|base|embed)\b[^>]*>"#,
                                #"(?is)\s(?:src|href|style)\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#] {
                    html = html.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                }
                data = Data(html.utf8)
            }
            guard let rich = try? NSAttributedString(data: data,
                options: [.documentType: documentType, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil) else { continue }
            let restored = normalizedLineBreaks(rich.string)
            guard restored.contains("\n"), !restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let plain {
                // Paragraph recovery must never remove any original text or
                // TeX. Compare content independently of whitespace.
                let compact: (String) -> String = { $0.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression) }
                let withoutListMarkers = restored.replacingOccurrences(
                    of: #"(?m)^\s*(?:[•◦○●▪]|\d+[.)])\s+"#, with: "", options: .regularExpression)
                guard compact(plain) == compact(restored) || compact(plain) == compact(withoutListMarkers) else { continue }
            }
            return restored
        }
        return plain
    }

    /// AI web pages often copy a KaTeX tree with visible glyphs plus a hidden
    /// TeX annotation. Replace the whole formula subtree with that annotation
    /// before importing HTML, otherwise the importer duplicates or flattens it.
    private static func restoreTeXAnnotations(in html: String) -> String {
        guard let tags = try? NSRegularExpression(pattern: #"<(/?)([A-Za-z][\w:-]*)\b[^>]*>"#),
              let annotation = try? NSRegularExpression(pattern: #"(?is)<annotation\b[^>]*encoding\s*=\s*["']application/x-tex["'][^>]*>([\s\S]*?)</annotation\s*>"#) else { return html }
        let ns = html as NSString
        var stack: [(name: String, start: Int, math: Bool, display: Bool)] = []
        var replacements: [(NSRange, String)] = []
        for tag in tags.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: tag.range(at: 2)).lowercased()
            let fullTag = ns.substring(with: tag.range)
            if ns.substring(with: tag.range(at: 1)) == "/" {
                guard let position = stack.lastIndex(where: { $0.name == name }) else { continue }
                let frame = stack[position]
                stack.removeSubrange(position...)
                guard frame.math else { continue }
                let range = NSRange(location: frame.start, length: NSMaxRange(tag.range) - frame.start)
                let fragment = ns.substring(with: range)
                guard let match = annotation.firstMatch(in: fragment, range: NSRange(location: 0, length: (fragment as NSString).length)) else { continue }
                let tex = (fragment as NSString).substring(with: match.range(at: 1))
                let delimiter = frame.display ? "$$" : "$"
                replacements.removeAll { NSLocationInRange($0.0.location, range) }
                replacements.append((range, delimiter + tex + delimiter))
            } else {
                if ["br", "img", "input", "meta", "link", "hr", "source", "wbr", "base", "embed", "area", "col", "param"].contains(name) || fullTag.hasSuffix("/>") { continue }
                let math = name == "math" || name == "mjx-container" || fullTag.range(of: #"(?i)class\s*=\s*["'][^"']*\bkatex\b"#, options: .regularExpression) != nil
                let display = fullTag.contains("katex-display") || fullTag.contains("display=\"block\"")
                stack.append((name, tag.range.location, math, display))
            }
        }
        let output = NSMutableString(string: html)
        for (range, value) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            output.replaceCharacters(in: range, with: value)
        }
        return output as String
    }
}

/// Plain-text fallback for destinations that cannot insert formula images.
/// Saved notes keep their TeX source; unknown constructs remain visible.
enum MathClipboardText {
    static func convert(_ source: String) -> String {
        var fenced = false
        var pending: [String] = []
        var output: [String] = []
        for line in source.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !pending.isEmpty { output.append(convertContent(pending.joined(separator: "\n"))) }
                pending.removeAll()
                fenced.toggle()
                output.append(line)
            } else if fenced { output.append(line) }
            else { pending.append(line) }
        }
        if !pending.isEmpty { output.append(convertContent(pending.joined(separator: "\n"))) }
        return output.joined(separator: "\n")
    }

    private static func convertContent(_ source: String) -> String {
        guard source.contains("\\") || source.contains("$") else { return source }
        // Only remove delimiters around recognisable math. Currency stays intact.
        let pattern = #"\\\[([\s\S]*?)\\\]|\\\(([\s\S]*?)\\\)|\$\$([\s\S]*?)\$\$|\$([^\n$]+)\$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            let contentRange = (1..<match.numberOfRanges).map { match.range(at: $0) }
                .first { $0.location != NSNotFound }!
            guard let range = Range(contentRange, in: source), let whole = Range(match.range, in: result) else { continue }
            let content = String(source[range])
            guard content.contains("\\") || content.contains("^") || content.contains("_") ||
                    content.contains("=") || content.range(of: "[A-Za-z]", options: .regularExpression) != nil else { continue }
            result.replaceSubrange(whole, with: Parser(content).parse())
        }
        // AI often omits delimiters. Convert command-bearing lines, but leave
        // ordinary prose, paths and fenced code alone.
        return result.components(separatedBy: "\n").map { line in
            guard line.contains("\\") else { return line }
            return Parser(line).parse()
        }.joined(separator: "\n")
    }

    private final class Parser {
        let chars: [Character]
        var index = 0
        init(_ text: String) { chars = Array(text) }

        func parse(until closing: Character? = nil) -> String {
            var output = ""
            while index < chars.count {
                let c = chars[index]
                if c == closing { index += 1; break }
                index += 1
                if c == "\\" {
                    let start = index - 1
                    var command = ""
                    while index < chars.count, chars[index].isLetter { command.append(chars[index]); index += 1 }
                    if command.isEmpty {
                        if index < chars.count, ["%", "$", "{", "}", "_", " ", ",", ";", "!"].contains(chars[index]) {
                            let escaped = chars[index]; index += 1
                            output += [",", ";", "!"].contains(escaped) ? " " : String(escaped)
                        } else { output.append(c) }
                    } else if ["frac", "dfrac", "tfrac"].contains(command) {
                        let checkpoint = index
                        if let numerator = group(), let denominator = group() {
                            output += "(\(numerator))/(\(denominator))"
                        } else { index = checkpoint; output += String(chars[start..<index]) }
                    } else if command == "sqrt" {
                        let checkpoint = index
                        var degree: String?
                        if index < chars.count, chars[index] == "[" { index += 1; degree = parse(until: "]") }
                        if let value = group() {
                            output += degree == "3" ? "∛(\(value))" : degree == nil || degree == "2" ? "√(\(value))" : "root[\(degree!)](\(value))"
                        } else { index = checkpoint; output += String(chars[start..<index]) }
                    } else if ["text", "mathrm", "mathbf", "mathit", "operatorname"].contains(command) {
                        if let value = group() { output += value } else { output += "\\" + command }
                    } else if ["left", "right"].contains(command) {
                        if index < chars.count, chars[index] == "." { index += 1 }
                    } else if let symbol = Self.symbols[command] { output += symbol }
                    else { output += "\\" + command }
                } else if c == "^" || c == "_" {
                    let value: String
                    if let grouped = group() { value = grouped }
                    else if index < chars.count { value = String(chars[index]); index += 1 }
                    else { output.append(c); continue }
                    let map = c == "^" ? Self.superscripts : Self.subscripts
                    if value.allSatisfy({ map[$0] != nil }) { output += value.map { map[$0]! }.joined() }
                    else { output.append(c); output += "(" + value + ")" }
                } else { output.append(c) }
            }
            return output
        }

        func group() -> String? {
            let checkpoint = index
            while index < chars.count, chars[index].isWhitespace { index += 1 }
            guard index < chars.count, chars[index] == "{" else { index = checkpoint; return nil }
            // Do not consume malformed groups.
            var depth = 0
            var end = index
            while end < chars.count {
                if chars[end] == "{" { depth += 1 }
                if chars[end] == "}" { depth -= 1; if depth == 0 { break } }
                end += 1
            }
            guard depth == 0 else { index = checkpoint; return nil }
            index += 1
            var value = ""
            while index < end {
                // Parse nested groups without discarding their grouping.
                if chars[index] == "{" { index += 1; value += "(" + parse(until: "}") + ")" }
                else {
                    // Parse the remaining group in a child parser, preserving
                    // recursive fractions and roots.
                    let child = Parser(String(chars[index..<end]))
                    value += child.parse(); index = end
                }
            }
            index = end + 1
            return value
        }

        static let superscripts = Dictionary(uniqueKeysWithValues: zip(Array("0123456789+-=()in"), Array("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁱⁿ")).map { ($0, String($1)) })
        static let subscripts = Dictionary(uniqueKeysWithValues: zip(Array("0123456789+-=()aehijklm noprstuvx".replacingOccurrences(of: " ", with: "")), Array("₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ")).map { ($0, String($1)) })
        static let symbols: [String: String] = [
            "alpha":"α", "beta":"β", "gamma":"γ", "delta":"δ", "epsilon":"ε", "theta":"θ", "lambda":"λ", "mu":"μ", "nu":"ν", "xi":"ξ", "pi":"π", "rho":"ρ", "sigma":"σ", "tau":"τ", "phi":"φ", "omega":"ω", "Delta":"Δ", "Gamma":"Γ", "Sigma":"Σ", "Omega":"Ω", "Phi":"Φ", "Psi":"Ψ", "psi":"ψ", "varepsilon":"ε", "varphi":"φ",
            "times":"×", "cdot":"·", "div":"÷", "pm":"±", "mp":"∓", "le":"≤", "leq":"≤", "ge":"≥", "geq":"≥", "ne":"≠", "neq":"≠", "approx":"≈", "equiv":"≡", "infty":"∞", "to":"→", "rightarrow":"→", "Rightarrow":"⇒", "leftarrow":"←", "Leftrightarrow":"⇔", "in":"∈", "notin":"∉", "subset":"⊂", "subseteq":"⊆", "cup":"∪", "cap":"∩", "emptyset":"∅", "forall":"∀", "exists":"∃", "partial":"∂", "nabla":"∇", "int":"∫", "iint":"∬", "sum":"∑", "prod":"∏", "lim":"lim", "sin":"sin", "cos":"cos", "tan":"tan", "ln":"ln", "log":"log", "exp":"exp", "ldots":"…", "cdots":"⋯", "quad":" ", "qquad":"  "
        ]
    }
}
