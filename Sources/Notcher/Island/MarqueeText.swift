import SwiftUI

/// Single-line text that scrolls when it doesn't fit: it rests for a moment, scrolls one full
/// length, then repeats. Edges fade so the text never cuts off hard.
struct MarqueeText: View {
    let text: String
    let font: Font
    let lineHeight: CGFloat
    var color: Color = .white

    @State private var textWidth: CGFloat = 0
    @State private var startDate = Date.now

    private let gap: CGFloat = 32
    private let speed: CGFloat = 30   // points per second
    private let pause: TimeInterval = 2
    private let fade: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.width
            if textWidth > available + 0.5 {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                    let offset = offset(at: context.date)
                    HStack(spacing: gap) {
                        label
                        label
                    }
                    .offset(x: -offset)
                    .frame(width: available, alignment: .leading)
                    .clipped()
                    // The leading edge only fades while the text is moving, so the first letter
                    // isn't clipped at rest.
                    .mask(edgeFade(leading: min(offset, fade)))
                }
            } else {
                label.frame(width: available, alignment: .leading)
            }
        }
        .frame(height: lineHeight)
        .background {
            label.hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
        }
        .onChange(of: text) { startDate = .now }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    private func offset(at date: Date) -> CGFloat {
        let distance = textWidth + gap
        let travel = TimeInterval(distance / speed)
        let phase = date.timeIntervalSince(startDate).truncatingRemainder(dividingBy: pause + travel)
        return phase < pause ? 0 : CGFloat(phase - pause) * speed
    }

    private func edgeFade(leading: CGFloat) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: leading)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: fade)
        }
    }
}
