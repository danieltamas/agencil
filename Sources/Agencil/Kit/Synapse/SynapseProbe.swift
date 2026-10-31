import QuartzCore

/// Reads the Core Animation tree. The tests and `scripts/perf.sh` use it to prove that a hidden panel runs nothing.
enum SynapseProbe {
    static func animationCount(in layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        let own = layer.animationKeys()?.count ?? 0
        return own + (layer.sublayers ?? []).reduce(0) { $0 + animationCount(in: $1) }
    }

    static func animatedKeyPaths(in layer: CALayer?) -> Set<String> {
        guard let layer else { return [] }
        var paths: Set<String> = []
        for key in layer.animationKeys() ?? [] {
            if let animation = layer.animation(forKey: key) { paths.formUnion(keyPaths(of: animation)) }
        }
        for sublayer in layer.sublayers ?? [] { paths.formUnion(animatedKeyPaths(in: sublayer)) }
        return paths
    }

    private static func keyPaths(of animation: CAAnimation) -> Set<String> {
        if let group = animation as? CAAnimationGroup { return (group.animations ?? []).reduce(into: []) { $0.formUnion(keyPaths(of: $1)) } }
        return (animation as? CAPropertyAnimation)?.keyPath.map { [$0] } ?? []
    }
}
