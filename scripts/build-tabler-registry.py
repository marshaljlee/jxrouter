import os
import re

svg_paths = {
    'antenna.radiowaves.left.and.right': ('outline', 'antenna'),
    'app.fill': ('filled', 'apps'),
    'arrow.down.circle': ('outline', 'arrow-down-circle'),
    'arrow.triangle.2.circlepath': ('outline', 'refresh'),
    'arrow.triangle.branch': ('outline', 'git-branch'),
    'arrow.up': ('outline', 'arrow-up'),
    'bolt': ('outline', 'bolt'),
    'bolt.fill': ('filled', 'bolt'),
    'bolt.shield.fill': ('outline', 'shield-bolt'),
    'brain': ('outline', 'brain'),
    'brain.head.profile': ('outline', 'brain'),
    'bubble.left.and.bubble.right.fill': ('filled', 'messages'),
    'chart.bar.fill': ('outline', 'chart-bar'),
    'checkmark': ('outline', 'check'),
    'checkmark.circle.fill': ('filled', 'circle-check'),
    'chevron.down': ('outline', 'chevron-down'),
    'chevron.right': ('outline', 'chevron-right'),
    'chevron.up.chevron.down': ('outline', 'selector'),
    'circle.fill': ('filled', 'circle'),
    'circle.grid.3x3': ('outline', 'grid-dots'),
    'circle.lefthalf.filled': ('outline', 'circle-half-2'),
    'clock.arrow.circlepath': ('outline', 'history'),
    'cloud': ('outline', 'cloud'),
    'cloud.fill': ('filled', 'cloud'),
    'cpu': ('outline', 'cpu'),
    'cpu.fill': ('outline', 'cpu'),
    'cube.fill': ('outline', 'cube'),
    'desktopcomputer': ('outline', 'device-desktop'),
    'doc.fill': ('filled', 'file'),
    'doc.on.doc': ('outline', 'copy'),
    'doc.text': ('outline', 'file-text'),
    'exclamationmark.triangle': ('outline', 'alert-triangle'),
    'exclamationmark.triangle.fill': ('filled', 'alert-triangle'),
    'eye': ('outline', 'eye'),
    'eye.fill': ('filled', 'eye'),
    'eye.slash': ('outline', 'eye-off'),
    'face.smiling': ('outline', 'mood-smile'),
    'flame': ('outline', 'flame'),
    'fleuron': ('outline', 'sparkles'),
    'folder': ('outline', 'folder'),
    'folder.fill': ('filled', 'folder'),
    'gearshape.2': ('outline', 'settings-2'),
    'gearshape.2.fill': ('outline', 'settings-2'),
    'gearshape.fill': ('filled', 'settings'),
    'hammer.fill': ('outline', 'hammer'),
    'info.circle': ('outline', 'info-circle'),
    'key': ('outline', 'key'),
    'link': ('outline', 'link'),
    'link.circle.fill': ('outline', 'link'),
    'list.bullet.rectangle.portrait': ('outline', 'list-details'),
    'lock.shield.fill': ('filled', 'shield-lock'),
    'logo.github': ('outline', 'brand-github'),
    'magnifyingglass': ('outline', 'search'),
    'memorychip': ('outline', 'device-sd-card'),
    'minus.circle': ('outline', 'circle-minus'),
    'moon.fill': ('filled', 'moon'),
    'network': ('outline', 'network'),
    'paperclip': ('outline', 'paperclip'),
    'person.2.fill': ('outline', 'users'),
    'person.fill': ('filled', 'user'),
    'play.fill': ('filled', 'player-play'),
    'plus': ('outline', 'plus'),
    'point.3.connected.trianglepath.dotted': ('outline', 'triangle-square-circle'),
    'puzzlepiece.extension': ('outline', 'puzzle'),
    'questionmark.circle': ('outline', 'help-circle'),
    'server.rack': ('outline', 'server'),
    'shippingbox': ('outline', 'package'),
    'sidebar.left': ('outline', 'layout-sidebar'),
    'sparkle': ('outline', 'sparkles'),
    'sparkle.magnifyingglass': ('outline', 'search'),
    'sparkles': ('outline', 'sparkles'),
    'square.on.square': ('outline', 'copy'),
    'square.stack.3d.up': ('outline', 'stack-2'),
    'star.fill': ('filled', 'star'),
    'stop.fill': ('filled', 'player-stop'),
    'sun.max.fill': ('filled', 'sun'),
    'terminal.fill': ('outline', 'terminal-2'),
    'text.alignleft': ('outline', 'align-left'),
    'text.bubble': ('outline', 'message'),
    'text.bubble.fill': ('filled', 'message'),
    'trash': ('outline', 'trash'),
    'trash.fill': ('filled', 'trash'),
    'triangle.lequalspath.fill': ('outline', 'math-equal-greater'),
    'x.squareroot': ('outline', 'square-root-2'),
    'xmark': ('outline', 'x'),
    'xmark.circle.fill': ('filled', 'circle-x'),
    'z.square': ('outline', 'square-letter-z')
}

