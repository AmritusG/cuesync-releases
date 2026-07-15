import SwiftUI
import AppKit

// MARK: - SVG Rendering Helper

/// Renders an SVG XML string to a SwiftUI Image via NSImage.
/// macOS natively supports SVG rendering through NSImage.
private func renderSVG(_ svg: String, size: CGSize) -> Image {
    guard let data = svg.data(using: .utf8),
          let nsImage = NSImage(data: data) else {
        return Image(systemName: "questionmark.circle")
    }
    nsImage.size = size
    return Image(nsImage: nsImage)
}

// MARK: - SVG String Constants
// Extracted directly from the Electron app's CueSync.jsx

private enum BrandSVG {

    static func rekordbox(color: String = "#e0e0e8") -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="150" height="150" viewBox="0 0 150 150" fill="\(color)">
          <path d="M105.006,81.466C105.437,72.853 105.433,72.89 103.797,64.444C103.339,62.081 104.235,62.321 106.257,61.102C110.19,58.731 113.691,56.614 114.338,56.223C124.789,49.907 127.626,47.556 127.711,50.466C127.805,53.683 127.659,97.417 127.645,101.5C127.594,116.865 123.795,115.899 110.674,123.796C75.42,145.016 73.49,147.841 72.96,144.443C72.916,144.164 73.082,121.486 73.097,119.49C73.15,112.219 98.079,118.106 105.006,81.466Z" transform="translate(0,10)"/>
          <path d="M58.576,34.975C35.847,40.243 38.779,49.942 33.456,47.588C28.342,45.326 14.316,36.27 12.691,35.221C9.412,33.104 14.074,33.316 53.361,8.264C66.429,-0.069 67.901,2.974 81.279,10.87C98.927,21.286 98.634,21.576 116.277,31.873C118.258,33.029 119.475,34.133 116.215,36.014C96.44,47.422 95.969,49.136 93.877,47.104C81.476,35.061 72.364,33.637 58.576,34.975Z" transform="translate(0,10)"/>
          <path d="M24.999,72.53C25.183,77.143 23.883,83.698 29.893,96.305C36.638,110.453 52.146,115.519 54.561,116.308C58.408,117.565 56.988,120.872 57.16,141.5C57.172,142.986 58.373,147.347 53.661,144.232C39.504,134.874 6.718,118.107 3.835,112.332C1.625,107.907 2.473,107.609 2.616,50.513C2.623,47.498 6.283,50.37 12.655,54.236C23.982,61.107 26.991,61.912 26.477,64.496C25.675,68.525 25.749,68.451 24.999,72.53Z" transform="translate(0,10)"/>
          <path d="M65.494,97.026C32.814,94.574 43.266,47.661 71.522,56.44C87.9,61.529 93.684,92.957 65.494,97.026Z" transform="translate(0,10)"/>
        </svg>
        """
    }

    static func serato(fgColor: String = "#ffffff", bgColor: String = "#1a1a2e") -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="135" height="135" viewBox="0 0 135 135">
          <circle cx="67.5" cy="67.5" r="66.5" fill="\(fgColor)"/>
          <circle cx="67.5" cy="67.5" r="60" fill="\(bgColor)"/>
          <path d="m116.8261 76.12984c-1.83412.00056-3.32228-1.48424-3.32588-3.31836v-10.5048c-.03293-1.45866.87311-2.77408 2.2477-3.26327 1.73938-.58846 3.62646.34455 4.21492 2.08393.11598.3428.1752.70225.17535 1.06414v10.62c.00068 1.83052-1.48157 3.31559-3.31209 3.31836" fill="\(fgColor)"/>
          <path d="m105.66388 87.09008c-.00819 2.02657-1.6577 3.6628-3.68427 3.65461-.54073-.00219-1.07428-.12385-1.5625-.35628-1.26659-.59086-2.06645-1.87214-2.04111-3.26953v-10.94559c-.01509-2.28357-1.87852-4.12254-4.16209-4.10745-2.26763.01498-4.1001 1.85356-4.10752 4.12123v26.2952c.02257 1.72868-1.06023 3.27907-2.691 3.85306-2.13928.76463-4.49336-.34975-5.258-2.48901-.13699-.38326-.21633-.7847-.23545-1.19124l-.00749-.18784v-8.00289c-.10468-2.52773-2.23867-4.492-4.7664-4.38731-.26611.01102-.53077.04523-.79094.10224-2.13165.51159-3.62104 2.43635-3.58131 4.62817v24.30418c.04697 2.53339-1.68507 4.75417-4.15361 5.32565-2.83054.59808-5.60998-1.21169-6.20806-4.04222-.07369-.34875-.11159-.7041-.11311-1.06055v-24.71112c-.01446-2.52628-2.07413-4.56253-4.60042-4.54807-2.45818.01407-4.46571 1.96844-4.54572 4.42535v7.96658l-.00627.15152c-.08072 2.25977-1.97806 4.02623-4.23782 3.94551-2.18513-.07805-3.92332-1.8593-3.94787-4.04568v-26.35908c-.02547-2.28665-1.89982-4.11971-4.18647-4.09423-.24325.00271-.48578.02685-.72478.07214-1.99526.43576-3.40276 2.22319-3.35844 4.265v10.605c.04909 2.01427-1.54401 3.68694-3.55827 3.73602-2.01427.04909-3.68694-1.544-3.73603-3.55827-.00077-.0317-.00113-.06341-.00108-.09512v-39.08152c-.05095-2.01424 1.54062-3.6884 3.55486-3.73935 2.01424-.05094 3.6884 1.54062 3.73934 3.55486.00081.03185.0012.06371.00117.09557v10.68764c-.04433 2.04182 1.36316 3.82927 3.35844 4.26504 2.24682.42571 4.41334-1.05059 4.83905-3.29741.04527-.23898.06941-.48148.07212-.72469v-26.35406c-.02992-1.56581.86591-3.00212 2.28526-3.664 2.05708-.98139 4.52024-.10938 5.50163 1.94769.24068.5045.37637 1.05264.39883 1.61117l.00627.15151v7.96649c.08223 2.52499 2.1958 4.50523 4.72079 4.423 2.45692-.08001 4.41129-2.08755 4.42535-4.54572v-24.7324c-.0349-2.05205 1.16658-3.92412 3.04669-4.74713 2.65852-1.18982 5.77823.00079 6.96805 2.65932.30106.67266.45779 1.40096.46008 2.13791v24.49952c-.03967 2.19154 1.44981 4.1159 3.58131 4.62692 2.4719.54087 4.91425-1.02454 5.45512-3.49644.0573-.26187.09151-.52827.10223-.79613v-7.99537l.00749-.18782c.10673-2.26932 2.03289-4.02244 4.30221-3.91571.40654.01912.80799.09846 1.19124.23545 1.63054.57428 2.71321 2.12448 2.691 3.85305v26.28769c.004 2.28362 1.85847 4.13161 4.14209 4.12762 2.26966-.00397 4.11187-1.83671 4.12753-4.10632v-10.94561c-.02534-1.39739.77452-2.67867 2.04111-3.26953 1.8298-.87114 4.01935-.09399 4.89049 1.73582.23244.48822.3541 1.02179.35628 1.56252z" fill="\(fgColor)"/>
          <path d="m21.56144 72.81123c-.00071 1.8345-1.48843 3.32108-3.32293 3.32037-.20304-.00008-.40566-.01878-.60529-.05585-1.60754-.34486-2.74396-1.78233-2.70855-3.42606v-10.29693c-.03541-1.64372 1.10101-3.08118 2.70853-3.42605 1.80407-.33465 3.53785.85656 3.8725 2.66064.03695.19917.0556.40131.05572.60387z" fill="\(fgColor)"/>
          <circle cx="67.5" cy="67.5" r="5.67" fill="\(fgColor)"/>
        </svg>
        """
    }

    static func engineDJ(color: String = "#ffffff") -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="167" height="189" viewBox="0 0 167 189" fill="\(color)">
          <g transform="matrix(1.005859,0,0,1.005859,21,16)">
            <path d="M59.528,21.99C22.768,28.688 27.181,57.523 27.181,96.5C27.181,133.888 28.917,139.37 17.5,139.56C8.407,139.711 10.933,134.049 5.554,129.436C1.259,125.753 0.924,125.107 1.195,94.499C1.285,84.415 7.83,86.447 7.845,80.503C7.894,60.634 7.727,60.672 7.389,58.513C7.118,56.783 10.422,32.883 21.514,21.512C26.859,16.033 33.695,7.606 52.499,3.497C80.86,-2.702 102.941,12.997 110.867,25.247C111.835,26.744 116.9,32.272 119.727,44.45C125.91,71.079 116.699,79.063 124.354,84.706C128.796,87.981 126.724,89.245 127.46,120.5C127.601,126.47 126.684,126.338 122.563,130.569C119.552,133.661 123.126,140.093 109.502,139.484C99.913,139.055 102.095,119.272 102.095,116.5C102.095,51.817 103.512,46.749 93.388,34.59C80.068,18.591 60.472,21.939 59.528,21.99Z"/>
            <path d="M74.835,61.5C74.835,134.494 75.153,135.048 72.31,138.344C69.348,141.778 55.138,145.746 55.004,129.501C54.419,58.605 54.539,57.667 55.328,51.475C56.585,41.617 74.503,41.028 74.822,54.488C74.907,58.082 74.828,57.979 74.835,61.5Z"/>
            <path d="M88.502,76.134C100.266,77.342 98.508,82.279 98.509,124.5C98.51,147.749 100.896,157.639 85.536,156.262C76.973,155.495 78.418,144.906 78.418,108.5C78.418,86.244 76.472,77.273 88.502,76.134Z"/>
            <path d="M50.929,147.51C49.393,161.796 31.761,156.559 31.552,149.492C31.112,134.699 31.543,92.459 31.594,87.5C31.765,70.744 50.819,73.872 50.928,86.5C50.964,90.597 50.932,142.63 50.929,147.51Z"/>
          </g>
        </svg>
        """
    }

    static let showKontrol = """
        <svg xmlns="http://www.w3.org/2000/svg" width="455" height="454" viewBox="0 0 455 454">
          <g transform="matrix(3.68042,0,0,3.68042,-1796.433953,-4.224491)">
            <path d="M500.966,57.564C500.669,65.882 499.426,79.329 513.65,96.382C515.54,98.649 519.265,100.289 516.294,102.21C508.043,107.545 507.326,107.856 505.756,106.238C466.73,66.004 496.747,-1.395 553.51,1.222C565.585,1.778 583.389,8.96 581.366,11.375C580.863,11.976 553.171,29.301 550.708,30.842C546.624,33.397 546.371,31.901 546.348,31.549C545.962,25.622 547.15,14.314 544.557,14.02C543.238,13.871 528.793,16.724 519.845,23.914C502.675,37.71 501.553,54.992 500.966,57.564Z" fill="rgb(239, 40, 138)"/>
          </g>
          <g transform="matrix(3.68042,0,0,3.68042,-1796.433953,-4.224491)">
            <path d="M609.981,76.6C598.342,122.795 551.469,133.735 520.211,116.982C515.477,114.445 521.051,113.685 547.805,95.925C548.436,95.506 553.444,91.835 553.51,94.498C553.895,110.067 552.529,112.005 555.5,111.703C595.949,107.59 613.181,57.176 585.232,28.756C582.842,26.327 580.836,25.638 583.711,23.815C590.01,19.82 591.221,16.175 596.071,21.907C617.274,46.969 611.159,72.075 609.981,76.6Z" fill="rgb(239, 40, 138)"/>
          </g>
        </svg>
        """

    static let showKontrolWhite = """
        <svg xmlns="http://www.w3.org/2000/svg" width="455" height="454" viewBox="0 0 455 454">
          <g transform="matrix(3.68042,0,0,3.68042,-1796.433953,-4.224491)">
            <path d="M500.966,57.564C500.669,65.882 499.426,79.329 513.65,96.382C515.54,98.649 519.265,100.289 516.294,102.21C508.043,107.545 507.326,107.856 505.756,106.238C466.73,66.004 496.747,-1.395 553.51,1.222C565.585,1.778 583.389,8.96 581.366,11.375C580.863,11.976 553.171,29.301 550.708,30.842C546.624,33.397 546.371,31.901 546.348,31.549C545.962,25.622 547.15,14.314 544.557,14.02C543.238,13.871 528.793,16.724 519.845,23.914C502.675,37.71 501.553,54.992 500.966,57.564Z" fill="#ffffff"/>
          </g>
          <g transform="matrix(3.68042,0,0,3.68042,-1796.433953,-4.224491)">
            <path d="M609.981,76.6C598.342,122.795 551.469,133.735 520.211,116.982C515.477,114.445 521.051,113.685 547.805,95.925C548.436,95.506 553.444,91.835 553.51,94.498C553.895,110.067 552.529,112.005 555.5,111.703C595.949,107.59 613.181,57.176 585.232,28.756C582.842,26.327 580.836,25.638 583.711,23.815C590.01,19.82 591.221,16.175 596.071,21.907C617.274,46.969 611.159,72.075 609.981,76.6Z" fill="#ffffff"/>
          </g>
        </svg>
        """

    static let resolume = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">
          <rect x="0" y="0" width="100" height="100" rx="22" fill="#1a3a35"/>
          <clipPath id="aClip">
            <path d="M50 12L15 88H32L40 70H60L68 88H85L50 12ZM45 55L50 42L55 55H45Z"/>
          </clipPath>
          <g clip-path="url(#aClip)">
            <rect x="0" y="0" width="100" height="100" fill="#5de4c7"/>
            <line x1="10" y1="100" x2="60" y2="0" stroke="#1a3a35" stroke-width="6"/>
            <line x1="30" y1="100" x2="80" y2="0" stroke="#1a3a35" stroke-width="6"/>
            <line x1="50" y1="100" x2="100" y2="0" stroke="#1a3a35" stroke-width="6"/>
            <line x1="70" y1="100" x2="120" y2="0" stroke="#1a3a35" stroke-width="6"/>
          </g>
        </svg>
        """

    static func createEnvelope(color: String = "#ffffff") -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="36" height="24" viewBox="0 0 36 24" fill="none" stroke="\(color)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <path d="M2 4C8 10 14 16 18 18C22 16 28 10 34 4"/>
          <path d="M2 4L2 20C2 21.5 3 22 4 22L32 22C33 22 34 21.5 34 20L34 4"/>
        </svg>
        """
    }

    static func newIcon(color: String = "#e0e0e8") -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="\(color)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <line x1="18" y1="6" x2="6" y2="18"/>
          <line x1="6" y1="6" x2="18" y2="18"/>
        </svg>
        """
    }

    static func openIcon(color: String = "#e0e0e8") -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="\(color)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>
        </svg>
        """
    }

    static func saveIcon(color: String = "#e0e0e8") -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="\(color)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/>
          <polyline points="17 21 17 13 7 13 7 21"/>
          <polyline points="7 3 7 8 15 8"/>
        </svg>
        """
    }

    static func boltIcon(color: String = "#1ed760") -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="\(color)">
          <path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/>
        </svg>
        """
    }
}

// MARK: - Public Icon Views

struct RekordboxIcon: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        renderSVG(BrandSVG.rekordbox(color: color.hexString ?? "#e0e0e8"), size: CGSize(width: size, height: size))
            .frame(width: size, height: size)
    }
}

struct SeratoIcon: View {
    let size: CGFloat
    let color: Color
    var bgColor: Color = Color(red: 26/255, green: 26/255, blue: 46/255)

    var body: some View {
        renderSVG(BrandSVG.serato(fgColor: color.hexString ?? "#ffffff", bgColor: bgColor.hexString ?? "#1a1a2e"), size: CGSize(width: size, height: size))
            .frame(width: size, height: size)
    }
}

struct EngineDJIcon: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        renderSVG(BrandSVG.engineDJ(color: color.hexString ?? "#ffffff"), size: CGSize(width: size, height: size * 189/167))
            .frame(width: size, height: size)
    }
}

struct ShowKontrolIcon: View {
    let size: CGFloat
    let color: Color
    var useWhite: Bool = false

    var body: some View {
        renderSVG(
            useWhite ? BrandSVG.showKontrolWhite : BrandSVG.showKontrol,
            size: CGSize(width: size, height: size)
        )
        .frame(width: size, height: size)
    }
}

struct ResolumeIcon: View {
    let size: CGFloat
    let color: Color  // unused — SVG has hardcoded colors

    var body: some View {
        renderSVG(BrandSVG.resolume, size: CGSize(width: size, height: size))
            .frame(width: size, height: size)
    }
}

struct CreateEnvelopeIcon: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        renderSVG(BrandSVG.createEnvelope(color: color.hexString ?? "#ffffff"), size: CGSize(width: size * 36/24, height: size))
            .frame(width: size * 36/24, height: size)
    }
}

struct NewIcon: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        renderSVG(BrandSVG.newIcon(color: color.hexString ?? "#e0e0e8"), size: CGSize(width: size, height: size))
            .frame(width: size, height: size)
    }
}

struct OpenIcon: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        renderSVG(BrandSVG.openIcon(color: color.hexString ?? "#e0e0e8"), size: CGSize(width: size, height: size))
            .frame(width: size, height: size)
    }
}

struct SaveIcon: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        renderSVG(BrandSVG.saveIcon(color: color.hexString ?? "#e0e0e8"), size: CGSize(width: size, height: size))
            .frame(width: size, height: size)
    }
}

struct BoltIcon: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        renderSVG(BrandSVG.boltIcon(color: color.hexString ?? "#1ed760"), size: CGSize(width: size, height: size))
            .frame(width: size, height: size)
    }
}

// MARK: - Color to Hex helper

extension Color {
    var hexString: String? {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int(components.redComponent * 255)
        let g = Int(components.greenComponent * 255)
        let b = Int(components.blueComponent * 255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
