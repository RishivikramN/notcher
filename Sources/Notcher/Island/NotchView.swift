import SwiftUI

/// Root view of the island, hung from the top centre of the panel.
struct NotchView: View {
    let controller: NotchController
    private let tuning = Tuning.shared

    var body: some View {
        let shape = NotchShape(
            style: controller.shapeStyle,
            topCornerRadius: controller.topCornerRadius,
            bottomCornerRadius: controller.bottomCornerRadius
        )

        Color.clear
            .frame(
                width: controller.currentWidth + 2 * controller.earWidth,
                height: controller.currentHeight
            )
            .background(shape.fill(.black))
            .overlay(alignment: .top) {
                if controller.showsNotification {
                    NotificationView(controller: controller)
                        .transition(.compactContent(tuning))
                }
            }
            .overlay(alignment: .top) {
                if controller.showsCompactContent {
                    CompactNowPlayingView(controller: controller)
                        .transition(.compactContent(tuning))
                }
            }
            .overlay(alignment: .top) {
                // Laid out at the final size and revealed by the clip, so it never reflows mid-morph.
                if controller.isExpanded {
                    ExpandedMediaPlayerView(controller: controller)
                        .transition(.expandedContent(tuning))
                }
            }
            .clipShape(shape)
            .contentShape(Rectangle())
            .onHover { controller.setMouseInside($0) }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in controller.setPressed(true) }
                    .onEnded { value in
                        controller.setPressed(false)
                        if abs(value.translation.width) < 4, abs(value.translation.height) < 4 {
                            controller.handleTap()
                        }
                    }
            )
            .scaleEffect(x: controller.scale.width, y: controller.scale.height, anchor: .top)
            .padding(.top, controller.topInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
    }
}