outline_dir = '/tmp/tabler-icons/icons/outline'
filled_dir = '/tmp/tabler-icons/icons/filled'

entries = []
for sym, (sub, name) in sorted(svg_paths.items()):
    p = os.path.join(outline_dir if sub == 'outline' else filled_dir, f'{name}.svg')
    raw = open(p).read()
    # Strip XML comments
    clean_svg = re.sub(r'<!--.*?-->', '', raw, flags=re.DOTALL).strip()
    # Replace currentColor with black so template rendering works deterministically
    clean_svg = clean_svg.replace('currentColor', 'black')
    # Collapse multiple whitespaces and linebreaks
    clean_svg = ' '.join(clean_svg.split())
    # Escape quotes for swift string literal
    escaped = clean_svg.replace('\\', '\\\\').replace('"', '\\"')
    entries.append(f'        "{sym}": "{escaped}"')

swift_code = f"""//
//  TablerIcons.swift
//  JXRouter
//
//  Generated authentic Tabler Icons (https://github.com/tabler/tabler-icons)
//  Clean vector template rendering replacing SF Symbols across the application.
//

import AppKit
import SwiftUI

public enum TablerIcons {{
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    /// Static SVG definitions for Tabler Icons mapped by canonical symbol key.
    public static let svgs: [String: String] = [
{",\n".join(entries)}
    ]

    /// Retrieves or rasterizes the vector Tabler icon as an NSImage template.
    public static func image(named name: String) -> NSImage? {{
        lock.lock()
        defer {{ lock.unlock() }}

        if let cached = cache[name] {{
            return cached
        }}

        guard let svgString = svgs[name] ?? svgs[fallback(for: name)],
              let data = svgString.data(using: .utf8),
              let img = NSImage(data: data) else {{
            return nil
        }}

        img.isTemplate = true
        cache[name] = img
        return img
    }}

    /// Fallback resolution for variant suffixes or aliases
    private static func fallback(for name: String) -> String {{
        if name.hasSuffix(".fill") {{
            let base = String(name.dropLast(5))
            if svgs[base] != nil {{ return base }}
        }}
        return name
    }}
}}

/// SwiftUI drop-in replacement for Image(systemName: ...) backed by authentic Tabler Icons.
public struct TablerIcon: View {{
    public let name: String
    public let fallbackSymbol: String
    public var isResizable: Bool = true
    public var contentMode: ContentMode = .fit
    public var pointSize: CGFloat? = nil

    public init(_ name: String, size: CGFloat? = nil, fallback: String? = nil) {{
        self.name = name
        self.fallbackSymbol = fallback ?? name
        self.pointSize = size
    }}

    public var body: some View {{
        let dim = pointSize ?? 15.0
        if let nsImage = TablerIcons.image(named: name) {{
            Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .frame(width: dim, height: dim)
        }} else {{
            Image(systemName: fallbackSymbol)
                .font(.system(size: dim))
        }}
    }}

    public func resizable(capInsets: EdgeInsets = EdgeInsets(), resizingMode: Image.ResizingMode = .stretch) -> TablerIcon {{
        var copy = self
        copy.isResizable = true
        return copy
    }}

    public func aspectRatio(_ aspectRatio: CGFloat? = nil, contentMode: ContentMode) -> TablerIcon {{
        var copy = self
        copy.contentMode = contentMode
        return copy
    }}

    public func font(_ font: Font?) -> TablerIcon {{
        var copy = self
        if let font = font, let extracted = Self.extractFontSize(from: font) {{
            copy.pointSize = extracted
        }}
        return copy
    }}

    private static func extractFontSize(from font: Font) -> CGFloat? {{
        let mirror = Mirror(reflecting: font)
        guard let provider = mirror.children.first?.value else {{ return nil }}
        let pMirror = Mirror(reflecting: provider)
        guard let base = pMirror.children.first(where: {{ zsh.label == "base" }})?.value else {{ return nil }}
        let bMirror = Mirror(reflecting: base)
        if let size = bMirror.children.first(where: {{ zsh.label == "size" }})?.value as? CGFloat {{
            return size
        }}
        return nil
    }}
}}
"""

out_path = 'Sources/JXRouter/TablerIcons.swift'
with open(out_path, 'w') as f:
    f.write(swift_code)

print(f"Generated {out_path} with {len(entries)} icons.")
