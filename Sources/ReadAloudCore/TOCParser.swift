// TOCParser: the top level of an EPUB's table of contents, as (name, link) pairs.
// Reads both kinds: EPUB 3's nav page (<nav epub:type="toc"><ol><li><a href>) and the
// older NCX file (<navMap><navPoint><navLabel><text>, <content src>). Only top-level
// entries: "Chapter 1: Don't Try", not the sections inside it.
import Foundation

final class TOCParser: NSObject, XMLParserDelegate {
    struct Entry { let title: String; let href: String }
    private var entries: [Entry] = []
    // NCX
    private var navPointDepth = 0
    private var inText = false
    private var pendingTitle = ""
    private var pendingHref = ""
    // nav
    private var inTOCNav = false
    private var navDepth = 0
    private var olDepth = 0
    private var inLink = false
    private var linkDepthOK = false

    static func topLevel(_ xml: String) -> [Entry] {
        // XML parsers choke on HTML entities like &nbsp;: swap the common ones first.
        var text = xml
        for (k, v) in ["&nbsp;": " ", "&mdash;": "-", "&ndash;": "-", "&rsquo;": "'", "&lsquo;": "'",
                       "&rdquo;": "\"", "&ldquo;": "\"", "&hellip;": "..."] {
            text = text.replacingOccurrences(of: k, with: v)
        }
        let p = TOCParser()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = p
        parser.parse()
        return p.entries.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let tag = name.lowercased()
        switch tag {
        case "navpoint":
            navPointDepth += 1
            if navPointDepth == 1 { pendingTitle = ""; pendingHref = "" }
        case "text" where navPointDepth == 1:
            inText = true
        case "content" where navPointDepth == 1 && pendingHref.isEmpty:
            pendingHref = attributes["src"] ?? ""
        case "nav":
            navDepth += 1
            let type = attributes["epub:type"] ?? attributes["type"] ?? ""
            if type.contains("toc") || (!inTOCNav && entries.isEmpty && type.isEmpty) { inTOCNav = true }
        case "ol" where inTOCNav:
            olDepth += 1
        case "a" where inTOCNav && olDepth == 1:
            inLink = true
            pendingTitle = ""
            pendingHref = attributes["href"] ?? ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText || inLink { pendingTitle += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let tag = name.lowercased()
        switch tag {
        case "text": inText = false
        case "navpoint":
            if navPointDepth == 1 { entries.append(Entry(title: pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines), href: pendingHref)) }
            navPointDepth -= 1
        case "a" where inLink:
            inLink = false
            entries.append(Entry(title: pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines), href: pendingHref))
        case "ol" where inTOCNav: olDepth -= 1
        case "nav":
            navDepth -= 1
            if inTOCNav && !entries.isEmpty { inTOCNav = false; parser.abortParsing() }
        default: break
        }
    }
}
