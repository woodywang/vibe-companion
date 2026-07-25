import SwiftUI
import Lottie

/// 包装 lottie-ios 的 LottieAnimationView，绑定速率 -> animationSpeed
struct LottiePetView: NSViewRepresentable {
    let animationName: String          // Resources/Animations 下的文件名（不含扩展）
    let speed: Double                  // animationSpeed

    func makeNSView(context: Context) -> Lottie.LottieAnimationView {
        // SwiftPM 打包的资源在 Contents/Resources/Animations/ 子目录下。
        // LottieAnimationView(name:bundle:) 不传 subdirectory 时只在 bundle 根查找，
        // 找不到会静默返回空视图（animation 为 nil）。这里显式指定子目录。
        let animation = LottieAnimation.named(
            animationName,
            bundle: .main,
            subdirectory: "Animations"
        )
        let view = LottieAnimationView(animation: animation)
        view.contentMode = .scaleAspectFit
        view.loopMode = .loop
        view.backgroundBehavior = .pauseAndRestore
        view.animationSpeed = speed
        view.play()
        return view
    }

    func updateNSView(_ nsView: Lottie.LottieAnimationView, context: Context) {
        // 速率变化时实时更新
        if abs(nsView.animationSpeed - speed) > 0.01 {
            nsView.animationSpeed = speed
        }
        if !nsView.isAnimationPlaying {
            nsView.play()
        }
    }
}
