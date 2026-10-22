import SwiftUI

@MainActor enum BrandAsset {
    static let image = Bundle.main.url(forResource: "AppIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    static let menuImage: NSImage? = {
        guard let image = image?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

struct BrandIcon: View {
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let image = BrandAsset.image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
